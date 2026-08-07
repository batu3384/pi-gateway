# Script tiers

Do not treat every `scripts/**/*.sh` as equal. Prefer `make` targets.

## core (day-to-day / deploy)

| Area | Scripts |
|------|---------|
| Mac pipeline | `install.sh`, `doctor.sh`, `discover-remote.sh`, `render-config.sh`, `validate.sh`, `deploy.sh`, `deploy-fast.sh`, `pre-deploy-check.sh` |
| Pi lifecycle | `bootstrap.sh`, `post-deploy.sh`, `smoke-test.sh`, `health-check.sh`, `stack-watchdog.sh`, `recover-stack.sh` |
| Lib | `common.sh`, `stack-health.sh`, `notify.sh`, `adguard-api.sh`, `password-policy.sh`, `compose-profiles.sh` |
| Security | `setup-firewall.sh`, `harden-host.sh` |
| Backup | `restic-backup.sh`, `backup-pull.sh`, `install-backup-cron.sh` |

Recover path: callers → `recover-stack.sh` → `stack-health.trigger_stack_recover` → `recover-readonly-root.sh`.

## ops (enabled features)

Setup helpers: `setup-*.sh` (forgejo, syncthing, n8n, netalertx, crowdsec, dozzle, uptime-kuma, tailscale-*, telegram-*, caddy-lan-ip, morning-*).

DNS: `apply-adguard-*.sh`, `configure-adguard.sh`, `wait-adguard-dns.sh`, `diagnose-dns-bypass.sh`.

## experimental (SSD-root / cutover — footguns)

Prefer hybrid (ADR-001). Touch only with `docs/SSD-ROOT.md`:

- Mac: `migrate-sd-boot-ssd-root.sh`, `flash-ssd.sh`, `harden-ssd-boot.sh`, `repair-cutover-bootfs.sh`, `rollback-to-sd-root.sh`, `verify-ssd-root.sh`, `restore-hybrid-boot.sh`, `setup-hybrid.sh`, `fix-ssd-pi-boot.sh`
- Pi: `setup-docker-ssd.sh`, `ssd-root-harden.sh`, `neutralize-legacy-sd-root.sh`, `fix-eeprom-usb-ssd.sh`

## CI

`scripts/mac/ci-compose-config.sh` + `.github/ci.env.fixture`
