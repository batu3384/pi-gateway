# Troubleshooting

## SSD dropped / degraded

**Symptoms:** Forgejo/n8n down, Telegram “SSD Degraded”, `storage_degraded: 1`.

```bash
# On Pi
cat /var/lib/pi-gateway/state.json
cat /run/pi-gateway/storage-degraded 2>/dev/null && echo DEGRADED
mountpoint /mnt/ssd && df -h /mnt/ssd
lsusb | grep 152d
journalctl -u pi-ssd-health -n 30 --no-pager
```

| Log | Meaning |
|-----|---------|
| `Cannot enable. Maybe the USB cable is bad?` | USB PHY — enclosure/port/power |
| `port disable rate-limit` | Software still trying; wait or check undervolt |
| `xhci rebind` | Host controller reset (automatic on bus dropout) |

**Do:** let `pi-ssd-health.timer` run; avoid full `docker compose up` while degraded (SD clobber risk).

**Manual recover:**

```bash
REMOTE_DIR=~/pi-gateway bash ~/pi-gateway/scripts/pi/recover-readonly-root.sh
```

JMicron (`152d:0583`) known flaky on Pi 4 USB3 — repo `docs/SSD-JMICRON-FIX.md`. Long-term: ASMedia enclosure.

## Wrong Telegram: “SD kart”

Fixed Aug 2026 — SSD I/O must use **SSD Degraded**, not SD card. Update Pi: `make deploy` + `install-privileged-scripts.sh`.

## DNS not resolving

```bash
make dns-test                    # from Mac
ssh pi 'dig @127.0.0.1 cloudflare.com +short'
docker ps | grep -E 'unbound|adguard'
```

Check router DHCP DNS → `PI_STATIC_IP`. AdGuard rewrites: `scripts/pi/apply-adguard-rewrites.sh`.

## Health check failing

```bash
ssh pi 'journalctl -t pi-gateway-health -n 30 --no-pager'
ssh pi 'REMOTE_DIR=~/pi-gateway bash ~/pi-gateway/scripts/pi/health-check.sh; echo exit=$?'
make test-remote
```

Backup SLA failures (`offsite-*`) are **soft** — they must not fail DNS systemd unit.

## TLS / browser warnings

```bash
make tls-certs    # regenerate mkcert
make trust-ca     # Mac keychain
```

## Stack recover

```bash
make recover-stack
# or on Pi:
REMOTE_DIR=~/pi-gateway bash ~/pi-gateway/scripts/pi/recover-stack.sh
```

## Remote access (Tailscale / SSH)

```bash
make diagnose-remote
```

## CI / validate failing locally

```bash
make validate
shellcheck -S warning scripts/pi/*.sh scripts/mac/*.sh scripts/lib/*.sh
```

## More

| Topic | Repo doc |
|-------|----------|
| SSD FSM runbook | `docs/runbooks/SSD-FSM.md` |
| Operations | `docs/OPERATIONS.md` |
| Restore / Restic | `docs/RESTORE.md` |
| Codebase audits | `docs/codebase-audit/` |

Open a [GitHub Issue](https://github.com/batu3384/pi-gateway/issues) with `journalctl` snippets and `state.json`.
