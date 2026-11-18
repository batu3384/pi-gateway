#!/usr/bin/env bash
# Host sertlestirme: gereksiz servisler, UFW guncelleme
set -euo pipefail

REMOTE_DIR="${REMOTE_DIR:-/home/${USER}/pi-gateway}"

log() { echo "[harden-host] $*"; }

disable_rpcbind() {
  if systemctl is-active --quiet rpcbind 2>/dev/null || systemctl is-enabled --quiet rpcbind 2>/dev/null; then
    log "rpcbind kapatiliyor (NFS kullanilmiyor)"
    sudo systemctl disable --now rpcbind rpcbind.socket 2>/dev/null || \
      sudo systemctl disable --now rpcbind 2>/dev/null || true
  else
    log "rpcbind zaten kapali"
  fi
}

fix_adguard_config_perms() {
  local cfg="$REMOTE_DIR/config/adguard/AdGuardHome.yaml"
  [[ -f "$cfg" ]] || return 0
  if [[ ! -r "$cfg" ]]; then
    log "AdGuard config izinleri duzeltiliyor"
    sudo chown "${USER}:${USER}" "$cfg"
    chmod 640 "$cfg"
  fi
}

# sshd: ilk değer kazanır — 00- 50-cloud-init.conf'dan önce gelmeli
harden_ssh_password() {
  local target_user="${PI_USER:-${SUDO_USER:-$USER}}"
  local target_home="/home/${target_user}"
  [[ "$target_user" == "root" ]] && target_home="/root"
  local keys="${target_home}/.ssh/authorized_keys"
  local dropin="/etc/ssh/sshd_config.d/00-pi-gateway-ssh.conf"
  if [[ ! -s "$keys" ]]; then
    log "SSH harden atlandi: authorized_keys bos"
    return 0
  fi
  local tmp_ssh=""
  tmp_ssh="$(mktemp)"
  cat >"$tmp_ssh" <<'EOF'
# Pi Gateway: key-only. sshd first-value-wins → filename before 50-cloud-init.conf
# Rollback: rm this file && systemctl reload ssh
# Konsol: HDMI veya SD userconf / raspi-config
PasswordAuthentication no
KbdInteractiveAuthentication no
EOF
  if [[ -f "$dropin" ]] && cmp -s "$tmp_ssh" "$dropin" \
    && [[ ! -e /etc/ssh/sshd_config.d/99-pi-gateway.conf ]] \
    && ! sudo sshd -T 2>/dev/null | grep -qi '^passwordauthentication yes$'; then
    rm -f "$tmp_ssh"
    log "SSH PasswordAuthentication=no zaten aktif"
    return 0
  fi
  sudo mkdir -p /etc/ssh/sshd_config.d
  sudo rm -f /etc/ssh/sshd_config.d/99-pi-gateway.conf
  sudo install -o root -g root -m 644 "$tmp_ssh" "$dropin"
  rm -f "$tmp_ssh"
  if ! sudo sshd -t; then
    sudo rm -f "$dropin"
    log "HATA: sshd -t fail — drop-in silindi"
    return 1
  fi
  sudo systemctl restart ssh 2>/dev/null || sudo systemctl restart sshd 2>/dev/null || true
  if sudo sshd -T 2>/dev/null | grep -qi '^passwordauthentication yes$'; then
    log "HATA: sshd hâlâ PasswordAuthentication yes — reload/Include sırası"
    return 1
  fi
  log "SSH PasswordAuthentication=no (00-pi-gateway-ssh.conf)"
}

mask_headless_noise() {
  # RP1 display probe — Pi 4B'de failed gürültü
  if systemctl list-unit-files rp1-test.service >/dev/null 2>&1; then
    sudo systemctl mask rp1-test.service 2>/dev/null || true
  fi
}

apply_kernel_and_nm_tuning() {
  if [[ -f "$REMOTE_DIR/host/sysctl.d/99-pi-gateway-net.conf" ]]; then
    echo "tcp_bbr" | sudo tee /etc/modules-load.d/pi-gateway-bbr.conf >/dev/null
    sudo modprobe tcp_bbr 2>/dev/null || true
    sudo install -o root -g root -m 644 \
      "$REMOTE_DIR/host/sysctl.d/99-pi-gateway-net.conf" \
      /etc/sysctl.d/99-pi-gateway-net.conf
    sudo /usr/sbin/sysctl -p /etc/sysctl.d/99-pi-gateway-net.conf >/dev/null 2>&1 || true
    sudo /usr/sbin/sysctl --system >/dev/null 2>&1 || true
    log "Kernel sysctl (BBR + fq + ARP flux + zram) uygulandi"
  fi
  if [[ -f "$REMOTE_DIR/host/NetworkManager/dispatcher.d/90-pi-gateway-wifi-failover" ]] \
    && [[ -d /etc/NetworkManager/dispatcher.d ]]; then
    sudo install -o root -g root -m 755 \
      "$REMOTE_DIR/host/NetworkManager/dispatcher.d/90-pi-gateway-wifi-failover" \
      /etc/NetworkManager/dispatcher.d/90-pi-gateway-wifi-failover
    log "NetworkManager eth0->wlan0 failover dispatcher kuruldu"
  fi
  local eth_iface="${PI_INTERFACE:-eth0}"
  local ethtool_bin=""
  ethtool_bin="$(command -v ethtool 2>/dev/null || echo /usr/sbin/ethtool)"
  if [[ -x "$ethtool_bin" ]] && [[ -d "/sys/class/net/${eth_iface}" ]]; then
    if sudo "$ethtool_bin" -K "$eth_iface" rx-udp-gro-forwarding on rx-gro-list off 2>/dev/null; then
      log "Tailscale UDP GRO forwarding etkin (${eth_iface})"
    fi
  fi
  if [[ "$(cat "/sys/class/net/${eth_iface}/carrier" 2>/dev/null || echo 0)" == "1" ]] \
    && command -v nmcli >/dev/null 2>&1; then
    if [[ "$(nmcli radio wifi 2>/dev/null || true)" == "enabled" ]]; then
      sudo nmcli radio wifi off >/dev/null 2>&1 || true
      log "Kablolu ${eth_iface} aktif — Pi Wi-Fi radyosu kapatildi"
    fi
  fi
  local target_user="${PI_USER:-${SUDO_USER:-$USER}}"
  if [[ -d /var/lib/pi-gateway ]] && id "$target_user" >/dev/null 2>&1; then
    sudo chown -R "${target_user}:${target_user}" /var/lib/pi-gateway 2>/dev/null || true
  fi
}

tune_desktop_and_speedtest_cli() {
  local target_user="${PI_USER:-${SUDO_USER:-$USER}}"
  if [[ -d /etc/chromium.d ]]; then
    if mountpoint -q /mnt/ssd 2>/dev/null && id "$target_user" >/dev/null 2>&1; then
      sudo mkdir -p /mnt/ssd/chromium-cache 2>/dev/null || true
      sudo chown "${target_user}:${target_user}" /mnt/ssd/chromium-cache 2>/dev/null || true
      sudo chmod 0700 /mnt/ssd/chromium-cache 2>/dev/null || true
    fi
    local tmp_chr=""
    tmp_chr="$(mktemp)"
    cat >"$tmp_chr" <<'EOF'
# Pi Gateway: /dev/shm + SSD cache + OnDeviceModel/Accessibility kapali (/bin/sh uyumlu)
_pg_clean=""
for _pg_f in $CHROMIUM_FLAGS; do
  case "$_pg_f" in
    --force-renderer-accessibility|--disable-dev-shm-usage) continue ;;
  esac
  _pg_clean="${_pg_clean} ${_pg_f}"
done
CHROMIUM_FLAGS="${_pg_clean} --disable-features=OptimizationGuideModelDownloading,OptimizationHintsFetching,OptimizationTargetPrediction,OptimizationHints --disk-cache-size=134217728"
if grep -qs ' /mnt/ssd ' /proc/mounts && [ -d /mnt/ssd/chromium-cache ] && [ -w /mnt/ssd/chromium-cache ]; then
  CHROMIUM_FLAGS="${CHROMIUM_FLAGS} --disk-cache-dir=/mnt/ssd/chromium-cache"
elif [ -n "${XDG_RUNTIME_DIR:-}" ]; then
  CHROMIUM_FLAGS="${CHROMIUM_FLAGS} --disk-cache-dir=${XDG_RUNTIME_DIR}/chromium-cache"
fi
export CHROMIUM_FLAGS
unset _pg_clean _pg_f
EOF
    sudo rm -f /etc/chromium.d/99-pi-gateway-perf
    sudo install -o root -g root -m 644 "$tmp_chr" /etc/chromium.d/zz-pi-gateway-perf
    rm -f "$tmp_chr"
    log "Chromium masaustu ayari yazildi (/etc/chromium.d/zz-pi-gateway-perf)"
  fi

  if [[ "$(uname -m 2>/dev/null || true)" == "aarch64" ]] && [[ ! -x /usr/local/bin/speedtest ]]; then
    local st_tmp=""
    st_tmp="$(mktemp -d)"
    if curl -fsSL --max-time 25 \
      "https://install.speedtest.net/app/cli/ookla-speedtest-1.2.0-linux-aarch64.tgz" \
      -o "$st_tmp/ookla.tgz" 2>/dev/null \
      && tar -xzf "$st_tmp/ookla.tgz" -C "$st_tmp" speedtest 2>/dev/null \
      && [[ -s "$st_tmp/speedtest" ]]; then
      sudo install -o root -g root -m 755 "$st_tmp/speedtest" /usr/local/bin/speedtest
      log "Ookla native aarch64 speedtest CLI kuruldu (/usr/local/bin/speedtest)"
    else
      log "WARN: Ookla native speedtest CLI indirilemedi (ag/cevrimdisi)"
    fi
    rm -rf "$st_tmp"
  fi
}

# Eski 99-pi-gateway-password (sifreli sudo) kaldirilir: User=PI_USER timer'lari
# (health, ibb, watchdog, ssd-alive state) sudo -n bekler; PI_USER docker grubunda
# zaten root esdegeri — sifre kapisi guvenlik katmadi, otomasyonu kirdi (2026-09-13).
remove_sudo_password_gate() {
  local file="/etc/sudoers.d/99-pi-gateway-password"
  [[ -e "$file" ]] || return 0
  sudo rm -f "$file" && log "eski sudo PASSWD politikasi kaldirildi ($file)"
}

main() {
  case "${1:---final}" in
    --prepare)
      disable_rpcbind
      fix_adguard_config_perms
      harden_ssh_password || log "WARN: SSH harden atlandi"
      mask_headless_noise
      remove_sudo_password_gate
      log "Hazirlik sertlestirmesi tamamlandi"
      return 0
      ;;
    ""|--final)
      ;;
    *)
      log "HATA: bilinmeyen mod: ${1:-}"
      return 2
      ;;
  esac
  disable_rpcbind
  fix_adguard_config_perms
  harden_ssh_password || log "WARN: SSH harden atlandi"
  mask_headless_noise
  remove_sudo_password_gate
  apply_kernel_and_nm_tuning
  tune_desktop_and_speedtest_cli
  # UFW post-deploy sonunda uygulanir (caddy-only kurallari ezilmesin)
  log "Tamamlandi"
}

main "$@"
