#!/usr/bin/env python3
"""Host :53 → DNS-over-TLS. Docker/AGH olunca systemd unit durur."""
from __future__ import annotations

import ipaddress
import os
import selectors
import socket
import ssl
import struct
import sys
import threading

UPSTREAMS = (
    ("9.9.9.9", 853, "dns.quad9.net"),
    ("94.140.14.14", 853, "dns.adguard-dns.com"),
)
DOT_TIMEOUT = 3.0
LISTEN_PORT = int(os.environ.get("DNS_FALLBACK_PORT", "53"))
MAX_DNS = 4096
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
        ans = query_dot(data)
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
        ans = query_dot(q)
        if ans:
            conn.sendall(struct.pack("!H", len(ans)) + ans)
    except OSError:
        return
    finally:
        conn.close()


def _bind(family: int, kind: int) -> socket.socket | None:
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
        print(f"[dns-dot-proxy] bind fail {family}/{kind}: {exc}", file=sys.stderr)
        return None
    if kind == socket.SOCK_STREAM:
        sock.listen(32)
    sock.setblocking(False)
    return sock


def serve() -> int:
    # ponytail: thread-per-query. Ceiling LAN storm; upgrade ThreadPoolExecutor.
    sel = selectors.DefaultSelector()
    bound = 0
    for family, kind in (
        (socket.AF_INET, socket.SOCK_DGRAM),
        (socket.AF_INET, socket.SOCK_STREAM),
        (socket.AF_INET6, socket.SOCK_DGRAM),
        (socket.AF_INET6, socket.SOCK_STREAM),
    ):
        sock = _bind(family, kind)
        if sock is None:
            continue
        sel.register(sock, selectors.EVENT_READ, kind)
        bound += 1
    if bound == 0:
        print("[dns-dot-proxy] HATA: :53 bind yok (AGH elinde?)", file=sys.stderr)
        return 75
    print(f"[dns-dot-proxy] listen :{LISTEN_PORT} sockets={bound}", flush=True)
    while True:
        for key, _ in sel.select():
            sock = key.fileobj
            kind = key.data
            if kind == socket.SOCK_DGRAM:
                try:
                    data, src = sock.recvfrom(MAX_DNS)
                except OSError:
                    continue
                threading.Thread(
                    target=_handle_udp, args=(sock, data, src), daemon=True
                ).start()
            else:
                try:
                    conn, addr = sock.accept()
                except OSError:
                    continue
                threading.Thread(
                    target=_handle_tcp, args=(conn, addr), daemon=True
                ).start()


def self_check() -> None:
    assert allowed("127.0.0.1")
    assert allowed("192.168.1.50")
    assert allowed("100.64.1.1")
    assert allowed("::1")
    assert not allowed("8.8.8.8")
    assert not allowed("1.1.1.1")
    packed = struct.pack("!H", 12) + b"abcdefghijkl"
    assert struct.unpack("!H", packed[:2])[0] == 12
    print("[dns-dot-proxy] self-check OK")


if __name__ == "__main__":
    if "--self-check" in sys.argv:
        self_check()
        sys.exit(0)
    sys.exit(serve())
