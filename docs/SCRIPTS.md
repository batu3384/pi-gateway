# Script tiers

Do not treat every `scripts/**/*.sh` as equal. Prefer `make` targets.

## core (day-to-day / deploy)

| Area | Scripts |
|------|---------|
| Mac pipeline | `install.sh`, `doctor.sh`, `discover-remote.sh`, `render-config.sh`, `validate.sh`, `deploy.sh`, `deploy-fast.sh`, `pre-deploy-check.sh`, `restore-check.sh`, `backup-restore-drill.sh`, `config-drift-check.sh`, `test-smoke-contract.sh` |
| Pi lifecycle | `bootstrap.sh`, `post-deploy.sh`, `smoke-test.sh`, `health-check.sh` → `recover-stack.sh`, `export-gateway-state.sh`, `export-adguard-metrics.sh`, `ssd-health.sh`, `ssd-hotplug-handler.sh`, `check-ssd-smart.sh` |
| Lib | `common.sh`, `stack-health.sh`, `ssd-alive.sh`, `notify.sh`, `adguard-api.sh`, `password-policy.sh`, `compose-profiles.sh`, `telegram-panels.py` + diğer `scripts/lib/*.py` (bash CLI; py relative import yok) |
| Security | `setup-firewall.sh`, `harden-host.sh` |
| Backup | `restic-backup.sh`, `backup-pull.sh`, `restore-check.sh`, `install-backup-cron.sh` |

Recover path: callers → `recover-stack.sh` → `stack-health.trigger_stack_recover` → `recover-readonly-root.sh`.

SSD path: udev `SYSTEMD_WANTS` + `pi-ssd-watch.path` (`PathChanged`) / `ssd-health.sh` → soft-reset (`ssd-alive.sh`) → remount or degraded core-dns.

## ops (enabled features)

Setup helpers: `setup-*.sh` (n8n, netalertx, crowdsec, dozzle, uptime-kuma, tailscale-*, telegram-menu, caddy-lan-ip, hermes-*).

DNS: `apply-adguard-*.sh`, `configure-adguard.sh`, `wait-adguard-dns.sh`, `diagnose-dns-bypass.sh`, `diagnose-remote-access.sh`, `adguard-tune.sh`, `lib/unbound-dnssec.sh`.

Make: `diagnose-remote`, `diagnose-dns`, `recover-stack`, `restore-check`.

## experimental (SSD-root / cutover — footguns)

Prefer hybrid (ADR-001). Touch only with `docs/SSD-ROOT.md`:

- Mac: `migrate-sd-boot-ssd-root.sh`, `flash-ssd.sh`, `harden-ssd-boot.sh`, `repair-cutover-bootfs.sh`, `rollback-to-sd-root.sh`, `verify-ssd-root.sh`, `restore-hybrid-boot.sh`, `setup-hybrid.sh`, `fix-ssd-pi-boot.sh`
- Pi: `setup-docker-ssd.sh`, `ssd-root-harden.sh`, `neutralize-legacy-sd-root.sh`, `fix-eeprom-usb-ssd.sh`

## CI

`scripts/mac/ci-compose-config.sh` + `.github/ci.env.fixture`

SSD recovery regression (Mac): `scripts/mac/test-ssd-alive.sh` (via `validate-recovery-contract.sh`).  
Smoke contract (Mac/CI): `scripts/mac/test-smoke-contract.sh`.
