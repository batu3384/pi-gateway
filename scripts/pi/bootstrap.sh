#!/usr/bin/env bash
set -euo pipefail
REMOTE_DIR="${REMOTE_DIR:-/home/${USER}/pi-gateway}"
PI_INTERFACE="${PI_INTERFACE:-eth0}"
TAILSCALE_AUTHKEY="${TAILSCALE_AUTHKEY:-}"
TAILSCALE_HOSTNAME="${TAILSCALE_HOSTNAME:-pi-gateway}"
STORAGE_TYPE="${STORAGE_TYPE:-hybrid}"
ENABLE_CROWDSEC="${ENABLE_CROWDSEC:-true}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_PG_ENV_LIB="${SCRIPT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}/../lib/env-file.sh"
PG_SCRIPT_NAME="$(basename "$0")"
# shellcheck source=../lib/env-file.sh
source "${_PG_ENV_LIB:?}"
_BOOT_ENABLE_UFW="${ENABLE_UFW:-}"
read_remote_dotenv || { echo "[${PG_SCRIPT_NAME:-script}] HATA: .env dotenv parser hatasi" >&2; exit 1; }
[[ -n "${_BOOT_ENABLE_UFW}" ]] && ENABLE_UFW="${_BOOT_ENABLE_UFW}"
ENABLE_CROWDSEC="${ENABLE_CROWDSEC:-true}"
echo "[bootstrap] Pi Gateway host preparation"
if ! command -v docker >/dev/null 2>&1; then
  curl -fsSL https://get.docker.com | sh
fi
sudo usermod -aG docker "$USER" || true
if systemctl is-active --quiet systemd-resolved 2>/dev/null; then
  sudo mkdir -p /etc/systemd/resolved.conf.d
  echo -e "[Resolve]\nDNSStubListener=no" | sudo tee /etc/systemd/resolved.conf.d/pi-gateway.conf >/dev/null
  sudo systemctl restart systemd-resolved
  if [[ -L /etc/resolv.conf ]]; then
    sudo ln -sf /run/systemd/resolve/resolv.conf /etc/resolv.conf
  fi
fi
if [[ -f "$REMOTE_DIR/host/sysctl/99-pi-gateway.conf" ]]; then
  sudo cp "$REMOTE_DIR/host/sysctl/99-pi-gateway.conf" /etc/sysctl.d/99-pi-gateway.conf
  sudo sysctl --system >/dev/null 2>&1 || true
fi
if [[ -f "$REMOTE_DIR/host/dhcpcd/pi-gateway.conf" ]]; then
  sudo mkdir -p /etc/dhcpcd.conf.d
  sudo cp "$REMOTE_DIR/host/dhcpcd/pi-gateway.conf" /etc/dhcpcd.conf.d/pi-gateway.conf
  grep -q 'pi-gateway.conf' /etc/dhcpcd.conf 2>/dev/null || echo 'include /etc/dhcpcd.conf.d/pi-gateway.conf' | sudo tee -a /etc/dhcpcd.conf >/dev/null
  sudo systemctl restart dhcpcd 2>/dev/null || sudo rc-service dhcpcd restart 2>/dev/null || true
fi
if ! command -v log2ram >/dev/null 2>&1; then
  timeout 180 bash -c 'curl -fsSL https://github.com/azlux/log2ram/raw/master/install.sh 2>/dev/null | sudo bash' 2>/dev/null || \
    echo "[bootstrap] log2ram install skipped"
fi
if ! grep -q '^dtparam=watchdog=on' /boot/firmware/config.txt 2>/dev/null; then
  echo 'dtparam=watchdog=on' | sudo tee -a /boot/firmware/config.txt >/dev/null 2>&1 || true
fi
sudo systemctl enable watchdog 2>/dev/null || true
if ! command -v tailscale >/dev/null 2>&1; then
  curl -fsSL https://tailscale.com/install.sh | sh
fi
if [[ -n "$TAILSCALE_AUTHKEY" ]]; then
  timeout 120 sudo tailscale up --auth-key="$TAILSCALE_AUTHKEY" --hostname="$TAILSCALE_HOSTNAME" || true
fi
# DNS gateway: Tailscale MagicDNS (100.100.100.100) dis cozumlemeyi kirar — yerel AdGuard kullan
if command -v tailscale >/dev/null 2>&1 && tailscale status --json 2>/dev/null | python3 -c \
  "import json,sys; sys.exit(0 if json.load(sys.stdin).get('BackendState')=='Running' else 1)" 2>/dev/null; then
  sudo tailscale set --accept-dns=false 2>/dev/null || true
fi
if ! grep -qE '^nameserver[[:space:]]+127\.0\.0\.1' /etc/resolv.conf 2>/dev/null; then
  # 127.0.0.1 = AdGuard. Ikinci = modem — AGH dusunce apt/docker icin son cikis; reklam engellemez.
  _gw="${LAN_GATEWAY:-192.168.1.1}"
  echo -e "nameserver 127.0.0.1\nnameserver ${_gw}" | sudo tee /etc/resolv.conf >/dev/null
  echo "[bootstrap] resolv.conf -> 127.0.0.1 (AdGuard), ${_gw} (AGH-down fallback)"
  unset _gw
fi
if [[ -f "$REMOTE_DIR/scripts/pi/harden-host.sh" ]]; then
  echo "[bootstrap] Host sertlestirme..."
  export REMOTE_DIR
  bash "$REMOTE_DIR/scripts/pi/harden-host.sh" --prepare || {
    echo "[bootstrap] HATA: harden-host basarisiz"
    exit 1
  }
fi
if [[ -f "$REMOTE_DIR/scripts/pi/setup-firewall.sh" ]] && [[ "${ENABLE_UFW:-true}" == "true" ]]; then
  echo "[bootstrap] UFW firewall..."
  export REMOTE_DIR
  bash "$REMOTE_DIR/scripts/pi/setup-firewall.sh" || {
    echo "[bootstrap] HATA: firewall setup basarisiz"
    exit 1
  }
fi
# Persistent journal — USB disconnect loglari reboot sonrasi kalsin
if [[ -d "$REMOTE_DIR/host/systemd/journald.conf.d" ]]; then
  echo "[bootstrap] journald persistent..."
  sudo mkdir -p /etc/systemd/journald.conf.d
  sudo cp "$REMOTE_DIR/host/systemd/journald.conf.d/"*.conf /etc/systemd/journald.conf.d/ 2>/dev/null || true
  sudo mkdir -p /var/log/journal
  sudo systemctl restart systemd-journald 2>/dev/null || true
fi
# JMicron autosuspend off
if [[ -f "$REMOTE_DIR/host/udev/99-pi-gateway-jmicron.rules" ]]; then
  echo "[bootstrap] udev JMicron rules..."
  sudo cp "$REMOTE_DIR/host/udev/99-pi-gateway-jmicron.rules" /etc/udev/rules.d/
  sudo udevadm control --reload-rules 2>/dev/null || true
  sudo udevadm trigger --subsystem-match=usb 2>/dev/null || true
fi
if [[ -f "$REMOTE_DIR/scripts/lib/usb-quirk.sh" ]]; then
  cmdline_target=""
  for candidate in /boot/firmware/cmdline.txt /boot/cmdline.txt /media/*/bootfs/cmdline.txt; do
    [[ -f "$candidate" ]] || continue
    if grep -q "DO NOT EDIT THIS FILE" "$candidate" 2>/dev/null; then
      continue
    fi
    cmdline_target="$candidate"
    break
  done
  if [[ -n "$cmdline_target" ]]; then
    echo "[bootstrap] JMicron cmdline (UAS off + NO_LPM + autosuspend=-1): $cmdline_target"
    if [[ "$REMOTE_DIR" =~ ^/[a-zA-Z0-9._/-]+$ && "$REMOTE_DIR" != *..* ]]; then
      sudo env REMOTE_DIR="$REMOTE_DIR" bash -c \
        "source \"\$REMOTE_DIR/scripts/lib/usb-quirk.sh\"; apply_jmicron_cmdline_file '$cmdline_target' 152d:0583:u" \
        || echo "[bootstrap] WARN: cmdline quirk patch atlandi"
    else
      echo "[bootstrap] WARN: REMOTE_DIR guvenli degil — cmdline skip"
    fi
  else
    echo "[bootstrap] WARN: cmdline.txt bulunamadi (bootfs mount?)"
  fi
fi
for unit in pi-gateway-health.timer pi-gateway-backup.timer pi-gateway-crowdsec-ufw.timer pi-gateway-adguard-filters.timer pi-data-symlink.timer pi-ssd-watch.path pi-ssd-health.timer pi-gateway-ssd-smart.timer pi-gateway-kuma-report.timer pi-gateway-speedtest.timer pi-gateway-quake.timer pi-gateway-ibb.timer pi-gateway-modem-inventory.timer; do
  [[ -f "$REMOTE_DIR/host/systemd/$unit" ]] && sudo cp "$REMOTE_DIR/host/systemd/$unit" "/etc/systemd/system/$unit"
done
install_systemd_unit() {
  local svc="$1"
  local src="$REMOTE_DIR/host/systemd/$svc"
  local dst="/etc/systemd/system/$svc"
  [[ -f "$src" ]] || return 0
  sed -e "s|/home/PI_USER/pi-gateway|${REMOTE_DIR}|g" \
      -e "s|/home/PI_USER|/home/${USER}|g" \
      -e "s|/opt/pi-gateway|${REMOTE_DIR}|g" \
      -e "s|User=PI_USER|User=${USER}|g" \
      -e "s|Group=PI_USER|Group=${USER}|g" \
      -e "s|Environment=PI_USER=PI_USER|Environment=PI_USER=${USER}|g" \
      -e "s|Environment=NOTIFY_OWNER=PI_USER|Environment=NOTIFY_OWNER=${USER}|g" \
      "$src" | sudo tee "$dst" >/dev/null
}
if [[ -x "$REMOTE_DIR/scripts/pi/install-privileged-scripts.sh" ]]; then
  echo "[bootstrap] Root-owned privileged scriptler kuruluyor..."
  privileged_script="$REMOTE_DIR/scripts/pi/install-privileged-scripts.sh"
  REMOTE_DIR="$REMOTE_DIR" bash "$privileged_script"
fi
for svc in pi-gateway-health.service pi-gateway-backup.service pi-gateway-adguard-config.service pi-gateway-adguard-filters.service pi-gateway-health-failure.service pi-gateway-boot-notify.service pi-gateway-crowdsec-ufw.service pi-data-symlink.service pi-data-symlink-repair.service pi-gateway-recover-ro.service pi-gateway-ensure-fstab.service pi-ssd-data.service pi-ssd-watch.service pi-ssd-health.service pi-gateway-ssd-smart.service pi-gateway-kuma-report.service pi-gateway-speedtest.service pi-gateway-quake.service pi-gateway-ibb.service pi-gateway-modem-inventory.service; do
  install_systemd_unit "$svc"
done
# Eski cift-doktor / cift-isim unit'lerini host'tan temizle (health + ADGUARDIMP yeterli)
for stale in pi-gateway-stack-watchdog.timer pi-gateway-stack-watchdog.service \
  pi-gateway-netalertx-names.timer pi-gateway-netalertx-names.service \
  pi-gateway-morning.timer pi-gateway-morning.service pi-gateway-telegram-bot.service; do
  sudo systemctl disable --now "$stale" 2>/dev/null || true
  sudo rm -f "/etc/systemd/system/$stale"
done
sudo rm -f /usr/local/lib/pi-gateway/scripts/pi/stack-watchdog.sh 2>/dev/null || true
sudo systemctl daemon-reload
sudo systemctl enable pi-gateway-health.timer pi-gateway-backup.timer pi-gateway-adguard-config.service pi-gateway-adguard-filters.timer pi-gateway-recover-ro.service pi-gateway-boot-notify.service pi-gateway-kuma-report.timer pi-gateway-speedtest.timer pi-gateway-quake.timer pi-gateway-ibb.timer pi-gateway-modem-inventory.timer 2>/dev/null || true
if [[ "$STORAGE_TYPE" == "hybrid" || "$STORAGE_TYPE" == "ssd-data" ]]; then
  sudo systemctl enable pi-data-symlink.service pi-gateway-ensure-fstab.service pi-data-symlink.timer pi-ssd-watch.path pi-ssd-data.service pi-ssd-health.timer pi-gateway-ssd-smart.timer 2>/dev/null || true
fi
if [[ "${ENABLE_CROWDSEC:-true}" == "true" ]]; then
  sudo systemctl enable --now pi-gateway-crowdsec-ufw.timer 2>/dev/null || true
fi
sudo systemctl start pi-gateway-health.timer pi-gateway-backup.timer pi-gateway-adguard-filters.timer pi-gateway-speedtest.timer pi-gateway-quake.timer pi-gateway-ibb.timer pi-gateway-modem-inventory.timer 2>/dev/null || true
if [[ "$STORAGE_TYPE" == "hybrid" || "$STORAGE_TYPE" == "ssd-data" ]]; then
  sudo systemctl reset-failed pi-ssd-health.service 2>/dev/null || true
  sudo systemctl enable --now pi-ssd-health.timer pi-gateway-ssd-smart.timer 2>/dev/null || true
  sudo systemctl start pi-ssd-health.timer 2>/dev/null || true
fi
if [[ "$STORAGE_TYPE" == "hybrid" || "$STORAGE_TYPE" == "ssd-data" ]]; then
  if [[ -x "$REMOTE_DIR/scripts/pi/ensure-ssd-fstab.sh" ]]; then
    echo "[bootstrap] SSD fstab kontrolu..."
    sudo REMOTE_DIR="$REMOTE_DIR" bash "$REMOTE_DIR/scripts/pi/ensure-ssd-fstab.sh" || {
      echo "[bootstrap] HATA: SSD fstab kontrolu basarisiz"
      exit 1
    }
  fi
  ssd_script="$REMOTE_DIR/scripts/pi/setup-ssd-data.sh"
  if [[ -f "$ssd_script" ]]; then
    echo "[bootstrap] SSD veri diski hazirlaniyor..."
    ssd_env=(REMOTE_DIR="$REMOTE_DIR" STORAGE_TYPE="$STORAGE_TYPE" PI_USER="$USER")
    if [[ ! -f /mnt/ssd/.pi-gateway-initialized ]]; then
      ssd_env+=(PI_SSD_CONFIRM_FORMAT=yes)
    fi
    if ! sudo env "${ssd_env[@]}" bash "$ssd_script"; then
      if [[ "${DNS_DEGRADED_ON_SSD_LOSS:-true}" == "true" || "${STORAGE_FALLBACK_SD:-false}" == "true" ]]; then
        echo "[bootstrap] WARN: SSD yok/hazirlanamadi — DNS degraded (SD data) ile devam"
        touch /run/pi-gateway/storage-degraded 2>/dev/null || \
          sudo mkdir -p /run/pi-gateway && sudo touch /run/pi-gateway/storage-degraded || true
        if [[ -d "$REMOTE_DIR/compose" ]]; then
          sudo docker compose -f "$REMOTE_DIR/compose/docker-compose.yml" \
            --env-file "$REMOTE_DIR/.env" stop \
            n8n uptime-kuma crowdsec dozzle netalertx \
            prometheus grafana node-exporter 2>/dev/null || true
        fi
        if [[ -f "$REMOTE_DIR/scripts/pi/setup-docker-fallback.sh" ]]; then
          sudo env REMOTE_DIR="$REMOTE_DIR" bash \
            "$REMOTE_DIR/scripts/pi/setup-docker-fallback.sh" || {
            echo "[bootstrap] WARN: Docker SD fallback basarisiz"
          }
        fi
      else
        echo "[bootstrap] HATA: SSD veri diski hazirlanamadi (disk takili mi?)"
        exit 1
      fi
    else
      echo "[bootstrap] SSD veri diski OK"
    fi
    if mountpoint -q /mnt/ssd 2>/dev/null; then
      echo "[bootstrap] Veri diski: /mnt/ssd"
      df -h /mnt/ssd | tail -1
    fi
  else
    echo "[bootstrap] HATA: setup-ssd-data.sh yok"
    exit 1
  fi
fi
# Veri dizini: hybrid=symlink, ssd-root=native
if [[ -f "$REMOTE_DIR/scripts/pi/ensure-data-symlink.sh" ]]; then
  echo "[bootstrap] Veri dizini kontrolu..."
  data_script="$REMOTE_DIR/scripts/pi/ensure-data-symlink.sh"
  if [[ "$STORAGE_TYPE" == "hybrid" || "$STORAGE_TYPE" == "ssd-data" ]]; then
    data_args=(repair)
    if [[ -f /run/pi-gateway/storage-degraded ]] || ! mountpoint -q /mnt/ssd 2>/dev/null; then
      data_args+=(--fallback-sd)
    fi
    REMOTE_DIR="$REMOTE_DIR" STORAGE_TYPE="$STORAGE_TYPE" bash "$data_script" "${data_args[@]}" || {
      echo "[bootstrap] HATA: data symlink onarilamadi (/mnt/ssd ve STORAGE_FALLBACK_SD kontrol)"
      exit 1
    }
  else
    REMOTE_DIR="$REMOTE_DIR" STORAGE_TYPE="$STORAGE_TYPE" bash "$data_script" repair || \
      echo "[bootstrap] WARN: data dizin kontrolu atlandi"
  fi
else
  mkdir -p "$REMOTE_DIR/data/adguard/work" "$REMOTE_DIR/data/uptime-kuma" \
    "$REMOTE_DIR/data/n8n" "$REMOTE_DIR/data/crowdsec" \
    "$REMOTE_DIR/data/prometheus" "$REMOTE_DIR/data/grafana"
fi
if [[ "${ENABLE_MONITORING:-true}" == "true" ]] && [[ -x "$REMOTE_DIR/scripts/pi/ensure-monitoring-data.sh" ]]; then
  ensure_mon="$REMOTE_DIR/scripts/pi/ensure-monitoring-data.sh"
  REMOTE_DIR="$REMOTE_DIR" bash "$ensure_mon" || true
fi
sudo chown -R "$USER:$USER" "$REMOTE_DIR/config/adguard" 2>/dev/null || true
if [[ "$STORAGE_TYPE" == "ssd-root" || "$STORAGE_TYPE" == "ssd" ]]; then
  ROOT_SRC="$(findmnt -n -o SOURCE / 2>/dev/null || true)"
  if echo "$ROOT_SRC" | grep -q mmcblk; then
    echo "[bootstrap] HATA: STORAGE_TYPE=$STORAGE_TYPE ama root hala SD ($ROOT_SRC)"
    echo "[bootstrap]       scripts/mac/migrate-sd-boot-ssd-root.sh calistir"
    exit 1
  fi
  echo "[bootstrap] Storage: SSD root OK ($ROOT_SRC)"
fi
sudo mkdir -p /run/pi-gateway/notify 2>/dev/null || true
sudo chown "$USER:$USER" /run/pi-gateway/notify 2>/dev/null || true
sudo chmod 775 /run/pi-gateway/notify 2>/dev/null || true
chmod +x "$REMOTE_DIR"/scripts/pi/*.sh "$REMOTE_DIR"/scripts/lib/*.sh 2>/dev/null || true
bash "$REMOTE_DIR/scripts/pi/harden-host.sh" --sudo-only || {
  echo "[bootstrap] HATA: sudo sertlestirmesi basarisiz"
  exit 1
}
echo "[bootstrap] complete"
