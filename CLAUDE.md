# Pi Gateway

Ev sunucusu (Raspberry Pi 4B): AdGuard DNS, Unbound, Caddy, Forgejo, Syncthing, n8n.

## Health Stack

- validate: `./scripts/mac/validate.sh`
- test: `ssh $PI_USER@$PI_STATIC_IP 'REMOTE_DIR=~/pi-gateway bash ~/pi-gateway/scripts/pi/smoke-test.sh'`
- runtime: `ssh $PI_USER@$PI_STATIC_IP 'REMOTE_DIR=~/pi-gateway bash ~/pi-gateway/scripts/pi/health-check.sh'`
- shell: `shellcheck -S warning scripts/pi/*.sh scripts/mac/*.sh scripts/lib/*.sh`

## Skill routing

When the user's request matches an available skill, invoke it via the Skill tool.

Key routing rules:
- Bugs/errors → invoke /investigate
- QA/testing → invoke /qa
- Code review → invoke /review or /adversarial-review
- Health check → invoke /health
- Ship/deploy → invoke /ship
