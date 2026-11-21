#!/usr/bin/env bash
# OpenBot provider-runtimes: bozuk indirme / yanlış binary (checksum mismatch) onarımı.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/openbot-paths.sh
source "${SCRIPT_DIR}/../lib/openbot-paths.sh"

STATE_DIR="$(openbot_state_dir)"
PR="${STATE_DIR}/provider-runtimes"
ENV_FILE="/opt/OpenBot/hosted/openbot.env"
ZAI_ENV="${OPENBOT_ZAI_ENV:-/mnt/ssd/openbot/zai.env}"

log() { echo "[repair-provider-runtimes] $*"; }

write_install_record() {
  local root="$1" runtime="$2" version="$3"
  python3 - "$root" "$runtime" "$version" <<'PY'
import hashlib, json, os, sys
root, runtime, version = sys.argv[1:4]
files: dict[str, str] = {}
for dirpath, _, fnames in os.walk(root):
    for fn in fnames:
        if fn == "openbot-install.json":
            continue
        p = os.path.join(dirpath, fn)
        rel = os.path.relpath(p, root).replace("\\", "/")
        h = hashlib.sha256()
        with open(p, "rb") as f:
            for chunk in iter(lambda: f.read(1 << 20), b""):
                h.update(chunk)
        files[rel] = h.hexdigest()
record = {
    "layoutVersion": 1,
    "runtime": runtime,
    "version": version,
    "target": "linux-arm64",
    "files": files,
}
with open(os.path.join(root, "openbot-install.json"), "w", encoding="utf-8") as out:
    json.dump(record, out, separators=(",", ":"))
    out.write("\n")
PY
}

sha_ok() {
  local expect="$1" file="$2"
  local got
  got="$(sha256sum "$file" | awk '{print $1}')"
  [[ "$got" == "$expect" ]] || {
    log "HATA: sha256 uyuşmuyor (beklenen=${expect}, gelen=${got}, dosya=${file})"
    exit 1
  }
}

need_cmd() { command -v "$1" >/dev/null 2>&1 || { log "HATA: $1 yok"; exit 1; }; }
need_cmd curl
need_cmd tar
need_cmd sha256sum

BUN_ASSET_SHA="ab95e7e692a53d25a1baa98ee395a17f5f264aedfb3cb15811432d54142f70eb"
BUN_BIN_SHA="354c2b049c716aca07b2e5cddb887928ac58950675d1258bb6312083917793b6"
OPENCODE_ASSET_SHA="91a937129efdae8eb8c0c5018ae533f9f35117f26ffd9a4d1f7a5f9da1e69306"
AGY_1512_ASSET_SHA="594046de1b91561f7fe16476365e3843038ecca56f5f59af45cf9d3091e43bd4"
AGY_1512_BIN_SHA="f8bb8d22dfb676ac0a69effe534283274f860095bfdca62a7caa69de459784ed"
OPENCODE_BIN_SHA="fc1ad8f2dffed8494e31265837f78d1e6ce5200f5c1c50e953cd9b63e607efdb"

WORKDIR="${OPENBOT_REPAIR_TMP:-/mnt/ssd/openbot-native/tmp/provider-repair}"
mkdir -p "$WORKDIR"
tmpdir="$(mktemp -d "${WORKDIR}/run.XXXXXX")"
cleanup() { rm -rf "$tmpdir"; }
trap cleanup EXIT

log "openbot durduruluyor"
sudo systemctl stop openbot.service

mkdir -p "${PR}"

log "bun 1.4.4 (linux-arm64) yeniden kuruluyor"
curl -fsSL -o "${tmpdir}/bun.tgz" \
  "https://registry.npmjs.org/@oven/bun-linux-aarch64/-/bun-linux-aarch64-1.4.4.tgz"
sha_ok "$BUN_ASSET_SHA" "${tmpdir}/bun.tgz"
mkdir -p "${tmpdir}/bun-ex"
tar -xzf "${tmpdir}/bun.tgz" -C "${tmpdir}/bun-ex"
sha_ok "$BUN_BIN_SHA" "${tmpdir}/bun-ex/package/bin/bun"
dest_bun="${PR}/bun/linux-arm64/1.4.4"
rm -rf "${dest_bun}"
mkdir -p "${dest_bun}/bin"
install -m 0755 "${tmpdir}/bun-ex/package/bin/bun" "${dest_bun}/bin/bun"
install -m 0755 "${tmpdir}/bun-ex/package/bin/bun" "${dest_bun}/bin/bunx"
printf '%s\n' '{"layoutVersion":1,"version":"1.4.4","target":"linux-arm64","executable":"bin/bun"}' \
  >"${dest_bun}/bun-package.json"
[[ -f "${tmpdir}/bun-ex/package/README.md" ]] && \
  cp "${tmpdir}/bun-ex/package/README.md" "${dest_bun}/LICENSE.md"
write_install_record "$dest_bun" bun "1.4.4"

log "bozuk provider indirmeleri temizleniyor"
rm -rf "${PR}/.downloads"/*.partial* 2>/dev/null || true

log "opencode 2.3.2 (linux-arm64) yeniden kuruluyor"
rm -rf "${PR}/opencode" "${PR}/.downloads"/opencode* 2>/dev/null || true
curl -fsSL -o "${tmpdir}/opencode.tgz" \
  "https://registry.npmjs.org/@opencode/cli-linux-arm64/-/cli-linux-arm64-2.3.2.tgz"
sha_ok "$OPENCODE_ASSET_SHA" "${tmpdir}/opencode.tgz"
mkdir -p "${tmpdir}/oc-ex"
tar -xzf "${tmpdir}/opencode.tgz" -C "${tmpdir}/oc-ex"
sha_ok "$OPENCODE_BIN_SHA" "${tmpdir}/oc-ex/package/bin/opencode"
dest_oc="${PR}/opencode/linux-arm64/2.3.2"
mkdir -p "${dest_oc}/bin"
install -m 0755 "${tmpdir}/oc-ex/package/bin/opencode" "${dest_oc}/bin/opencode"
printf '%s\n' '{"layoutVersion":1,"version":"2.3.2","target":"linux-arm64","executable":"bin/opencode"}' \
  >"${dest_oc}/opencode-package.json"
write_install_record "$dest_oc" opencode "2.3.2"

log "antigravity (Gemini CLI) 1.5.12 yeniden kuruluyor"
dest_agy="${PR}/antigravity/linux-arm64/1.5.12"
# Eski/bozuk sürümler (1.5.4 headless'ta SIGSEGV → "Gemini server version cannot be read")
rm -rf "${PR}/antigravity/linux-arm64/1.5.5" \
  "${PR}/antigravity/linux-arm64/1.5.4" \
  "${dest_agy}" 2>/dev/null || true
rm -f "${PR}/.downloads"/antigravity* 2>/dev/null || true
curl -fsSL -o "${tmpdir}/agy.tgz" \
  "https://github.com/google-antigravity/antigravity-cli/releases/download/1.5.12/agy_cli_linux_arm64.tar.gz"
sha_ok "$AGY_1512_ASSET_SHA" "${tmpdir}/agy.tgz"
mkdir -p "${tmpdir}/agy-ex"
tar -xzf "${tmpdir}/agy.tgz" -C "${tmpdir}/agy-ex"
agy_bin="$(find "${tmpdir}/agy-ex" -maxdepth 2 -type f -name antigravity | head -1)"
[[ -n "$agy_bin" ]] || { log "HATA: antigravity binary yok"; exit 1; }
sha_ok "$AGY_1512_BIN_SHA" "$agy_bin"
mkdir -p "${dest_agy}/bin"
install -m 0755 "$agy_bin" "${dest_agy}/bin/antigravity"
printf '%s\n' '{"layoutVersion":1,"version":"1.5.12","target":"linux-arm64","executable":"bin/antigravity"}' \
  >"${dest_agy}/antigravity-package.json"
write_install_record "$dest_agy" antigravity "1.5.12"

log "hosted openbot.env + systemd drop-in → yönetilen runtime yolları"
# openbot-hosted-server openbot.env içinden yalnızca DISPLAY_SIZE ve AUTH_API_URL okur;
# OPENBOT_OPENCODE_PATH ve OPENBOT_ANTIGRAVITY_PATH systemd Environment= ile verilmek zorunda.
sudo tee "$ENV_FILE" >/dev/null <<EOF
OPENBOT_DISPLAY_SIZE=1024x768
OPENBOT_OPENCODE_PATH=${dest_oc}/bin/opencode
OPENBOT_ANTIGRAVITY_PATH=${dest_agy}/bin/antigravity
EOF
sudo mkdir -p /etc/systemd/system/openbot.service.d
sudo tee /etc/systemd/system/openbot.service.d/provider-paths.conf >/dev/null <<EOF
[Service]
Environment=OPENBOT_OPENCODE_PATH=${dest_oc}/bin/opencode
Environment=OPENBOT_ANTIGRAVITY_PATH=${dest_agy}/bin/antigravity
EOF
sudo systemctl disable --now openbot-update.timer 2>/dev/null || true
sudo systemctl daemon-reload

if [[ -f "$ZAI_ENV" ]] && ! grep -q 'source.*zai.env' "${HOME}/.profile" 2>/dev/null; then
  echo "set -a; source ${ZAI_ENV}; set +a" >>"${HOME}/.profile"
fi

if [[ -x "${SCRIPT_DIR}/setup-openbot-zai-jarvis.sh" ]]; then
  REMOTE_DIR="${REMOTE_DIR:-/home/${USER:-batu}/pi-gateway}" \
    bash "${SCRIPT_DIR}/setup-openbot-zai-jarvis.sh" || log "WARN: z.ai/Jarvis senkron atlandı"
fi

log "openbot başlatılıyor"
sudo openbot restart
sleep 8
sudo openbot status | head -10 || true

log "bun doğrulama"
"${dest_bun}/bin/bun" --version
"${dest_oc}/bin/opencode" --version
"${dest_agy}/bin/antigravity" --version 2>/dev/null || log "WARN: antigravity --version headless ortamda atlandı"

log "OK — jarvis-send testi: jarvis-send.sh ping"