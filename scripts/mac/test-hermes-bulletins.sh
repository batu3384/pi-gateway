#!/usr/bin/env bash
# Hermes bülten yolu emekli. Sözleşme: unit yok, Telegram gönderimi yok, Jarvis bülten yazmaz.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
die() { echo "[test-hermes-bulletins] HATA: $*" >&2; exit 1; }
ok() { echo "[test-hermes-bulletins] OK: $*"; }

[[ ! -f "$ROOT/host/systemd/hermes-gateway.service" ]] || die "hermes-gateway unit duruyor"
! grep -q 'api.telegram.org' "$ROOT/scripts/lib/notify.sh" || die "notify.sh telegram API duruyor"
! grep -q 'api.telegram.org' "$ROOT/scripts/lib/bulletin-post.py" || die "bulletin-post telegram API duruyor"
! grep -q 'setup-hermes-gateway.sh' "$ROOT/scripts/pi/post-deploy.sh" || die "post-deploy hermes kuruyor"
grep -q 'heal-openbot-fleet.sh' "$ROOT/scripts/pi/post-deploy.sh" || die "post-deploy openbot heal yok"
python3 "$ROOT/scripts/lib/bulletin-post.py" --self-check || die "bulletin-post self-check"
grep -q 'Sabah sistem' "$ROOT/scripts/pi/sync-fleet-routines.py" || die "Jarvis sabah sistem rutini yok"
python3 "$ROOT/scripts/pi/sync-fleet-routines.py" --self-check || die "sync-fleet-routines self-check"
bash "$ROOT/scripts/pi/jarvis-health-brief.sh" --self-check || die "jarvis-health-brief self-check"
bash "$ROOT/scripts/pi/render-ultron-pdf.sh" --self-check || die "render-ultron-pdf self-check"
bash "$ROOT/scripts/pi/fleet-shared-rotate.sh" --self-check || die "fleet-shared-rotate self-check"
grep -q '"backupModels"' "$ROOT/scripts/pi/setup-openbot-fleet.sh" || die "setup-openbot-fleet backupModels yok"
ok "hermes yok + openbot filo kontratlari OK"
