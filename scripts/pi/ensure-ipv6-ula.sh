#!/usr/bin/env bash
# Sabit ULA IPv6 (DNS). IPv6 kapatilmaz; GUA/SLAAC kalir.
# Oncelik: ip addr + systemd oneshot (NM keyfile bazi Pi'lerde modify reddeder).
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REMOTE_DIR="${REMOTE_DIR:-/home/${USER}/pi-gateway}"
_PG_ENV_LIB="${SCRIPT_DIR}/../lib/env-file.sh"
PG_SCRIPT_NAME="$(basename "$0")"
# shellcheck source=../lib/env-file.sh
source "${_PG_ENV_LIB:?}"
read_remote_dotenv || { echo "[${PG_SCRIPT_NAME}] HATA: .env dotenv parser hatasi" >&2; exit 1; }

PI_IFACE="${PI_INTERFACE:-eth0}"
ULA="${PI_IPV6_ULA:-}"
[[ -n "$ULA" ]] || { echo "[ipv6-ula] HATA: PI_IPV6_ULA bos (.env)" >&2; exit 1; }
[[ "$ULA" == *:* ]] || { echo "[ipv6-ula] HATA: PI_IPV6_ULA gecersiz: $ULA" >&2; exit 1; }
case "$ULA" in
  */*) ULA_CIDR="$ULA" ;;
  *) ULA_CIDR="${ULA}/64" ;;
esac
ULA_ADDR="${ULA_CIDR%%/*}"

log() { echo "[ipv6-ula] $*"; }

has_ula() {
  ip -6 addr show dev "$PI_IFACE" scope global 2>/dev/null | grep -qw "$ULA_ADDR"
}

install_systemd_unit() {
  local unit_src="$REMOTE_DIR/host/systemd/pi-gateway-ipv6-ula.service"
  local unit_dst="/etc/systemd/system/pi-gateway-ipv6-ula.service"
  [[ -f "$unit_src" ]] || return 0
  # ip addr add mevcutsa exit 2 — SuccessExitStatus ile OK
  sed -e "s|__PI_IFACE__|${PI_IFACE}|g" \
      -e "s|__ULA_CIDR__|${ULA_CIDR}|g" \
      "$unit_src" | sudo tee "$unit_dst" >/dev/null
  sudo systemctl daemon-reload
  sudo systemctl enable pi-gateway-ipv6-ula.service 2>/dev/null || true
  log "systemd pi-gateway-ipv6-ula.service enable"
}

add_ula_now() {
  if has_ula; then
    log "ULA zaten var: $ULA_ADDR ($PI_IFACE)"
    return 0
  fi
  log "ip -6 addr add $ULA_CIDR dev $PI_IFACE"
  sudo ip -6 addr add "$ULA_CIDR" dev "$PI_IFACE" || {
    # already exists race
    has_ula && return 0
    log "HATA: ULA eklenemedi"
    return 1
  }
  has_ula || { log "HATA: ULA dogrulanamadi"; return 1; }
  log "ULA eklendi: $ULA_ADDR"
}

# Opsiyonel: NM destekliyorsa kalici adres de yaz (basarisiz olursa sorun degil)
try_nm_persist() {
  command -v nmcli >/dev/null 2>&1 || return 0
  systemctl is-active NetworkManager >/dev/null 2>&1 || return 0
  local con
  con="$(nmcli -t -f NAME,DEVICE connection show --active | awk -F: -v d="$PI_IFACE" '$2==d{print $1; exit}')"
  [[ -n "$con" ]] || return 0
  if sudo nmcli connection modify "$con" +ipv6.addresses "$ULA_CIDR" 2>/dev/null; then
    log "NM persist OK: $con"
    sudo nmcli connection up "$con" >/dev/null 2>&1 || true
  else
    log "NM persist yok (keyfile) — systemd oneshot kullanilacak"
  fi
}

add_ula_now
try_nm_persist
install_systemd_unit
sudo systemctl start pi-gateway-ipv6-ula.service 2>/dev/null || true

if dig +time=2 +tries=1 @"$ULA_ADDR" cloudflare.com A >/dev/null 2>&1; then
  log "OK: dig @$ULA_ADDR cloudflare.com"
else
  log "WARN: dig @$ULA_ADDR basarisiz — AdGuard/ufw IPv6 sonra kontrol"
fi
log "Tamamlandi — modem RDNSS/IPv6 DNS = $ULA_ADDR"
