# Security Model

## Assumptions

- Home LAN (`192.168.1.0/24`) is partially trusted
- DNS and admin panels are centralized on the Pi
- Internet threats target SSH and service ports

## Layers

| Layer | Component |
|-------|-----------|
| Network | UFW (LAN-scoped) |
| Threat | CrowdSec + UFW sync / bouncer (sole SSH ban — fail2ban yok; CrowdSec/timer down ise UFW yine LAN kısıtlar ama auto-ban yok) |
| Application | Per-service passwords (Dozzle, Kuma GUI) |
| DNS | AdGuard filters + Unbound |
| Remote | Tailscale (optional) |

## HTTP risk

`*.home` defaults to **HTTPS** (`ENABLE_TLS=true`). Certs: `make tls-certs`.

HTTP-only LAN requires explicit risk acceptance:

```bash
ENABLE_TLS=false
WEAK_TLS_OK=yes
```

**Recommendations (priority order):**

1. Keep TLS on; `UFW_ADMIN_EXPOSURE=caddy-only`
2. Admin over Tailscale; close sensitive ports in UFW
3. Cloudflare Tunnel only with hostname allowlist — `docs/CLOUDFLARE-TUNNEL.md`

## Secrets

- `.env` never goes into git (Pi: mode 600 via `fix-config-perms.sh`)
- `backup.sh` / `backup-pull` skip `.env` and `caddy/certs` (mkcert private key). AGH runtime yaml skipped on Mac pull (mode 640). Encrypted restic still has data + certs.
- Restic is encrypted; password lives in `.env` on the same Pi (co-location accepted). Use `make backup-pull` for offsite
- SSH: password auth off after key install (`harden-host.sh`). Rollback: HDMI/SD userconf + remove `00-pi-gateway-ssh.conf`

## CrowdSec bouncer

`setup-crowdsec-bouncer.sh` tries a host bouncer; if that fails, `sync-crowdsec-ufw.sh` + timer applies CrowdSec decisions to UFW.

```bash
sudo systemctl status crowdsec-firewall-bouncer  # if host install exists
sudo systemctl status pi-gateway-crowdsec-ufw.timer
docker exec crowdsec cscli decisions list
```

## Cloudflare Tunnel

If a token is set, external access is enabled. Expose only required hostnames; HTTPS termination should be on Cloudflare.

## Checklist

- [ ] All default passwords changed
- [ ] Telegram notifications tested
- [ ] `make backup-pull` weekly cron (Mac)
- [ ] Tailscale 2FA (account side)

## Public GitHub preparation

Before making the repo public:

1. `make validate` — `validate-public-repo.sh` secret/PII scan
2. `.env` never committed — `git log -- .env` should be empty
3. **Rotate** any real tokens/passwords seen in chat or logs (Telegram, Tailscale, service passwords)
4. `config/tailscale/acl.hujson` and `host/dhcpcd/pi-gateway.conf` render only on the Pi — not in git
5. `TAILSCALE_ACL_OWNER` in `.env` is your real Tailscale email (not tracked)

After going public: follow [.github/SECURITY.md](../.github/SECURITY.md) for security issues; in an emergency, make the repo private and rotate secrets.
