# Security

Summary of repo [`docs/SECURITY.md`](https://github.com/batu3384/pi-gateway/blob/master/docs/SECURITY.md) and [`.github/SECURITY.md`](https://github.com/batu3384/pi-gateway/blob/master/.github/SECURITY.md).

## Threat model (assumptions)

- Home LAN (`192.168.1.0/24`) partially trusted
- Pi centralizes DNS and admin panels
- Internet threats: SSH brute force, exposed services

## Layers

| Layer | Control |
|-------|---------|
| Network | UFW (LAN-scoped admin), CrowdSec (SSH) |
| Threat intel | CrowdSec + UFW bouncer (optional) |
| Application | Per-service passwords; unified login option |
| DNS | AdGuard filters + Unbound DoT forward (`:853`) |
| Remote | Tailscale (optional), no public SSH by default |
| TLS | mkcert `*.home` default; HTTP requires `WEAK_TLS_OK=yes` |

## Secrets

| Item | Rule |
|------|------|
| `.env` | Gitignored — never commit |
| TLS keys | Gitignored |
| Rendered AdGuard/Caddy | Gitignored on Pi |

`make validate` fails on `CHANGE_ME*` placeholders in public-repo checks.

## Reporting vulnerabilities

**Do not** open public issues for auth bypass, RCE, or leaked credentials.

1. [GitHub Security Advisories](https://github.com/batu3384/pi-gateway/security/advisories) (private), or  
2. Maintainer contact via GitHub profile

Include: affected path, reproduction, impact.

## Hardening defaults

- `UFW_ADMIN_EXPOSURE=caddy-only`
- Admin ports bound to localhost where possible
- n8n `executeCommand` disabled in workflow set
- Gitleaks in CI (`validate` workflow)

## Public repo checklist

Before publishing: rotate any credential ever in logs/chat; run `make validate`.

## Related wiki

- [Getting Started](Getting-Started.md) — TLS & trust-ca
- [Architecture](Architecture.md) — compose tiers & exposure
- [Troubleshooting](Troubleshooting.md) — access diagnostics
