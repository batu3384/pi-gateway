#!/usr/bin/env bash
# Modem DNS/lease degisikliginden sonra LAN kapsamini izle (cihaz reboot gerekmez).
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REMOTE_DIR="${REMOTE_DIR:-/home/${USER}/pi-gateway}"
TIMEOUT="${DNS_ROLLOUT_TIMEOUT_SEC:-1800}"
INTERVAL="${DNS_ROLLOUT_INTERVAL_SEC:-60}"
MIN_COVERAGE="${ADGUARD_MIN_COVERAGE_PERCENT:-50}"

echo "=== DNS rollout izleme (max ${TIMEOUT}s, her ${INTERVAL}s) ==="
echo "Modem: DHCP lease kisa + reboot yeterli — telefon reboot gerekmez."
deadline=$((SECONDS + TIMEOUT))
while (( SECONDS < deadline )); do
  set +e
  REMOTE_DIR="$REMOTE_DIR" ADGUARD_BYPASS_CHECK=strict \
    bash "$SCRIPT_DIR/audit-dns-coverage.sh" >/tmp/pi-gateway-dns-rollout.log 2>&1
  rc=$?
  set -e
  if [[ "$rc" -eq 0 ]]; then
    cat /tmp/pi-gateway-dns-rollout.log
    echo "[rollout] OK — tum ping-aktif cihazlar Pi DNS kullaniyor"
    exit 0
  fi
  status="rc=${rc}"
  if grep -qE 'COVERAGE_FAIL:[0-9]+' /tmp/pi-gateway-dns-rollout.log; then
    status="kapsam %$(grep -oE 'COVERAGE_FAIL:[0-9]+' /tmp/pi-gateway-dns-rollout.log | tail -1 | cut -d: -f2)"
  elif grep -qE 'COVERAGE_UNKNOWN|UNKNOWN_DEVICES:' /tmp/pi-gateway-dns-rollout.log; then
    status="envanter/cihaz UNKNOWN"
  elif grep -qE 'MISSING_DEVICES:' /tmp/pi-gateway-dns-rollout.log; then
    status="bypass $(grep -oE 'MISSING_DEVICES:[^[:space:]]+' /tmp/pi-gateway-dns-rollout.log | tail -1 | cut -d: -f2-)"
  fi
  echo "[rollout] bekleniyor (${status}, hedef >=${MIN_COVERAGE}) — $((deadline - SECONDS))s kaldi"
  tail -8 /tmp/pi-gateway-dns-rollout.log | sed 's/^/  /'
  sleep "$INTERVAL"
done
echo "[rollout] TIMEOUT — bazi cihazlar hala bypass (Ozel DNS / sabit DNS olabilir)" >&2
cat /tmp/pi-gateway-dns-rollout.log
exit 1
