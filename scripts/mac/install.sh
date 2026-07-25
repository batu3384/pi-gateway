#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "$SCRIPT_DIR/../lib/common.sh"

if [[ ! -f "$PROJECT_DIR/.env" ]]; then
  cp "$PROJECT_DIR/.env.example" "$PROJECT_DIR/.env"
  log "Created .env from example — edit passwords then re-run"
  die "Edit .env (AGH_ADMIN_PASSWORD, service passwords) then: make doctor && make install"
fi

load_env

# Prefer explicit PI_HOST; fall back to discovered static IP
if [[ -z "${PI_HOST:-}" && -n "${PI_STATIC_IP:-}" ]]; then
  PI_HOST="$PI_STATIC_IP"
  export PI_HOST
  log "Using PI_STATIC_IP as PI_HOST ($PI_HOST)"
fi

if [[ -z "${PI_HOST:-}" ]]; then
  read -r -p "Pi temporary IP (DHCP): " PI_HOST
  export PI_HOST
  if grep -q '^PI_HOST=' "$PROJECT_DIR/.env"; then
    sed -i.bak "s|^PI_HOST=.*|PI_HOST=$PI_HOST|" "$PROJECT_DIR/.env"
  else
    echo "PI_HOST=$PI_HOST" >> "$PROJECT_DIR/.env"
  fi
  rm -f "$PROJECT_DIR/.env.bak"
  load_env
fi

log "Step 0/4 Prerequisites (doctor)"
"$SCRIPT_DIR/doctor.sh"

log "Step 1/4 Network discovery"
"$SCRIPT_DIR/discover-remote.sh"

log "Step 2/4 Render configs"
load_env
"$SCRIPT_DIR/render-config.sh"

log "Step 3/4 Validate"
"$SCRIPT_DIR/validate.sh"

log "Step 4/4 Deploy"
"$SCRIPT_DIR/deploy.sh"

log "Production install finished"
