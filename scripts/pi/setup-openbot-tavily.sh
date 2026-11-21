#!/usr/bin/env bash
# Tavily, yalnız OpenCode (Jarvis / z.ai). Anahtar ortamdan gelir, repoya yazılmaz.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/openbot-paths.sh
source "${SCRIPT_DIR}/../lib/openbot-paths.sh"
ENVF="${TAVILY_ENV:-/mnt/ssd/openbot/tavily.env}"
if [[ -z "${OPENBOT_BUN:-}" ]]; then
  _bun_root="$(openbot_state_dir)/provider-runtimes/bun/linux-arm64"
  OPENBOT_BUN="$(find "$_bun_root" -maxdepth 3 -type f -name bun -perm -u+x 2>/dev/null | sort -V | tail -1 || true)"
fi
BUN="${OPENBOT_BUN:-$(openbot_state_dir)/provider-runtimes/bun/linux-arm64/1.4.4/bin/bun}"
DROP="/etc/systemd/system/openbot.service.d/tavily-env.conf"

log() { echo "[openbot-tavily] $*"; }
die() { log "HATA: $*"; exit 1; }

[[ -n "${TAVILY_API_KEY:-}" ]] || die "TAVILY_API_KEY yok"
[[ "${TAVILY_API_KEY}" == tvly-* ]] || die "anahtar tvly- ile başlamıyor"
[[ -x "$BUN" ]] || die "bun yok: $BUN"

install -d -m 0755 "$(dirname "$ENVF")"
umask 077
printf 'TAVILY_API_KEY=%s\n' "$TAVILY_API_KEY" >"$ENVF"
chmod 600 "$ENVF"
log "anahtar yazıldı (değer yok): $ENVF"

export BUN_INSTALL="${BUN_INSTALL:-$HOME/.bun}"
cli_link="${BUN_INSTALL}/bin/tvly"
pkg="${BUN_INSTALL}/install/global/node_modules/@tavily"
cache="${BUN_INSTALL}/install/cache/@tavily"
shebang=""
if [[ -L "$cli_link" ]]; then
  shebang="$(head -1 "$(readlink -f "$cli_link")" 2>/dev/null || true)"
fi
if [[ "$shebang" != "#!/usr/bin/env node" ]]; then
  # Bozuk kopya bun önbelleğiyle aynı inode ise yeniden indirme şart.
  rm -rf "$pkg" "$cache"
  "$BUN" install -g @tavily/cli
fi
cli="$(readlink -f "$cli_link")"
[[ -f "$cli" ]] || die "tvly kurulmadı"
[[ "$(head -1 "$cli")" == "#!/usr/bin/env node" ]] || die "tvly paketi bozuk"
wrap="$(mktemp)"
cat >"$wrap" <<EOF
#!/bin/sh
exec ${BUN} ${cli} "\$@"
EOF
sudo rm -f /usr/local/bin/tvly
sudo cp -f "$wrap" /usr/local/bin/tvly
sudo chmod 755 /usr/local/bin/tvly
rm -f "$wrap"
log "tvly sarmalayıcı hazır"

sudo tee "$DROP" >/dev/null <<EOF
[Service]
EnvironmentFile=-${ENVF}
EOF
sudo systemctl daemon-reload
if systemctl is-active --quiet openbot.service 2>/dev/null; then
  sudo systemctl restart openbot.service
fi
log "systemd EnvironmentFile hazır. OpenCode eklentisi: @tavily/opencode-plugin"
