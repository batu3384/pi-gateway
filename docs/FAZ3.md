# Faz 3 — Otomasyon, cache, guvenlik, tunel

## Servisler

| # | Servis | URL | Not |
|---|--------|-----|-----|
| 5 | CrowdSec | `127.0.0.1:8082` | SSH saldiri tespiti (fail2ban ile birlikte) |
| 9 | Redis | `127.0.0.1:6379` | Sadece Pi uzerinden (SSH tunnel) |
| 10 | n8n | http://n8n.home | Otomasyon / webhook |
| 2 | Cloudflare Tunnel | — | `CLOUDFLARE_TUNNEL_TOKEN` doluysa aktif |

## n8n ilk kurulum

1. http://n8n.home veya http://192.168.1.112:5678
2. Ilk acilista owner hesabi olustur
3. `N8N_ENCRYPTION_KEY` `.env` icinde sabit kalmali — degistirme

## Redis (Mac'ten test)

```bash
ssh -L 6379:127.0.0.1:6379 batu@192.168.1.112
redis-cli -h 127.0.0.1 ping
```

## CrowdSec

```bash
ssh batu@192.168.1.112 'docker exec crowdsec cscli metrics'
ssh batu@192.168.1.112 'docker exec crowdsec cscli decisions list'
```

## Cloudflare Tunnel

1. [Cloudflare Zero Trust](https://one.dash.cloudflare.com/) → Networks → Tunnels
2. Token olustur → `.env` icine `CLOUDFLARE_TUNNEL_TOKEN=...`
3. `make deploy` (profil otomatik eklenir)

Public hostname ornegi: `demo.seninadi.com` → `http://localhost:80`

## Kapatma

`.env` icinde `ENABLE_N8N=false` vb. sonra `make deploy`.
