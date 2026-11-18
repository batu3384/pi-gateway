#!/usr/bin/env bash
# SD root alan acma — guvenli temizlik (hybrid: Docker SSD veya SD'de olabilir)
set -euo pipefail
REMOTE_DIR="${REMOTE_DIR:-/home/${USER}/pi-gateway}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/env-file.sh
source "$SCRIPT_DIR/../lib/env-file.sh"
read_remote_dotenv || { echo "[prune-sd] HATA: .env dotenv parser hatasi" >&2; exit 1; }
STORAGE_DEGRADED_FLAG="${STORAGE_DEGRADED_FLAG:-/run/pi-gateway/storage-degraded}"
DISK_PRUNE_PCT="${DISK_PRUNE_PCT:-65}"
DISK_PRUNE_FORCE_PCT="${DISK_PRUNE_FORCE_PCT:-70}"
STAMP="/var/lib/pi-gateway/last-sd-prune"
STATE_OWNER="${PI_USER:-${SUDO_USER:-${USER:-pi}}}"
log() { echo "[prune-sd] $*"; }
root_usage_pct() {
  df -P / 2>/dev/null | awk 'NR==2 {gsub(/%/,""); print $5}'
}
prune_safe() {
  log "temizlik basliyor..."
  sudo apt-get clean -qq 2>/dev/null || true
  sudo journalctl --vacuum-size=150M 2>/dev/null || true
  # Eski gecici SD yedek ve bulten artiklarini temizle (>14 gun)
  sudo find /var/lib -maxdepth 1 -name 'docker.sd-backup-*' -mtime +14 -exec rm -rf {} + 2>/dev/null || true
  if [[ -d "$REMOTE_DIR" ]]; then
    sudo find "$REMOTE_DIR" -maxdepth 1 -name 'data.sd-degraded.bak.*' -mtime +14 -exec rm -rf {} + 2>/dev/null || true
  fi
  if [[ -d /var/lib/pi-gateway/bulletins ]]; then
    sudo find /var/lib/pi-gateway/bulletins -type f -mtime +14 -delete 2>/dev/null || true
  fi
  if [[ -f "$STORAGE_DEGRADED_FLAG" ]]; then
    log "degraded — docker image prune atlandi"
    return 0
  fi
  # ponytail: Docker 29+ overlayfs snapshotter = layers in containerd, not Docker Root Dir.
  # ENABLE_DOCKER_SSD=true + /mnt/ssd/docker does not mean images left SD.
  local containerd_root
  containerd_root="$(grep -E '^root\s*=' /etc/containerd/config.toml 2>/dev/null | head -1 | sed -n 's/.*"\([^"]*\)".*/\1/p' || true)"
  [[ -n "$containerd_root" ]] || containerd_root="/var/lib/containerd"
  if [[ "$containerd_root" == /mnt/ssd/* ]]; then
    log "containerd SSD'de (${containerd_root}) — image prune atlandi"
    return 0
  fi
  log "containerd SD'de (${containerd_root}) — dangling image + orphan lease prune"
  # prune -a kullanilmaz: pinli restic imaji konteynersizken silinir, gece yedek kirilir.
  timeout 60 docker image prune -f 2>/dev/null || true
  if command -v ctr >/dev/null 2>&1 && systemctl is-active --quiet docker 2>/dev/null; then
    python3 - <<'PY' 2>/dev/null || true
import datetime
import subprocess

live = set(subprocess.check_output(["docker", "ps", "-a", "--no-trunc", "--format", "{{.ID}}"], text=True, timeout=15).split())
if not live:
    raise SystemExit(0)
now = datetime.datetime.now(datetime.timezone.utc)
rows = subprocess.check_output(["sudo", "ctr", "-n", "moby", "leases", "ls"], text=True, timeout=15).splitlines()[1:]
orphans = []
for row in rows:
    cols = row.split()
    if not cols:
        continue
    lid = cols[0]
    if len(lid) != 64 or not all(c in "0123456789abcdef" for c in lid) or lid in live:
        continue
    if len(cols) >= 2:
        try:
            created = datetime.datetime.fromisoformat(cols[1].replace("Z", "+00:00"))
            if created.tzinfo is None:
                created = created.replace(tzinfo=datetime.timezone.utc)
            if (now - created).total_seconds() < 86400:
                continue
        except ValueError:
            continue
    orphans.append(lid)
for i in range(0, len(orphans), 50):
    chunk = orphans[i:i+50]
    cmd = ["sudo", "ctr", "-n", "moby", "leases", "delete"] + (["--sync"] if i + 50 >= len(orphans) else []) + chunk
    subprocess.run(cmd, check=False, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=60)
PY
  fi
}
usage="$(root_usage_pct)"
[[ -n "${usage:-}" ]] || { log "df / okunamadi"; exit 1; }
if (( usage < DISK_PRUNE_PCT )); then
  log "atlandi: / ${usage}% < ${DISK_PRUNE_PCT}%"
  exit 0
fi
if [[ -f "$STAMP" ]]; then
  age_h="$(python3 -c "import os,time; print(int((time.time()-os.path.getmtime('$STAMP'))//3600))")"
  if (( age_h < 24 )) && (( usage < DISK_PRUNE_FORCE_PCT )); then
    log "atlandi: son prune ${age_h}h once (24h cooldown; force >=${DISK_PRUNE_FORCE_PCT}%)"
    exit 0
  fi
fi
before="${usage}"
prune_safe
after="$(root_usage_pct)"
sudo mkdir -p /var/lib/pi-gateway
sudo chown "${STATE_OWNER}:${STATE_OWNER}" /var/lib/pi-gateway 2>/dev/null || true
sudo touch "$STAMP"
sudo chown "${STATE_OWNER}:${STATE_OWNER}" "$STAMP" 2>/dev/null || true
log "tamamlandi: / ${before}% -> ${after}%"
