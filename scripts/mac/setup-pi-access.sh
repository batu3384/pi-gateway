#!/usr/bin/env bash
# Mac: ssh pi + tarayici kisayollari
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "$SCRIPT_DIR/../lib/common.sh"
load_env

PI_USER="${PI_USER:-pi}"
PI_STATIC_IP="${PI_STATIC_IP:-}"
LAN_DOMAIN="${LAN_DOMAIN:-home}"
[[ -n "$PI_STATIC_IP" ]] || die "PI_STATIC_IP gerekli (.env)"
PANEL_PROTOCOL="${PANEL_PROTOCOL:-}"
if [[ -z "$PANEL_PROTOCOL" ]]; then
  if [[ "${ENABLE_TLS:-false}" == "true" ]]; then
    PANEL_PROTOCOL=https
  else
    PANEL_PROTOCOL=http
  fi
fi
SSH_CONFIG="${HOME}/.ssh/config"
MARKER="# pi-gateway access"

log() { echo "[pi-access] $*"; }

block() {
  cat <<EOF

$MARKER
Host pi
  HostName ${PI_STATIC_IP}
  User ${PI_USER}

Host pi-ts
  HostName pi-gateway
  User ${PI_USER}
EOF
}

if [[ -f "$SSH_CONFIG" ]] && grep -qF "$MARKER" "$SSH_CONFIG"; then
  log "SSH config zaten guncel (~/.ssh/config)"
else
  mkdir -p "${HOME}/.ssh"
  chmod 700 "${HOME}/.ssh"
  block >> "$SSH_CONFIG"
  chmod 600 "$SSH_CONFIG"
  log "SSH eklendi: ssh pi (ev LAN) | ssh pi-ts (Tailscale)"
fi

BIN="${HOME}/.local/bin"
mkdir -p "$BIN"

cat > "${BIN}/pi-open" <<EOF
#!/usr/bin/env bash
open "${PANEL_PROTOCOL}://gateway.${LAN_DOMAIN}"
EOF
chmod +x "${BIN}/pi-open"

cat > "${BIN}/pi-logs" <<EOF
#!/usr/bin/env bash
open "${PANEL_PROTOCOL}://logs.${LAN_DOMAIN}"
EOF
chmod +x "${BIN}/pi-logs"

cat > "${BIN}/pi-status" <<EOF
#!/usr/bin/env bash
open "${PANEL_PROTOCOL}://status.${LAN_DOMAIN}"
EOF
chmod +x "${BIN}/pi-status"

log "Komutlar: pi-open | pi-logs | pi-status"
log "PATH'te ~/.local/bin yoksa: export PATH=\"\$HOME/.local/bin:\$PATH\""

if [[ ":${PATH}:" != *":${BIN}:"* ]]; then
  log "Ipucu: echo 'export PATH=\"\$HOME/.local/bin:\$PATH\"' >> ~/.zshrc"
fi

log "Tamamlandi"
