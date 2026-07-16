#!/usr/bin/env bash
# Mac: Caddy tls internal kok sertifikasini guvenilir yap (tarayici uyarisi gider)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "$SCRIPT_DIR/../lib/common.sh"
load_env

PI_USER="${PI_USER:-batu}"
PI_STATIC_IP="${PI_STATIC_IP:-192.168.1.112}"
CERT_DIR="${HOME}/.local/share/pi-gateway"
CERT_FILE="${CERT_DIR}/caddy-root-ca.crt"
PROFILE_FILE="${CERT_DIR}/pi-gateway-caddy-ca.mobileconfig"
LAN_DOMAIN="${LAN_DOMAIN:-home}"

log() { echo "[trust-ca] $*"; }

mkdir -p "$CERT_DIR"

log "Pi'den Caddy kok sertifikasi aliniyor..."
if ! ssh "${PI_USER}@${PI_STATIC_IP}" \
  'docker exec caddy cat /data/caddy/pki/authorities/local/root.crt' >"$CERT_FILE"; then
  log "HATA: Sertifika alinamadi. Pi ve caddy container calisiyor mu?"
  exit 1
fi

if ! openssl x509 -in "$CERT_FILE" -noout -subject >/dev/null 2>&1; then
  log "HATA: Gecersiz sertifika dosyasi: $CERT_FILE"
  exit 1
fi

cert_b64="$(openssl x509 -in "$CERT_FILE" -outform der | base64 | tr -d '\n')"
payload_uuid="$(uuidgen | tr '[:upper:]' '[:lower:]')"
profile_uuid="$(uuidgen | tr '[:upper:]' '[:lower:]')"

cat >"$PROFILE_FILE" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>PayloadContent</key>
  <array>
    <dict>
      <key>PayloadCertificateFileName</key>
      <string>caddy-root-ca.crt</string>
      <key>PayloadContent</key>
      <data>${cert_b64}</data>
      <key>PayloadDescription</key>
      <string>Pi Gateway Caddy yerel HTTPS kok sertifikasi</string>
      <key>PayloadDisplayName</key>
      <string>Pi Gateway Caddy CA</string>
      <key>PayloadIdentifier</key>
      <string>home.pi-gateway.caddy-ca</string>
      <key>PayloadType</key>
      <string>com.apple.security.root</string>
      <key>PayloadUUID</key>
      <string>${payload_uuid}</string>
      <key>PayloadVersion</key>
      <integer>1</integer>
    </dict>
  </array>
  <key>PayloadDisplayName</key>
  <string>Pi Gateway HTTPS</string>
  <key>PayloadIdentifier</key>
  <string>home.pi-gateway.https</string>
  <key>PayloadRemovalDisallowed</key>
  <false/>
  <key>PayloadType</key>
  <string>Configuration</string>
  <key>PayloadUUID</key>
  <string>${profile_uuid}</string>
  <key>PayloadVersion</key>
  <integer>1</integer>
</dict>
</plist>
EOF

log "Kurulum profili hazir: $PROFILE_FILE"
log "Sistem Ayarlari aciliyor — macOS sifreni isteyebilir."
open "$PROFILE_FILE"

cat <<EOF

=== Simdi ekranda su adimlari yap ===
1) "Pi Gateway HTTPS" profilini Yukle / Install
2) macOS sifreni gir
3) Ayarlar -> Gizlilik ve Guvenlik -> Profiller (veya Genel -> Aygit Yonetimi)
   -> Pi Gateway HTTPS -> Guven / Install
4) Safari'yi tamamen kapat (Cmd+Q) ve tekrar ac
5) https://gateway.${LAN_DOMAIN} ac — yesil kilit olmali

Profil acilmazsa cift tikla: $PROFILE_FILE
Manuel (alternatif): Anahtar Zinciri -> "Caddy Local Authority - 2026 ECC Root"
  -> cift tik -> Guven -> SSL icin: Her Zaman Guven

EOF
