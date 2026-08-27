# Tailscale Remote Access

## Two jobs (same app)

1. **Panels** — `http://100.x/p/…` (Telegram). MagicDNS not required.
2. **DNS filter away from home** — Tailscale tunnel to Pi AdGuard `:53`. Without this, cellular DNS is the ISP; ads return.

Pi itself: `--accept-dns=false` (MagicDNS would break Pi `resolv.conf`). Clients: Use Tailscale DNS **on**.

## Setup (Pi)

`setup-tailscale-remote.sh` runs during deploy. Manual:

```bash
ssh pi 'REMOTE_DIR=~/pi-gateway bash ~/pi-gateway/scripts/pi/setup-tailscale-remote.sh'
```

UFW `tailscale0` `:53` UDP+TCP comes from `setup-firewall.sh` (runs **after** remote.sh on deploy — do not put INPUT `:53` only in remote.sh).

## Mac / iPhone

1. Install the Tailscale app
2. Sign in to the same tailnet
3. Approve Pi: subnet route `192.168.1.0/24`
4. Tag Pi `tag:pi-gateway`. Phones/Mac: untagged (`group:owners`) **or** `tag:owner-device`
5. Connected + **Use Tailscale DNS**. Off: Android Private DNS, iCloud Private Relay, Chrome Secure DNS (they bypass Tailscale DNS)

## DNS (AdGuard as global nameserver)

Do **not** flip Override first. Same lesson as WAN `:53` drop: listen + ACL + proof, then cut.

1. UFW: `tailscale0` `:53/udp` + `:53/tcp` (`setup-firewall.sh`, Tailscale up)
2. ACL: `group:owners` + `tag:owner-device` → `tag:pi-gateway:53` (`make tailscale-acl`)
3. **Proof from Mac/phone** (not from Pi — `dig @100.x` on the Pi is local delivery, skips UFW):

   ```bash
   dig @"$(ssh pi 'tailscale ip -4 | head -1')" cloudflare.com +short
   dig @"$(ssh pi 'tailscale ip -4 | head -1')" doubleclick.net +short
   ```

   Expect block (`0.0.0.0` / NXDOMAIN) for `doubleclick.net`.

4. Admin → [DNS](https://login.tailscale.com/admin/dns):
   - **Global nameserver** = Pi Tailscale IPv4 (`100.x`). **Not** LAN `.112` (source is `100.x`; LAN UFW rule does not match; post-deploy also wipes `ts-subnet` FORWARD)
   - Keep split DNS `home` → same `100.x` (devices with Override off)
   - **No second global NS** (Tailscale queries in parallel; ads leak)
   - **Override DNS servers** — only after step 3 is green
5. Cellular: Wi-Fi off, `doubleclick.net` blocked; AdGuard query log shows client `100.x`
6. Pi `/etc/resolv.conf` stays `127.0.0.1`. Health-check does **not** fail the house if Tailscale is down.

Exit node later: enable **Use with exit node** on this nameserver or DNS bypasses AdGuard.

AGH `ratelimit: 20` — if apps flake after Override, check AdGuard logs before adding a public NS.

## Tailscale Serve (recommended — remote Telegram links)

On phone, `https://gateway.home` does not trust mkcert certs. Instead:

1. Enable Serve in Admin: `/f/serve` link from deploy or ACL
2. On Pi: `bash scripts/pi/setup-tailscale-serve.sh`
3. Telegram menu prefers **`http://100.x.x.x/p/...`** (works without MagicDNS). Serve HTTPS is optional backup when MagicDNS + Override DNS are on.

```bash
make telegram-menu   # or on Pi: scripts/pi/telegram-menu.sh
REMOTE_DIR=~/pi-gateway bash scripts/pi/diagnose-remote-access.sh
```

**Security:** admin panels via Caddy on Tailscale `80/443`. DNS `:53` on `tailscale0` is AdGuard (filter), not the admin UI. Do not open AdGuard `:8080` / NetAlertX `:20211` on `tailscale0`. ACL: `group:owners` / `tag:owner-device` only.

**Auth tradeoff:** `http://100.x.x.x` Caddy block has **no basic_auth** (Telegram in-app browser cannot do Basic Auth). LAN `192.x` keeps basic_auth. Anyone on your tailnet who can reach the Pi can open panels without a password — **ACL is the only gate**. Do not invite untrusted devices.

Phone tips: Tailscale **Connected**; open links in **Safari** (Telegram in-app browser often breaks).

Diagnostics: `bash scripts/pi/diagnose-remote-access.sh`

## ACL (recommended)

`make tailscale-acl` — requires `TAILSCALE_ACL_OWNER` in `.env` (Tailscale email).
Template: `config/tailscale/acl.hujson.example` → local `config/tailscale/acl.hujson` (gitignored, do not commit).

Manual: copy template to [Access Controls](https://login.tailscale.com/admin/acls).

- Tag Pi: `tag:pi-gateway` (dst `:53` / `:80` / `:443` will not match otherwise)
- Your login’s devices: `group:owners` (no tag required) or `tag:owner-device`
- Guest devices cannot reach Pi. Override + untagged non-owner device = no DNS while Tailscale is up.

## SSH

```bash
ssh pi-ts          # Tailscale IP
ssh "$PI_USER@100.x.x.x"
```

## Security note

UFW on `tailscale0`: `22/80/443` TCP (panels/SSH) and `:53` UDP+TCP (AdGuard). WAN `:53` stays closed.
