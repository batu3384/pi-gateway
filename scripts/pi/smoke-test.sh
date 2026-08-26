#!/usr/bin/env bash
set -euo pipefail
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:${PATH:-}"
REMOTE_DIR="${REMOTE_DIR:-/home/${USER}/pi-gateway}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_PG_ENV_LIB="${SCRIPT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}/../lib/env-file.sh"
PG_SCRIPT_NAME="$(basename "$0")"
# shellcheck source=../lib/env-file.sh
source "${_PG_ENV_LIB:?}"
read_remote_dotenv || { echo "[${PG_SCRIPT_NAME:-script}] HATA: .env dotenv parser hatasi" >&2; exit 1; }
PI_STATIC_IP="${PI_STATIC_IP:-127.0.0.1}"
ADGUARD_WEB_PORT="${ADGUARD_WEB_PORT:-8080}"
LAN_DOMAIN="${LAN_DOMAIN:-home}"
N8N_PORT="${N8N_PORT:-5678}"
DOZZLE_PORT="${DOZZLE_PORT:-9999}"
NETALERTX_PORT="${NETALERTX_PORT:-20211}"
NETALERTX_LISTEN_ADDR="${NETALERTX_LISTEN_ADDR:-172.17.0.1}"
UFW_ADMIN_EXPOSURE="${UFW_ADMIN_EXPOSURE:-caddy-only}"
checks=0
pass=0
run_check() {
  local name="$1"; shift
  checks=$((checks + 1))
  if "$@" >/dev/null 2>&1; then
    echo "PASS $name"
    pass=$((pass + 1))
  else
    echo "FAIL $name"
  fi
}
CADDY_AUTH_USER="${CADDY_AUTH_USER:-${AGH_ADMIN_USER:-admin}}"
CADDY_AUTH_PASSWORD="${CADDY_AUTH_PASSWORD:-${AGH_ADMIN_PASSWORD:-}}"
run_caddy_auth_checks() {
  local host="$1"
  local resolve_ip="${PI_STATIC_IP:-127.0.0.1}"
  run_check "caddy-${host}-auth-deny" bash -c \
    'if [[ "${ENABLE_TLS:-false}" == "true" ]]; then code=$(curl -sk -o /dev/null -w "%{http_code}" --max-time 5 --resolve "'"${host}"'.'"${LAN_DOMAIN}"':443:'"${resolve_ip}"'" "https://'"${host}"'.'"${LAN_DOMAIN}"'/"); else code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 -H "Host: '"${host}"'.'"${LAN_DOMAIN}"'" http://127.0.0.1/); fi; [[ "$code" == "401" ]]'
  run_check "caddy-${host}-auth-ok" bash -c \
    'if [[ "${ENABLE_TLS:-false}" == "true" ]]; then code=$(curl -sk -o /dev/null -w "%{http_code}" --max-time 5 -u "'"${CADDY_AUTH_USER}"':'"${CADDY_AUTH_PASSWORD}"'" --resolve "'"${host}"'.'"${LAN_DOMAIN}"':443:'"${resolve_ip}"'" "https://'"${host}"'.'"${LAN_DOMAIN}"'/"); else code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 -u "'"${CADDY_AUTH_USER}"':'"${CADDY_AUTH_PASSWORD}"'" -H "Host: '"${host}"'.'"${LAN_DOMAIN}"'" http://127.0.0.1/); fi; [[ "$code" == "200" || "$code" == "302" || "$code" == "307" ]]'
}
DEGRADED=0
if [[ -f /run/pi-gateway/storage-degraded ]]; then
  DEGRADED=1
fi
if [[ "$STORAGE_TYPE" == "ssd-root" || "$STORAGE_TYPE" == "ssd" ]]; then
  run_check "root-on-ssd" bash -c '! findmnt -n -o SOURCE / | grep -q mmcblk'
  run_check "root-rw" bash -c '! findmnt -n -o OPTIONS / | tr "," "\n" | grep -qx ro'
  run_check "data-native" bash -c \
    "[[ -d '${REMOTE_DIR}/data' && ! -L '${REMOTE_DIR}/data' ]]"
  run_check "sd-health" bash -c "REMOTE_DIR='${REMOTE_DIR}' bash '${REMOTE_DIR}/scripts/pi/check-sd-health.sh'"
elif [[ "$STORAGE_TYPE" == "hybrid" || "$STORAGE_TYPE" == "ssd-data" ]]; then
  if [[ "$DEGRADED" -eq 1 ]]; then
    run_check "data-sd-fallback" bash -c \
      "[[ -d '${REMOTE_DIR}/data' && ! -L '${REMOTE_DIR}/data' ]]"
  else
    run_check "data-ssd-symlink" bash -c \
      "[[ -L '${REMOTE_DIR}/data' ]] && [[ \"\$(readlink -f '${REMOTE_DIR}/data')\" == '/mnt/ssd/pi-gateway-data' ]]"
    run_check "ssd-mounted" mountpoint -q /mnt/ssd
  fi
  if [[ -f /mnt/ssd/.docker-data-root ]]; then
    run_check "docker-ssd-root" bash -c \
      "docker info 2>/dev/null | grep -q 'Docker Root Dir: ${DOCKER_SSD_ROOT:-/mnt/ssd/docker}'"
    if [[ "${CONTAINERD_ON_SSD:-false}" == "true" ]]; then
      run_check "containerd-ssd-root" bash -c \
        "grep -E '^root\\s*=' /etc/containerd/config.toml | grep -q '${CONTAINERD_SSD_ROOT:-/mnt/ssd/containerd}'"
    fi
  fi
  run_check "root-rw" bash -c '! findmnt -n -o OPTIONS / | tr "," "\n" | grep -qx ro'
  run_check "ssd-fstab" bash -c 'grep -qE "[[:space:]]/mnt/ssd[[:space:]]" /etc/fstab'
  run_check "ssd-health-timer" systemctl is-active pi-ssd-health.timer
  if [[ "$DEGRADED" -eq 0 ]]; then
    run_check "sd-health" bash -c "REMOTE_DIR='${REMOTE_DIR}' bash '${REMOTE_DIR}/scripts/pi/check-sd-health.sh'"
  fi
fi
run_check "unbound-5335" dig +time=3 +tries=1 @127.0.0.1 -p 5335 cloudflare.com A
run_check "adguard-53" dig +time=3 +tries=1 @"$PI_STATIC_IP" cloudflare.com A
run_check "adguard-block" bash -c \
  "for d in doubleclick.net googletagmanager.com pagead.l.doubleclick.net; do dig +time=3 +tries=1 @${PI_STATIC_IP} \"\$d\" A | grep -Eq '0.0.0.0|127.0.0.0|NXDOMAIN' || exit 1; done"
run_check "dns-rewrite" bash -c \
  "dig +time=3 +tries=1 @${PI_STATIC_IP} gateway.${LAN_DOMAIN} A +short | grep -qx '${PI_STATIC_IP}'"
run_check "dns-rewrite-logs" bash -c \
  "dig +time=3 +tries=1 @${PI_STATIC_IP} logs.${LAN_DOMAIN} A +short | grep -qx '${PI_STATIC_IP}'"
run_check "dns-rewrite-devices" bash -c \
  "dig +time=3 +tries=1 @${PI_STATIC_IP} devices.${LAN_DOMAIN} A +short | grep -qx '${PI_STATIC_IP}'"
if [[ "${ENABLE_MONITORING:-true}" == "true" ]]; then
  run_check "dns-rewrite-grafana" bash -c \
    "dig +time=3 +tries=1 @${PI_STATIC_IP} grafana.${LAN_DOMAIN} A +short | grep -qx '${PI_STATIC_IP}'"
fi
# Degraded: sadece DNS (+ opsiyonel caddy/homepage). App panel smoke yok.
if [[ "$DEGRADED" -eq 1 ]]; then
  run_check "adguard-ui" curl -fsS "http://127.0.0.1:${ADGUARD_WEB_PORT}/"
  run_check "privileged-lib-installed" test -x /usr/local/lib/pi-gateway/scripts/pi/recover-readonly-root.sh
  echo "Smoke test (degraded/core-dns): $pass/$checks passed"
  [[ "$pass" -eq "$checks" ]]
  exit $?
fi
if [[ "${ENABLE_CADDY:-true}" == "true" ]]; then
  auth_pass="${CADDY_AUTH_PASSWORD:-${AGH_ADMIN_PASSWORD:-}}"
  case "${auth_pass}" in
    ""|CHANGE_ME*|Degistir*)
      run_check "caddy-auth-configured" bash -c 'echo "CADDY_AUTH_PASSWORD/AGH_ADMIN_PASSWORD placeholder"; exit 1'
      ;;
    *)
      run_caddy_auth_checks "gateway"
      run_caddy_auth_checks "status"
      run_caddy_auth_checks "logs"
      run_caddy_auth_checks "dns"
      if [[ "${ENABLE_N8N:-true}" == "true" ]]; then
        run_caddy_auth_checks "n8n"
      fi
      if [[ "${ENABLE_NETALERTX:-true}" == "true" ]]; then
        run_check "netalertx-caddy-no-basic-auth" bash -c \
          'base="https://devices.'"${LAN_DOMAIN}"'"; resolve="--resolve devices.'"${LAN_DOMAIN}"':443:'"${PI_STATIC_IP}"'"; \
          code=$(curl -sk -o /dev/null -w "%{http_code}" --max-time 5 $resolve "$base/"); \
          [[ "$code" == "200" || "$code" == "302" ]] && \
          ! curl -skI --max-time 5 $resolve "$base/" | grep -qi "www-authenticate: Basic"'
      fi
      ;;
  esac
fi
run_check "homepage" curl -fsS "http://127.0.0.1:3040"
run_check "uptime-kuma" curl -fsS "http://127.0.0.1:3001"
run_check "adguard-ui" curl -fsS "http://127.0.0.1:${ADGUARD_WEB_PORT}/"
if [[ "${ENABLE_CADDY:-true}" == "true" ]] && [[ -z "${CADDY_AUTH_PASSWORD:-}" ]]; then
  run_check "gateway-http" bash -c \
    'if [[ "${ENABLE_TLS:-false}" == "true" ]]; then code=$(curl -sk -o /dev/null -w "%{http_code}" --max-time 5 --resolve "gateway.'"${LAN_DOMAIN}"':443:'"${PI_STATIC_IP}"'" "https://gateway.'"${LAN_DOMAIN}"'/"); else code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 -H "Host: gateway.'"${LAN_DOMAIN}"'" "http://'"${PI_STATIC_IP}"'/"); fi; [[ "$code" == "200" || "$code" == "401" || "$code" == "302" || "$code" == "307" ]]'
fi
if [[ "${ENABLE_DOZZLE:-true}" == "true" ]]; then
  run_check "dozzle" curl -fsS -u "${DOZZLE_ADMIN_USER:-admin}:${DOZZLE_ADMIN_PASSWORD}" "http://127.0.0.1:${DOZZLE_PORT}/"
fi
if [[ "${ENABLE_N8N:-true}" == "true" ]]; then
  run_check "n8n" bash -c \
    "for _ in 1 2 3 4 5; do curl -fsS \"http://127.0.0.1:${N8N_PORT}/\" >/dev/null && exit 0; sleep 4; done; exit 1"
  case "${N8N_WEBHOOK_SECRET:-}" in
    ""|CHANGE_ME*) ;;
    *)
      run_check "n8n-kuma-telegram-off" bash -c \
        'code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 -X POST \
          "http://127.0.0.1:'"${N8N_PORT}"'/webhook/uptime-kuma-alert-'"${N8N_WEBHOOK_SECRET}"'" \
          -H "Content-Type: application/json" \
          -d "{\"heartbeat\":{\"status\":1,\"msg\":\"smoke\"},\"monitor\":{\"name\":\"Smoke Test\"}}"); \
          [[ "$code" != "200" ]]'
      ;;
  esac
fi
if [[ "${ENABLE_NETALERTX:-true}" == "true" ]]; then
  run_check "netalertx" bash -c \
    "for _ in 1 2 3 4 5 6; do curl -fsS -L \"http://${NETALERTX_LISTEN_ADDR:-127.0.0.1}:${NETALERTX_PORT}/\" >/dev/null && exit 0; sleep 5; done; exit 1"
fi
run_check "privileged-lib-installed" test -x /usr/local/lib/pi-gateway/scripts/pi/recover-readonly-root.sh
run_check "privileged-lib-sync" diff -q \
  "${REMOTE_DIR}/scripts/lib/stack-health.sh" \
  /usr/local/lib/pi-gateway/scripts/lib/stack-health.sh
run_check "privileged-lib-hash" bash -c \
  '[[ -f /usr/local/lib/pi-gateway/.installed-sha256 ]] && (cd /usr/local/lib/pi-gateway && sha256sum -c .installed-sha256 >/dev/null)'
if [[ "$DEGRADED" -eq 0 ]]; then
  run_check "gateway-state-json" test -f /var/lib/pi-gateway/state.json
  run_check "gateway-metrics-prom" test -f /var/lib/pi-gateway/metrics/pi_gateway.prom
  run_check "gateway-state-container" bash -c 'docker ps --format "{{.Names}}" | grep -qx gateway-state'
  run_check "gateway-state-http" bash -c \
    'docker exec gateway-state wget -q -O- http://127.0.0.1/state.json | grep -q storage_degraded'
fi
if [[ "${ENABLE_MONITORING:-true}" == "true" ]]; then
  run_check "prometheus-container" bash -c 'docker ps --format "{{.Names}}" | grep -qx prometheus'
  run_check "grafana-container" bash -c 'docker ps --format "{{.Names}}" | grep -qx grafana'
  run_check "node-exporter-container" bash -c 'docker ps --format "{{.Names}}" | grep -qx node-exporter'
  run_check "prometheus-ready" bash -c \
    'curl -fsS --max-time 5 http://127.0.0.1:9090/-/ready | grep -qi ready'
  run_check "grafana-ready" bash -c \
    'curl -fsS --max-time 5 http://127.0.0.1:'"${GRAFANA_PORT:-3030}"'/api/health | grep -q ok'
fi
if [[ "${ENABLE_CROWDSEC:-true}" == "true" ]]; then
  run_check "crowdsec" bash -c \
    'code=$(curl -s -o /dev/null -w "%{http_code}" "http://127.0.0.1:8082/v1/heartbeat"); [[ "$code" == "200" || "$code" == "401" ]]'
fi
if [[ "${NETWORK_MODE:-router-dns}" == "adguard-dhcp" ]]; then
  run_check "adguard-dhcp-config" bash -c \
    'grep -A5 "^dhcp:" "'"${REMOTE_DIR}"'/config/adguard/AdGuardHome.yaml" | grep -q "enabled: true"'
fi
if [[ "${ENABLE_UFW:-true}" == "true" ]] && [[ -x /usr/sbin/ufw ]]; then
  run_check "ufw-active" bash -c 'sudo -n /usr/sbin/ufw status | grep -q "Status: active"'
  run_check "ufw-ssh-lan" bash -c \
    "sudo -n /usr/sbin/ufw status | grep -E '22/tcp' | grep -q '${LAN_SUBNET_CIDR:-192.168.1.0/24}'"
  run_check "ufw-dns-lan" bash -c \
    "sudo -n /usr/sbin/ufw status | grep -E '53/(tcp|udp)' | grep -q '${LAN_SUBNET_CIDR:-192.168.1.0/24}'"
  if [[ "$UFW_ADMIN_EXPOSURE" == "caddy-only" ]]; then
    run_check "ufw-caddy-only" bash -c \
      "! sudo -n /usr/sbin/ufw status | grep -E 'pi-gateway (9999|8080|3001)' | grep -q '${LAN_SUBNET_CIDR:-192.168.1.0/24}'"
    run_check "adguard-ui-ufw-no-lan" bash -c \
      "! sudo -n /usr/sbin/ufw status numbered | grep -E '8080/tcp' | grep -q '${LAN_SUBNET_CIDR:-192.168.1.0/24}'"
    # Docker UFW'yi bypass eder — bind gercekten localhost olmali (AdGuard host:0.0.0.0 kasıtlı — UFW blok)
    run_check "admin-ports-localhost" bash -c \
      '! ss -lnt | grep -E ":(3040|3001|5678|9999)\\b" | grep -vE "127\\.0\\.0\\.1|\\[::1\\]" | grep -q .'
    if [[ "${ENABLE_NETALERTX:-true}" == "true" ]]; then
      run_check "netalertx-ufw-caddy-only" bash -c \
        '! sudo -n /usr/sbin/ufw status | grep -E ":'"${NETALERTX_PORT:-20211}"'\\b" | grep -q "${LAN_SUBNET_CIDR:-192.168.1.0/24}"'
    fi
  fi
fi
if command -v tailscale >/dev/null 2>&1 && tailscale status >/dev/null 2>&1; then
  run_check "tailscale-connected" tailscale status
  case "${TAILSCALE_ACL_OWNER:-}" in
    ""|CHANGE_ME*) ;;
    *)
      run_check "tailscale-acl-rendered" test -f "${REMOTE_DIR}/config/tailscale/acl.hujson"
      run_check "tailscale-acl-owner" grep -Fq "${TAILSCALE_ACL_OWNER}" "${REMOTE_DIR}/config/tailscale/acl.hujson"
      ;;
  esac
  run_check "tailscale-serve" bash -c 'tailscale serve status 2>/dev/null | grep -qE "443|https"'
fi
echo "Smoke test: $pass/$checks passed"
[[ "$pass" -eq "$checks" ]]
