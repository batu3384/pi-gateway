# Pi Gateway

Home server (Raspberry Pi 4B): AdGuard Home, Unbound (DoT `:853`), Caddy, Glance, Gatus, VictoriaMetrics + Grafana, NetAlertX, CrowdSec, Restic, OpenBot Jarvis fleet (`n8n` disabled by default).

## Health Stack

- validate / test: `./scripts/mac/validate.sh` or `make test`
- smoke: `ssh $PI_USER@${PI_DEPLOY_HOST:-$PI_STATIC_IP} 'REMOTE_DIR=~/pi-gateway bash ~/pi-gateway/scripts/pi/smoke-test.sh'`
- runtime: `ssh $PI_USER@${PI_DEPLOY_HOST:-$PI_STATIC_IP} 'REMOTE_DIR=~/pi-gateway bash ~/pi-gateway/scripts/pi/health-check.sh'`
- deploy code (daily): `make deploy-code` — full stack: `make deploy`
- DNS coverage: `make audit-dns` / `make remediate-dns`
- shell: `shellcheck -S warning scripts/pi/*.sh scripts/mac/*.sh scripts/lib/*.sh`

## Skill routing

When the user's request matches an available skill, invoke it via the Skill tool.

Key routing rules:
- Bugs/errors → invoke /investigate
- QA/testing → invoke /qa
- Code review → invoke /review or /adversarial-review
- Health check → invoke /health
- Ship/deploy → invoke /ship
