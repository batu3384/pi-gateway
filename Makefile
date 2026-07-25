# Deploy targeting only — never `include`/export whole .env (secrets leak to recipe env).
env_val = $(shell awk -F= -v k='$(1)' '$$1 == k { sub(/^[^=]*=/, ""); print; exit }' .env 2>/dev/null)

ifneq (,$(wildcard .env))
  PI_USER ?= $(call env_val,PI_USER)
  PI_STATIC_IP ?= $(call env_val,PI_STATIC_IP)
  REMOTE_DIR ?= $(call env_val,REMOTE_DIR)
endif

PI_USER ?= pi
REMOTE_DIR ?= /home/$(PI_USER)/pi-gateway

.PHONY: setup validate render deploy deploy-fast install discover mac-dns harden status dns-test test-remote backup-pull backup-cron verify-data pi-access trust-ca tls-certs telegram-menu firewall morning-test sync-configs docker-ssd check-pi-env

check-pi-env:
	@test -n "$(PI_STATIC_IP)" || (echo "PI_STATIC_IP gerekli — .env duzenle veya make discover" && exit 1)

setup:
	@cp -n .env.example .env 2>/dev/null || true
	@chmod +x scripts/**/*.sh scripts/*.sh 2>/dev/null || true
	@echo "Edit .env then: make install"

validate:
	@./scripts/mac/validate.sh

render:
	@./scripts/mac/render-config.sh

discover:
	@./scripts/mac/discover-remote.sh

deploy:
	@./scripts/mac/deploy.sh

deploy-fast:
	@chmod +x scripts/mac/deploy-fast.sh 2>/dev/null || true
	@./scripts/mac/deploy-fast.sh

sync-configs:
	@chmod +x scripts/mac/sync-rendered-configs.sh 2>/dev/null || true
	@make render && ./scripts/mac/sync-rendered-configs.sh

morning-test: check-pi-env
	@ssh "$(PI_USER)@$(PI_STATIC_IP)" 'REMOTE_DIR="$(REMOTE_DIR)" bash "$(REMOTE_DIR)/scripts/pi/morning-summary.sh"'

verify-data:
	@chmod +x scripts/mac/pre-deploy-check.sh scripts/lib/ensure-data-symlink.sh scripts/pi/ensure-data-symlink.sh 2>/dev/null || true
	@./scripts/mac/pre-deploy-check.sh

install:
	@./scripts/mac/install.sh

mac-dns:
	@./scripts/mac/setup-local-dns.sh

dns-fallback:
	@chmod +x scripts/mac/setup-dns-fallback.sh 2>/dev/null || true
	@./scripts/mac/setup-dns-fallback.sh

syncthing:
	@./scripts/mac/setup-syncthing.sh

harden: check-pi-env
	@ssh "$(PI_USER)@$(PI_STATIC_IP)" "REMOTE_DIR='$(REMOTE_DIR)' bash -s" < ./scripts/pi/harden-host.sh

status:
	@chmod +x scripts/mac/status.sh 2>/dev/null || true
	@./scripts/mac/status.sh

dns-test:
	@chmod +x scripts/mac/dns-test.sh 2>/dev/null || true
	@./scripts/mac/dns-test.sh

test-remote: check-pi-env
	@ssh "$(PI_USER)@$(PI_STATIC_IP)" 'REMOTE_DIR="$(REMOTE_DIR)" bash "$(REMOTE_DIR)/scripts/pi/health-check.sh" && REMOTE_DIR="$(REMOTE_DIR)" bash "$(REMOTE_DIR)/scripts/pi/smoke-test.sh"'

telegram-test: check-pi-env
	@ssh "$(PI_USER)@$(PI_STATIC_IP)" 'REMOTE_DIR="$(REMOTE_DIR)" bash "$(REMOTE_DIR)/scripts/pi/test-telegram.sh"'

telegram-menu: check-pi-env
	@ssh "$(PI_USER)@$(PI_STATIC_IP)" 'REMOTE_DIR="$(REMOTE_DIR)" bash "$(REMOTE_DIR)/scripts/pi/telegram-menu.sh"'

pi-access:
	@chmod +x scripts/mac/setup-pi-access.sh 2>/dev/null || true
	@./scripts/mac/setup-pi-access.sh

trust-ca:
	@chmod +x scripts/mac/trust-caddy-ca.sh 2>/dev/null || true
	@./scripts/mac/trust-caddy-ca.sh

tls-certs:
	@chmod +x scripts/mac/setup-tls-certs.sh 2>/dev/null || true
	@./scripts/mac/setup-tls-certs.sh

pi-open:
	@. ./.env 2>/dev/null; proto=$${PANEL_PROTOCOL:-http}; [ "$${ENABLE_TLS:-false}" = "true" ] && proto=https; open "$$proto://gateway.$${LAN_DOMAIN:-home}"

backup-pull:
	@chmod +x scripts/mac/backup-pull.sh 2>/dev/null || true
	@./scripts/mac/backup-pull.sh

backup-cron:
	@chmod +x scripts/mac/install-backup-cron.sh 2>/dev/null || true
	@./scripts/mac/install-backup-cron.sh

firewall: check-pi-env
	@ssh "$(PI_USER)@$(PI_STATIC_IP)" 'REMOTE_DIR="$(REMOTE_DIR)" bash "$(REMOTE_DIR)/scripts/pi/setup-firewall.sh"'

docker-ssd: check-pi-env
	@scp scripts/pi/setup-docker-ssd.sh "$(PI_USER)@$(PI_STATIC_IP):$(REMOTE_DIR)/scripts/pi/setup-docker-ssd.sh"
	@ssh "$(PI_USER)@$(PI_STATIC_IP)" 'REMOTE_DIR="$(REMOTE_DIR)" bash "$(REMOTE_DIR)/scripts/pi/setup-docker-ssd.sh"'

tailscale-acl: check-pi-env
	@chmod +x scripts/pi/setup-tailscale-acl.sh 2>/dev/null || true
	@ssh "$(PI_USER)@$(PI_STATIC_IP)" 'REMOTE_DIR="$(REMOTE_DIR)" bash "$(REMOTE_DIR)/scripts/pi/setup-tailscale-acl.sh"'

n8n-workflows: check-pi-env
	@chmod +x scripts/pi/setup-n8n-workflows.sh scripts/pi/setup-forgejo-webhook.sh 2>/dev/null || true
	@ssh "$(PI_USER)@$(PI_STATIC_IP)" 'REMOTE_DIR="$(REMOTE_DIR)" bash "$(REMOTE_DIR)/scripts/pi/setup-n8n-workflows.sh" && REMOTE_DIR="$(REMOTE_DIR)" bash "$(REMOTE_DIR)/scripts/pi/setup-uptime-kuma.sh" && REMOTE_DIR="$(REMOTE_DIR)" bash "$(REMOTE_DIR)/scripts/pi/setup-forgejo-webhook.sh"'
