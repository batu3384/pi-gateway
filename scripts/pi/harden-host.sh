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
  local keys="${HOME}/.ssh/authorized_keys"
  local dropin="/etc/ssh/sshd_config.d/00-pi-gateway-ssh.conf"
  if [[ ! -s "$keys" ]]; then
    log "SSH harden atlandi: authorized_keys bos"
    return 0
  fi
  sudo mkdir -p /etc/ssh/sshd_config.d
  sudo rm -f /etc/ssh/sshd_config.d/99-pi-gateway.conf
  sudo tee "$dropin" >/dev/null <<'EOF'
# Pi Gateway: key-only. sshd first-value-wins → filename before 50-cloud-init.conf
# Rollback: rm this file && systemctl reload ssh
# Konsol: HDMI veya SD userconf / raspi-config
PasswordAuthentication no
KbdInteractiveAuthentication no
EOF
  if ! sudo sshd -t; then
    sudo rm -f "$dropin"
    log "HATA: sshd -t fail — drop-in silindi"
    return 1
  fi
  sudo systemctl reload ssh 2>/dev/null || sudo systemctl reload sshd 2>/dev/null || true
  if sudo sshd -T 2>/dev/null | grep -qi '^passwordauthentication yes$'; then
    log "HATA: sshd hâlâ PasswordAuthentication yes — reload/Include sırası"
    return 1
  fi
  log "SSH PasswordAuthentication=no (00-pi-gateway-ssh.conf)"
}

mask_headless_noise() {
  # RP1 display probe — headless Pi'de failed gürültü
  if systemctl list-unit-files rp1-test.service >/dev/null 2>&1; then
    sudo systemctl mask rp1-test.service 2>/dev/null || true
  fi
}

harden_sudo() {
  local user="${PI_USER:-${SUDO_USER:-}}"
  local file="/etc/sudoers.d/99-pi-gateway-password"
  if [[ -z "$user" || "$user" == "root" ]]; then
    user="$(basename "$(dirname "$REMOTE_DIR")")"
  fi
  [[ -n "$user" && "$user" != "root" ]] || {
    log "HATA: sudo sahibi belirlenemedi"
    return 1
  }
  printf '%s ALL=(ALL:ALL) PASSWD: ALL\n' "$user" \
    | sudo tee "$file" >/dev/null
  sudo chmod 440 "$file"
  sudo visudo -cf "$file" >/dev/null
  log "sudo NOPASSWD kapatildi ($file)"
}

main() {
  case "${1:-final}" in
    --prepare)
      disable_rpcbind
      fix_adguard_config_perms
      harden_ssh_password || log "WARN: SSH harden atlandi"
      mask_headless_noise
      log "Hazirlik sertlestirmesi tamamlandi"
      return 0
      ;;
    --sudo-only)
      harden_sudo
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
  harden_sudo
  # UFW post-deploy sonunda uygulanir (caddy-only kurallari ezilmesin)
  log "Tamamlandi"
}

main "$@"
