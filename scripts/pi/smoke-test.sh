#!/usr/bin/env bash
set -euo pipefail

export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:${PATH:-}"

REMOTE_DIR="${REMOTE_DIR:-/home/${USER}/pi-gateway}"
# shellcheck source=/dev/null
[[ -f "$REMOTE_DIR/.env" ]] && set -a && source "$REMOTE_DIR/.env" && set +a

PI_STATIC_IP="${PI_STATIC_IP:-127.0.0.1}"
ADGUARD_WEB_PORT="${ADGUARD_WEB_PORT:-8080}"
LAN_DOMAIN="${LAN_DOMAIN:-home}"
FORGEJO_PORT="${FORGEJO_PORT:-3002}"
SYNCTHING_PORT="${SYNCTHING_PORT:-8384}"
N8N_PORT="${N8N_PORT:-5678}"
DOZZLE_PORT="${DOZZLE_PORT:-9999}"
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

if [[ "${STORAGE_TYPE:-hybrid}" == "hybrid" || "${STORAGE_TYPE}" == "ssd-data" ]]; then
  run_check "data-ssd-symlink" bash -c \
    "[[ -L '${REMOTE_DIR}/data' ]] && [[ \"\$(readlink -f '${REMOTE_DIR}/data')\" == '/mnt/ssd/pi-gateway-data' ]]"
  if [[ -f /mnt/ssd/.docker-data-root ]]; then
    run_check "docker-ssd-root" bash -c \
      "docker info 2>/dev/null | grep -q 'Docker Root Dir: ${DOCKER_SSD_ROOT:-/mnt/ssd/docker}'"
  fi
  run_check "root-rw" bash -c '! findmnt -n -o OPTIONS / | tr "," "\n" | grep -qx ro'
  run_check "ssd-fstab" bash -c 'grep -qE "[[:space:]]/mnt/ssd[[:space:]]" /etc/fstab'
  run_check "ssd-mounted" mountpoint -q /mnt/ssd
  run_check "sd-health" bash -c "REMOTE_DIR='${REMOTE_DIR}' bash '${REMOTE_DIR}/scripts/pi/check-sd-health.sh'"
fi

run_check "unbound-5335" dig +time=3 +tries=1 @127.0.0.1 -p 5335 cloudflare.com A
run_check "adguard-53" dig +time=3 +tries=1 @"$PI_STATIC_IP" cloudflare.com A
run_check "adguard-block" bash -c \
  "for d in doubleclick.net googletagmanager.com pagead.l.doubleclick.net; do dig +time=3 +tries=1 @${PI_STATIC_IP} \"\$d\" A | grep -Eq '0.0.0.0|127.0.0.0|NXDOMAIN' || exit 1; done"
run_check "dns-rewrite" bash -c \
  "dig +time=3 +tries=1 @${PI_STATIC_IP} git.${LAN_DOMAIN} A +short | grep -qx '${PI_STATIC_IP}'"
run_check "dns-rewrite-logs" bash -c \
  "dig +time=3 +tries=1 @${PI_STATIC_IP} logs.${LAN_DOMAIN} A +short | grep -qx '${PI_STATIC_IP}'"
run_check "gateway-http" bash -c \
  'if [[ "${ENABLE_TLS:-false}" == "true" ]]; then curl -sfk -o /dev/null --max-time 5 --resolve "gateway.'"${LAN_DOMAIN}"':443:127.0.0.1" "https://gateway.'"${LAN_DOMAIN}"'/"; else curl -sf -o /dev/null --max-time 5 -H "Host: gateway.'"${LAN_DOMAIN}"'" http://127.0.0.1/; fi'
run_check "homepage" curl -fsS "http://127.0.0.1:3040"
run_check "uptime-kuma" curl -fsS "http://127.0.0.1:3001"
run_check "adguard-ui" curl -fsS "http://127.0.0.1:${ADGUARD_WEB_PORT}/"

if [[ "${ENABLE_CADDY:-true}" == "true" ]]; then
  run_check "caddy-logs.home" bash -c \
    'if [[ "${ENABLE_TLS:-false}" == "true" ]]; then code=$(curl -sk -o /dev/null -w "%{http_code}" --resolve "logs.'"${LAN_DOMAIN}"':443:127.0.0.1" "https://logs.'"${LAN_DOMAIN}"'/"); else code=$(curl -s -o /dev/null -w "%{http_code}" -H "Host: logs.'"${LAN_DOMAIN}"'" http://127.0.0.1/); fi; [[ "$code" == "200" || "$code" == "401" || "$code" == "307" || "$code" == "302" ]]'
fi

if [[ "${ENABLE_DOZZLE:-true}" == "true" ]]; then
  run_check "dozzle" curl -fsS -u "${DOZZLE_ADMIN_USER:-batu}:${DOZZLE_ADMIN_PASSWORD}" "http://127.0.0.1:${DOZZLE_PORT}/"
fi

if [[ "${ENABLE_FORGEJO:-true}" == "true" ]]; then
  run_check "forgejo" bash -c \
    "for _ in 1 2 3 4 5; do curl -fsS \"http://127.0.0.1:${FORGEJO_PORT}/\" >/dev/null && exit 0; sleep 3; done; exit 1"
fi

if [[ "${ENABLE_SYNCTHING:-true}" == "true" ]]; then
  run_check "syncthing" curl -fsS "http://127.0.0.1:${SYNCTHING_PORT}/"
fi

if [[ "${ENABLE_REDIS:-true}" == "true" ]]; then
  run_check "redis" docker exec redis redis-cli ping
fi

if [[ "${ENABLE_N8N:-true}" == "true" ]]; then
  run_check "n8n" bash -c \
    "for _ in 1 2 3 4 5; do curl -fsS \"http://127.0.0.1:${N8N_PORT}/\" >/dev/null && exit 0; sleep 4; done; exit 1"
fi

if [[ "${ENABLE_CROWDSEC:-true}" == "true" ]]; then
  run_check "crowdsec" bash -c \
    'code=$(curl -s -o /dev/null -w "%{http_code}" "http://127.0.0.1:8082/v1/heartbeat"); [[ "$code" == "200" || "$code" == "401" ]]'
fi

if [[ "${ENABLE_UFW:-true}" == "true" ]] && [[ -x /usr/sbin/ufw ]]; then
  run_check "ufw-active" bash -c 'sudo -n /usr/sbin/ufw status | grep -q "Status: active"'
  run_check "ufw-dns-lan" bash -c \
    "sudo -n /usr/sbin/ufw status | grep -E '53/(tcp|udp)' | grep -q '${LAN_SUBNET_CIDR:-192.168.1.0/24}'"
  if [[ "$UFW_ADMIN_EXPOSURE" == "caddy-only" ]]; then
    run_check "ufw-caddy-only" bash -c \
      "! sudo -n /usr/sbin/ufw status | grep -E 'pi-gateway (9999|8080|3001|8384)' | grep -q '${LAN_SUBNET_CIDR:-192.168.1.0/24}'"
  fi
fi

echo "Smoke test: $pass/$checks passed"
[[ "$pass" -eq "$checks" ]]
