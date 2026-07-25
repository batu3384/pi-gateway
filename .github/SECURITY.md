# Security Policy

## Supported versions

Security fixes apply to the latest `master` / `main` branch of this repository.

## Reporting a vulnerability

Do **not** open a public issue for secrets, RCE, or auth bypass.

1. Email the maintainer via GitHub profile contact, **or**
2. Open a private GitHub Security Advisory on this repo (if enabled)

Include: affected script/path, reproduction steps, impact.

## Secrets in this project

| Item | Location | Rule |
|------|----------|------|
| Passwords, tokens, keys | `.env` (gitignored) | Never commit |
| Tailscale ACL | `config/tailscale/acl.hujson` (generated) | Never commit |
| TLS keys | `*.pem` / `*.key` | Never commit |
| Rendered AdGuard/Caddy | `config/adguard/AdGuardHome.yaml`, `config/caddy/Caddyfile` | Gitignored |

Before making the repo public: run `make validate` and rotate any credentials that ever appeared in chat, logs, or old private clones.

## Hardening defaults

- `UFW_ADMIN_EXPOSURE=caddy-only`
- Service passwords fail-closed on `CHANGE_ME*` placeholders
- Makefile does **not** export the whole `.env` into recipe environments
