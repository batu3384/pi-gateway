#!/usr/bin/env bash
# ISP hız — Grafana textfile, Telegram yok
set -euo pipefail
METRICS_DIR="${PI_GATEWAY_METRICS_DIR:-/var/lib/pi-gateway/metrics}"
OUT="${METRICS_DIR}/pi_gateway_speedtest.prom"
PRIMARY_URL="${SPEEDTEST_URL:-http://umr1speedtest.turktelekom.com.tr:8080/speedtest/random4000x4000.jpg}"
FALLBACK_URL="${SPEEDTEST_FALLBACK_URL:-https://speed.cloudflare.com/__down?bytes=25000000}"
WORKERS="${SPEEDTEST_WORKERS:-8}"
MAX_SEC="${SPEEDTEST_MAX_SEC:-6}"

if [[ "${1:-}" == "--self-check" ]]; then
  python3 - <<'PY'
import json
def calc_mbps(nbytes: int, dt: float) -> float:
    return (nbytes * 8) / dt / 1_000_000 if dt > 0 and nbytes > 0 else -1.0

def parse_ookla(raw: str) -> tuple[float, float]:
    d = json.loads(raw)
    bw = float((d.get("download") or {}).get("bandwidth") or 0)
    ping = float((d.get("ping") or {}).get("latency") or -1.0)
    if bw <= 0:
        raise ValueError("zero bandwidth")
    return (bw * 8.0) / 1_000_000.0, ping

assert abs(calc_mbps(25_000_000, 0.25) - 800.0) < 0.01
assert calc_mbps(0, 1.0) == -1.0
d_mbps, d_ping = parse_ookla('{"download":{"bandwidth":115000000},"ping":{"latency":4.2}}')
assert abs(d_mbps - 920.0) < 0.01 and abs(d_ping - 4.2) < 0.01
print("[isp-speedtest] self-check OK")
PY
  exit 0
fi

mkdir -p "$METRICS_DIR" 2>/dev/null || true
python3 - "$PRIMARY_URL" "$FALLBACK_URL" "$WORKERS" "$MAX_SEC" "$OUT" <<'PY'
from concurrent.futures import ThreadPoolExecutor
import json
import os
import shutil
import socket
import subprocess
import sys
import tempfile
import time
import urllib.parse
import urllib.request

primary_url, fallback_url = sys.argv[1], sys.argv[2]
workers, max_sec, out = max(1, int(sys.argv[3])), max(2.0, float(sys.argv[4])), sys.argv[5]
UA = "Mozilla/5.0 pi-gateway-speedtest/2"
WARMUP_SEC = 0.30


class _SameHostRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        old_host = (urllib.parse.urlsplit(req.full_url).hostname or "").lower()
        new_host = (urllib.parse.urlsplit(newurl).hostname or "").lower()
        if old_host and new_host and new_host != old_host:
            return None
        return super().redirect_request(req, fp, code, msg, headers, newurl)


DIRECT_OPENER = urllib.request.build_opener(
    urllib.request.ProxyHandler({}),
    _SameHostRedirect(),
)


def bench_ookla_cli() -> tuple[float, float] | None:
    if os.environ.get("SPEEDTEST_DISABLE_OOKLA", "false").lower() == "true":
        return None
    cli = shutil.which("speedtest") or (
        "/usr/local/bin/speedtest" if os.path.isfile("/usr/local/bin/speedtest") else None
    )
    if not cli:
        return None
    try:
        proc = subprocess.run(
            [cli, "--accept-license", "--accept-gdpr", "--format=json"],
            capture_output=True,
            text=True,
            timeout=45,
            check=True,
        )
        data = json.loads(proc.stdout)
        bw = float((data.get("download") or {}).get("bandwidth") or 0)
        ping_ms = float((data.get("ping") or {}).get("latency") or -1.0)
        if bw > 0:
            return (bw * 8.0) / 1_000_000.0, ping_ms
    except Exception:
        return None
    return None

def _tcp_handshake_min_ms(host: str, port: int) -> float:
    ip = socket.gethostbyname(host)
    best: float | None = None
    for _ in range(3):
        t0 = time.perf_counter()
        with socket.create_connection((ip, port), timeout=3.0):
            ms = (time.perf_counter() - t0) * 1000.0
            if best is None or ms < best:
                best = ms
    assert best is not None
    return min(best, 60000.0)

def measure_tcp_ping_ms(url: str) -> float:
    parsed = urllib.parse.urlsplit(url)
    host = parsed.hostname or ""
    port = parsed.port or (443 if parsed.scheme == "https" else 80)
    for target_host, target_port in ((host, port), ("1.1.1.2", 443)):
        if not target_host:
            continue
        try:
            return _tcp_handshake_min_ms(target_host, target_port)
        except OSError:
            continue
    return -1.0

def bench_parallel(url: str) -> tuple[float, float]:
    headers = {"User-Agent": UA}
    if "cloudflare.com" in url:
        headers["Referer"] = "https://speed.cloudflare.com/"
    ping_ms = measure_tcp_ping_ms(url)
    t_start = time.perf_counter()
    warmup_until = t_start + WARMUP_SEC
    deadline = t_start + max_sec

    def fetch_one(idx: int) -> tuple[int, int]:
        sep = "&" if "?" in url else "?"
        req = urllib.request.Request(f"{url}{sep}s={idx}&t={int(time.time())}", headers=headers)
        all_got = 0
        post_got = 0
        with DIRECT_OPENER.open(req, timeout=max_sec + 4) as resp:
            while time.perf_counter() < deadline:
                chunk = resp.read(131072)
                if not chunk:
                    break
                n = len(chunk)
                all_got += n
                if time.perf_counter() >= warmup_until:
                    post_got += n
        return all_got, post_got

    all_total = 0
    post_total = 0
    with ThreadPoolExecutor(max_workers=workers) as pool:
        for all_got, post_got in pool.map(fetch_one, range(workers)):
            all_total += all_got
            post_total += post_got
    t_end = time.perf_counter()
    if post_total > 0 and t_end > warmup_until:
        mbps = (post_total * 8) / max(t_end - warmup_until, 0.001) / 1_000_000
    elif all_total > 0 and t_end > t_start:
        mbps = (all_total * 8) / max(t_end - t_start, 0.001) / 1_000_000
    else:
        raise RuntimeError("empty transfer")
    return mbps, ping_ms

down = ping = -1.0
ookla = bench_ookla_cli()
if ookla is not None:
    down, ping = ookla
else:
    for candidate in (primary_url, fallback_url):
        if not candidate:
            continue
        try:
            down, ping = bench_parallel(candidate)
            break
        except Exception:
            continue
text = (
    "# HELP pi_gateway_isp_download_mbps Approx download via multi-stream CDN sample (-1 fail)\n"
    "# TYPE pi_gateway_isp_download_mbps gauge\n"
    f"pi_gateway_isp_download_mbps {down:.3f}\n"
    "# HELP pi_gateway_isp_ping_ms TCP handshake RTT latency in ms (-1 fail)\n"
    "# TYPE pi_gateway_isp_ping_ms gauge\n"
    f"pi_gateway_isp_ping_ms {ping:.1f}\n"
)
out_dir = os.path.dirname(out) or "."
tmp_path = None
try:
    os.makedirs(out_dir, exist_ok=True)
    fd, tmp_path = tempfile.mkstemp(prefix=".speedtest-", suffix=".tmp", dir=out_dir)
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        f.write(text)
    os.chmod(tmp_path, 0o644)
    os.replace(tmp_path, out)
    tmp_path = None
except OSError as exc:
    print(f"[isp-speedtest] HATA metric yazilamadi ({out}): {exc}", file=sys.stderr)
    sys.exit(1)
finally:
    if tmp_path is not None:
        try:
            os.unlink(tmp_path)
        except OSError:
            pass
print(f"[isp-speedtest] down={down:.2f} Mbps ping~{ping:.0f}ms")
PY
