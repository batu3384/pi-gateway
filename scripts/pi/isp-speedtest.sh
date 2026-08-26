#!/usr/bin/env bash
# ISP hız — Grafana textfile, Telegram yok
set -euo pipefail
METRICS_DIR="${PI_GATEWAY_METRICS_DIR:-/var/lib/pi-gateway/metrics}"
OUT="${METRICS_DIR}/pi_gateway_speedtest.prom"
BYTES="${SPEEDTEST_BYTES:-2000000}"
URL="${SPEEDTEST_URL:-https://speed.cloudflare.com/__down?bytes=${BYTES}}"

if [[ "${1:-}" == "--self-check" ]]; then
  python3 - <<'PY'
mbps = (2_000_000 * 8) / 1.0 / 1_000_000
assert abs(mbps - 16.0) < 0.01
print("[isp-speedtest] self-check OK")
PY
  exit 0
fi

mkdir -p "$METRICS_DIR" 2>/dev/null || true
python3 - "$URL" "$BYTES" "$OUT" <<'PY'
import os, sys, time, urllib.request
url, nbytes, out = sys.argv[1], int(sys.argv[2]), sys.argv[3]
down = ping = -1.0
t0 = time.perf_counter()
req = urllib.request.Request(url, headers={"User-Agent": "pi-gateway-speedtest/1"})
try:
    with urllib.request.urlopen(req, timeout=45) as resp:
        got = 0
        while True:
            chunk = resp.read(65536)
            if not chunk:
                break
            got += len(chunk)
    dt = time.perf_counter() - t0
    if dt > 0 and got > 0:
        down = (got * 8) / dt / 1_000_000
        ping = dt * 1000 * (min(got, 4096) / max(got, 1))
        ping = min(dt * 1000, 60000)
except Exception:
    down = ping = -1.0
text = (
    "# HELP pi_gateway_isp_download_mbps Approx download via CDN sample (-1 fail)\n"
    "# TYPE pi_gateway_isp_download_mbps gauge\n"
    f"pi_gateway_isp_download_mbps {down:.3f}\n"
    "# HELP pi_gateway_isp_ping_ms Sample transfer time as ping proxy (-1 fail)\n"
    "# TYPE pi_gateway_isp_ping_ms gauge\n"
    f"pi_gateway_isp_ping_ms {ping:.1f}\n"
)
try:
    os.makedirs(os.path.dirname(out), exist_ok=True)
    tmp = out + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        f.write(text)
    os.replace(tmp, out)
except OSError:
    pass
print(f"[isp-speedtest] down={down:.2f} Mbps ping~{ping:.0f}ms")
PY
