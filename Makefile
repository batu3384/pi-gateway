.PHONY: setup validate render deploy install discover mac-dns harden status dns-test test-remote backup-pull backup-cron verify-data pi-access telegram-menu firewall

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

verify-data:
	@chmod +x scripts/mac/pre-deploy-check.sh scripts/lib/ensure-data-symlink.sh scripts/pi/ensure-data-symlink.sh 2>/dev/null || true
	@./scripts/mac/pre-deploy-check.sh

install:
	@./scripts/mac/install.sh

mac-dns:
	@./scripts/mac/setup-local-dns.sh

syncthing:
	@./scripts/mac/setup-syncthing.sh

harden:
	@ssh "$${PI_USER:-batu}@$${PI_STATIC_IP:-192.168.1.112}" "REMOTE_DIR=/home/$${PI_USER:-batu}/pi-gateway bash -s" < ./scripts/pi/harden-host.sh

status:
	@chmod +x scripts/mac/status.sh 2>/dev/null || true
	@./scripts/mac/status.sh

dns-test:
	@chmod +x scripts/mac/dns-test.sh 2>/dev/null || true
	@./scripts/mac/dns-test.sh

test-remote:
	@ssh "$${PI_USER:-batu}@$${PI_STATIC_IP:-192.168.1.112}" 'R=/home/$${USER:-batu}/pi-gateway; REMOTE_DIR="$$R" bash "$$R/scripts/pi/health-check.sh" && REMOTE_DIR="$$R" bash "$$R/scripts/pi/smoke-test.sh"'

telegram-test:
	@ssh "$${PI_USER:-batu}@$${PI_STATIC_IP:-192.168.1.112}" 'R=/home/$${USER:-batu}/pi-gateway; REMOTE_DIR="$$R" bash "$$R/scripts/pi/test-telegram.sh"'

telegram-menu:
	@ssh "$${PI_USER:-batu}@$${PI_STATIC_IP:-192.168.1.112}" 'R=/home/$${USER:-batu}/pi-gateway; REMOTE_DIR="$$R" bash "$$R/scripts/pi/telegram-menu.sh"'

pi-access:
	@chmod +x scripts/mac/setup-pi-access.sh 2>/dev/null || true
	@./scripts/mac/setup-pi-access.sh

pi-open:
	@open "http://gateway.$${LAN_DOMAIN:-home}"

backup-pull:
	@chmod +x scripts/mac/backup-pull.sh 2>/dev/null || true
	@./scripts/mac/backup-pull.sh

backup-cron:
	@chmod +x scripts/mac/install-backup-cron.sh 2>/dev/null || true
	@./scripts/mac/install-backup-cron.sh

firewall:
	@ssh "$${PI_USER:-batu}@$${PI_STATIC_IP:-192.168.1.112}" 'R=/home/$${USER:-batu}/pi-gateway; REMOTE_DIR="$$R" bash "$$R/scripts/pi/setup-firewall.sh"'
