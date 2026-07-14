#!/usr/bin/env bash
set -euo pipefail

REMOTE_DIR="${REMOTE_DIR:-/home/${USER}/pi-gateway}"
PI_INTERFACE="${PI_INTERFACE:-eth0}"
TAILSCALE_AUTHKEY="${TAILSCALE_AUTHKEY:-}"
TAILSCALE_HOSTNAME="${TAILSCALE_HOSTNAME:-pi-gateway}"
STORAGE_TYPE="${STORAGE_TYPE:-hybrid}"
ENABLE_CROWDSEC="${ENABLE_CROWDSEC:-true}"

# shellcheck source=/dev/null
[[ -f "$REMOTE_DIR/.env" ]] && source "$REMOTE_DIR/.env"
STORAGE_TYPE="${STORAGE_TYPE:-hybrid}"
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
  curl -fsSL https://github.com/azlux/log2ram/raw/master/install.sh | sudo bash || echo "[bootstrap] log2ram install skipped"
fi

if ! grep -q '^dtparam=watchdog=on' /boot/firmware/config.txt 2>/dev/null; then
  echo 'dtparam=watchdog=on' | sudo tee -a /boot/firmware/config.txt >/dev/null 2>&1 || true
fi
sudo systemctl enable watchdog 2>/dev/null || true

if ! command -v tailscale >/dev/null 2>&1; then
  curl -fsSL https://tailscale.com/install.sh | sh
fi
if [[ -n "$TAILSCALE_AUTHKEY" ]]; then
  sudo tailscale up --auth-key="$TAILSCALE_AUTHKEY" --hostname="$TAILSCALE_HOSTNAME" || true
fi

if [[ -f "$REMOTE_DIR/scripts/pi/harden-host.sh" ]]; then
  echo "[bootstrap] Host sertlestirme..."
  export REMOTE_DIR
  bash "$REMOTE_DIR/scripts/pi/harden-host.sh" || \
    echo "[bootstrap] WARN: harden-host atlandi"
elif [[ -f "$REMOTE_DIR/scripts/pi/setup-firewall.sh" ]]; then
  echo "[bootstrap] Host guvenligi (UFW + fail2ban)..."
  export REMOTE_DIR
  bash "$REMOTE_DIR/scripts/pi/setup-firewall.sh" || \
    echo "[bootstrap] WARN: firewall setup atlandi"
fi

for unit in pi-gateway-health.timer pi-gateway-backup.timer pi-gateway-crowdsec-ufw.timer; do
  [[ -f "$REMOTE_DIR/host/systemd/$unit" ]] && sudo cp "$REMOTE_DIR/host/systemd/$unit" "/etc/systemd/system/$unit"
done
for svc in pi-gateway-health.service pi-gateway-backup.service pi-gateway-adguard-config.service pi-gateway-health-failure.service pi-gateway-crowdsec-ufw.service pi-data-symlink.service; do
  if [[ -f "$REMOTE_DIR/host/systemd/$svc" ]]; then
    sudo cp "$REMOTE_DIR/host/systemd/$svc" "/etc/systemd/system/$svc"
    sudo sed -i "s|PI_USER|${USER}|g" "/etc/systemd/system/$svc" 2>/dev/null || \
      sudo sed -i '' "s|PI_USER|${USER}|g" "/etc/systemd/system/$svc" 2>/dev/null || true
    sudo sed -i "s|/home/PI_USER/pi-gateway|$REMOTE_DIR|g" "/etc/systemd/system/$svc" 2>/dev/null || \
      sudo sed -i '' "s|/home/PI_USER/pi-gateway|$REMOTE_DIR|g" "/etc/systemd/system/$svc" 2>/dev/null || true
    sudo sed -i "s|/opt/pi-gateway|$REMOTE_DIR|g" "/etc/systemd/system/$svc" 2>/dev/null || \
      sudo sed -i '' "s|/opt/pi-gateway|$REMOTE_DIR|g" "/etc/systemd/system/$svc" 2>/dev/null || true
  fi
done
sudo systemctl daemon-reload
sudo systemctl enable pi-gateway-health.timer pi-gateway-backup.timer pi-gateway-adguard-config.service pi-data-symlink.service 2>/dev/null || true
if [[ "${ENABLE_CROWDSEC:-true}" == "true" ]]; then
  sudo systemctl enable --now pi-gateway-crowdsec-ufw.timer 2>/dev/null || true
fi
sudo systemctl start pi-gateway-health.timer pi-gateway-backup.timer 2>/dev/null || true

if [[ "$STORAGE_TYPE" == "hybrid" || "$STORAGE_TYPE" == "ssd-data" ]]; then
  if [[ -x /usr/local/sbin/pi-setup-ssd-data.sh ]]; then
    echo "[bootstrap] SSD veri diski hazirlaniyor..."
    sudo PI_USER="$USER" REMOTE_DIR="$REMOTE_DIR" /usr/local/sbin/pi-setup-ssd-data.sh || \
      echo "[bootstrap] WARN: SSD setup atlandi (disk takili degil veya henuz hazir degil)"
  fi
  if mountpoint -q /mnt/ssd 2>/dev/null; then
    echo "[bootstrap] Veri diski: /mnt/ssd"
    df -h /mnt/ssd | tail -1
  fi
fi

# Veri dizini: SSD symlink (hybrid) — mkdir ile SD uzerinde data/ OLUSTURMA
if [[ -f "$REMOTE_DIR/scripts/pi/ensure-data-symlink.sh" ]]; then
  echo "[bootstrap] Veri dizini symlink kontrolu..."
  REMOTE_DIR="$REMOTE_DIR" STORAGE_TYPE="$STORAGE_TYPE" bash "$REMOTE_DIR/scripts/pi/ensure-data-symlink.sh" repair || \
    echo "[bootstrap] WARN: data symlink atlandi"
else
  mkdir -p "$REMOTE_DIR/data/adguard/work" "$REMOTE_DIR/data/uptime-kuma" \
    "$REMOTE_DIR/data/forgejo" "$REMOTE_DIR/data/syncthing" "$REMOTE_DIR/data/projects" \
    "$REMOTE_DIR/data/redis" "$REMOTE_DIR/data/n8n" "$REMOTE_DIR/data/crowdsec"
fi
sudo chown -R "$USER:$USER" "$REMOTE_DIR/config/adguard" 2>/dev/null || true

if [[ "$STORAGE_TYPE" == "ssd" ]]; then
  ROOT_DEV="$(findmnt -n -o SOURCE / | sed 's/p[0-9]*$//')"
  if echo "$ROOT_DEV" | grep -q mmcblk; then
    echo "[bootstrap] WARN: OS still on SD card. Migrate to USB SSD for production use."
  else
    echo "[bootstrap] Storage: non-SD root detected ($ROOT_DEV)"
  fi
fi

echo "[bootstrap] complete"
