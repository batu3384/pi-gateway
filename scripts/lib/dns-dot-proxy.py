#!/usr/bin/env python3
"""Host :53 → DNS-over-TLS. Docker/AGH olunca systemd unit durur."""
from __future__ import annotations

import errno
import ipaddress
import os
import selectors
import socket
import ssl
import struct
import sys
import threading
import time

UPSTREAMS = (
    ("9.9.9.9", 853, "dns.quad9.net"),
    ("94.140.14.14", 853, "dns.adguard-dns.com"),
)
DOT_TIMEOUT = 3.0
LISTEN_PORT = int(os.environ.get("DNS_FALLBACK_PORT", "53"))
# ponytail: EADDRINUSE retry. Tavan sonsuz bekleme; unit stop = AGH geri.
BIND_RETRY_SEC = float(os.environ.get("DNS_FALLBACK_BIND_RETRY_SEC", "0.5"))
BIND_WAIT_SEC = float(os.environ.get("DNS_FALLBACK_BIND_WAIT_SEC", "0"))
MAX_DNS = 4096
QTYPE_AAAA = 28
DISABLE_AAAA = os.environ.get("DNS_FALLBACK_DISABLE_AAAA", "true").strip().lower() in (
    "1",
    "true",
    "yes",
)
# ponytail: thread-per-query. Ceiling LAN storm; upgrade ThreadPoolExecutor.
MAX_INFLIGHT = int(os.environ.get("DNS_FALLBACK_MAX_INFLIGHT", "64"))
_INFLIGHT = threading.Semaphore(MAX_INFLIGHT)
ALLOWED = (
    ipaddress.ip_network("127.0.0.0/8"),
    ipaddress.ip_network("10.0.0.0/8"),
    ipaddress.ip_network("172.16.0.0/12"),
    ipaddress.ip_network("192.168.0.0/16"),
    ipaddress.ip_network("100.64.0.0/10"),
    ipaddress.ip_network("::1/128"),
    ipaddress.ip_network("fc00::/7"),
    ipaddress.ip_network("fe80::/10"),
)


def allowed(addr: str) -> bool:
    try:
        ip = ipaddress.ip_address(addr)
    except ValueError:
        return False
    return any(ip in net for net in ALLOWED)


def _skip_qname(q: bytes, i: int) -> int:
    n = len(q)
    while i < n:
        lab = q[i]
        if lab == 0:
            return i + 1
        if lab & 0xC0 == 0xC0:
            return i + 2
        i += 1 + lab
    return n


def qtype(q: bytes) -> int:
    if len(q) < 16:
        return 0
    i = _skip_qname(q, 12)
    if i + 2 > len(q):
        return 0
    return int.from_bytes(q[i : i + 2], "big")


def nodata(q: bytes) -> bytes:
    """NOERROR + empty answer (NODATA). Happy Eyeballs AAAA bekletmesin."""
    if len(q) < 16:
        return b""
    end = _skip_qname(q, 12) + 4
    if end > len(q) or end < 16:
        return b""
    return q[:2] + b"\x81\x80" + q[4:6] + b"\x00\x00\x00\x00\x00\x00" + q[12:end]


def _answer(q: bytes) -> bytes:
    if DISABLE_AAAA and qtype(q) == QTYPE_AAAA:
        return nodata(q)
    return query_dot(q)


def query_dot(q: bytes) -> bytes:
    if not q or len(q) > MAX_DNS:
        return b""
    ctx = ssl.create_default_context()
    payload = struct.pack("!H", len(q)) + q
    last_err: OSError | None = None
    for host, port, sni in UPSTREAMS:
        try:
            raw = socket.create_connection((host, port), timeout=DOT_TIMEOUT)
            tls = ctx.wrap_socket(raw, server_hostname=sni)
            with tls:
                tls.settimeout(DOT_TIMEOUT)
                tls.sendall(payload)
                hdr = b""
                while len(hdr) < 2:
                    chunk = tls.recv(2 - len(hdr))
                    if not chunk:
                        raise OSError("dot eof")
                    hdr += chunk
                (n,) = struct.unpack("!H", hdr)
                if n == 0 or n > MAX_DNS:
                    raise OSError("dot len")
                body = b""
                while len(body) < n:
                    chunk = tls.recv(n - len(body))
                    if not chunk:
                        raise OSError("dot eof body")
                    body += chunk
                return body
        except OSError as exc:
            last_err = exc
    if last_err is not None:
        raise last_err
    return b""


def _handle_udp(sock: socket.socket, data: bytes, src: tuple) -> None:
    host = src[0]
    if host.startswith("::ffff:"):
        host = host[7:]
    if not allowed(host):
        return
    try:
        ans = _answer(data)
    except OSError:
        return
    if ans:
        sock.sendto(ans, src)


def _handle_tcp(conn: socket.socket, addr: tuple) -> None:
    host = addr[0]
    if host.startswith("::ffff:"):
        host = host[7:]
    try:
        if not allowed(host):
            return
        conn.settimeout(DOT_TIMEOUT)
        hdr = b""
        while len(hdr) < 2:
            chunk = conn.recv(2 - len(hdr))
            if not chunk:
                return
            hdr += chunk
        (n,) = struct.unpack("!H", hdr)
        if n == 0 or n > MAX_DNS:
            return
        q = b""
        while len(q) < n:
            chunk = conn.recv(n - len(q))
            if not chunk:
                return
            q += chunk
        ans = _answer(q)
        if ans:
            conn.sendall(struct.pack("!H", len(ans)) + ans)
    except OSError:
        return
    finally:
        conn.close()


def _bind(family: int, kind: int) -> tuple[socket.socket | None, int | None]:
    sock = socket.socket(family, kind)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    if family == socket.AF_INET6:
        sock.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 1)
    try:
        if family == socket.AF_INET6:
            sock.bind(("::", LISTEN_PORT))
        else:
            sock.bind(("0.0.0.0", LISTEN_PORT))
    except OSError as exc:
        sock.close()
        err = exc.errno
        if err not in (
            errno.EADDRINUSE,
            errno.EAFNOSUPPORT,
            errno.EADDRNOTAVAIL,
        ):
            print(f"[dns-dot-proxy] bind fail {family}/{kind}: {exc}", file=sys.stderr)
        return None, err
    if kind == socket.SOCK_STREAM:
        sock.listen(32)
    sock.setblocking(False)
    return sock, None


def bind_ready(results: list[tuple[bool, int | None, bool]]) -> bool:
    """(bound, errno, required). Kismi bind yasak: bir soket mesgulse hepsini birak."""
    got = need = 0
    conflict = False
    for bound, err, required in results:
        if required:
            need += 1
        if bound:
            if required:
                got += 1
            continue
        if err in (errno.EAFNOSUPPORT, errno.EADDRNOTAVAIL) and not required:
            continue
        conflict = True
    return (not conflict) and need > 0 and got == need


def _spawn(target, args) -> None:
    if not _INFLIGHT.acquire(blocking=False):
        return
    def _run() -> None:
        try:
            target(*args)
        finally:
            _INFLIGHT.release()
    threading.Thread(target=_run, daemon=True).start()


def _drop_bind(sel: selectors.BaseSelector, held: list[socket.socket]) -> None:
    for sock in held:
        try:
            sel.unregister(sock)
        except KeyError:
            pass
        sock.close()
    sel.close()


def serve() -> int:
    deadline = None if BIND_WAIT_SEC <= 0 else time.monotonic() + BIND_WAIT_SEC
    logged_wait = False
    slots = (
        (socket.AF_INET, socket.SOCK_DGRAM, True),
        (socket.AF_INET, socket.SOCK_STREAM, True),
        (socket.AF_INET6, socket.SOCK_DGRAM, False),
        (socket.AF_INET6, socket.SOCK_STREAM, False),
    )
    sel: selectors.BaseSelector | None = None
    while True:
        sel = selectors.DefaultSelector()
        held: list[socket.socket] = []
        results: list[tuple[bool, int | None, bool]] = []
        for family, kind, required in slots:
            sock, err = _bind(family, kind)
            if sock is not None:
                sel.register(sock, selectors.EVENT_READ, kind)
                held.append(sock)
                results.append((True, None, required))
            else:
                results.append((False, err, required))
        if bind_ready(results):
            break
        _drop_bind(sel, held)
        sel = None
        if deadline is not None and time.monotonic() >= deadline:
            print("[dns-dot-proxy] HATA: :53 bind yok (AGH elinde?)", file=sys.stderr)
            return 75
        if not logged_wait:
            print("[dns-dot-proxy] :53 mesgul — tam bind bekle (kismi yok)", flush=True)
            logged_wait = True
        time.sleep(max(BIND_RETRY_SEC, 0.05))
    assert sel is not None
    print(f"[dns-dot-proxy] listen :{LISTEN_PORT} sockets={len(held)}", flush=True)
    while True:
        for key, _ in sel.select():
            sock = key.fileobj
            kind = key.data
            if kind == socket.SOCK_DGRAM:
                try:
                    data, src = sock.recvfrom(MAX_DNS)
                except OSError:
                    continue
                _spawn(_handle_udp, (sock, data, src))
            else:
                try:
                    conn, addr = sock.accept()
                except OSError:
                    continue
                _spawn(_handle_tcp, (conn, addr))


def self_check() -> None:
    assert allowed("127.0.0.1")
    assert allowed("192.168.1.50")
    assert allowed("100.64.1.1")
    assert allowed("::1")
    assert not allowed("8.8.8.8")
    assert not allowed("1.1.1.1")
    packed = struct.pack("!H", 12) + b"abcdefghijkl"
    assert struct.unpack("!H", packed[:2])[0] == 12
    aaaa_q = bytes.fromhex("000101000001000000000000016100001c0001")
    assert qtype(aaaa_q) == QTYPE_AAAA
    aaaa_r = nodata(aaaa_q)
    assert aaaa_r[:2] == aaaa_q[:2]
    assert aaaa_r[2] & 0x80
    assert aaaa_r[6:8] == b"\x00\x00"
    a_q = bytes.fromhex("00010100000100000000000001610000010001")
    assert qtype(a_q) == 1
    assert MAX_INFLIGHT >= 1
    assert BIND_RETRY_SEC > 0
    assert BIND_WAIT_SEC >= 0
    assert bind_ready(
        [(True, None, True), (True, None, True), (True, None, False), (True, None, False)]
    )
    assert bind_ready(
        [
            (True, None, True),
            (True, None, True),
            (False, errno.EAFNOSUPPORT, False),
            (False, errno.EAFNOSUPPORT, False),
        ]
    )
    # UDP bos, TCP AGH'de: yarim bind servis etme (canli 2026-10-21).
    assert not bind_ready(
        [
            (True, None, True),
            (False, errno.EADDRINUSE, True),
            (True, None, False),
            (False, errno.EADDRINUSE, False),
        ]
    )
    assert not bind_ready(
        [(False, errno.EADDRINUSE, True), (False, errno.EADDRINUSE, True)]
    )
    assert _INFLIGHT.acquire(blocking=False)
    _INFLIGHT.release()
    print("[dns-dot-proxy] self-check OK")


if __name__ == "__main__":
    if "--self-check" in sys.argv:
        self_check()
        sys.exit(0)
    sys.exit(serve())
