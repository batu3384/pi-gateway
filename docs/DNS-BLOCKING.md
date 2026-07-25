# DNS ad blocking — limits and stack

## Why does phone AdGuard block more?

| Layer | Phone AdGuard | Pi AdGuard Home |
|-------|---------------|-----------------|
| DNS host blocking | Yes | Yes (this project) |
| HTTPS content (path/query) | Yes (local VPN/proxy) | **No** |
| CSS element hiding | Yes | **No** |
| Scriptlet / JS injection | Yes | **No** |

Result: Ads served from the same domain (YouTube `googlevideo.com`, some in-app ads, in-page iframe paths) cannot be blocked by DNS alone. This is normal; it is a DNS-only architecture limit.

## Current DNS stack

1. **HaGeZi Pro++** — primary ad/tracker list (OISD and others already included)
2. **HaGeZi TIF Medium** — malware/phishing (medium for Pi 4GB; full TIF strains RAM)
3. **AdGuard DNS Popup Hosts** — popup hosts
4. **Apple / Windows / Samsung tracker** — device telemetry
5. **User rules** — Google Ads, DoubleClick, Criteo, Taboola, Gemius, etc. with `$important`

OISD Big is intentionally omitted: duplicates Pro++; wastes Pi RAM.

## Browser / YouTube

If DNS is not enough, add on the device:

- Safari: AdGuard for Safari / uBlock Origin Lite
- Chrome/Firefox: uBlock Origin
- YouTube: browser extension or SponsorBlock (DNS cannot fix this)

## Update

```bash
ssh "$PI_USER@$PI_STATIC_IP" 'REMOTE_DIR=~/pi-gateway bash ~/pi-gateway/scripts/pi/apply-adguard-dns.sh'
ssh "$PI_USER@$PI_STATIC_IP" 'REMOTE_DIR=~/pi-gateway bash ~/pi-gateway/scripts/pi/apply-adguard-filters.sh'
```

After deploy, `post-deploy` runs automatically: `wait-adguard-dns` → `apply-adguard-dns` → `apply-adguard-filters`.

## Boot note

After a Pi reboot, DNS port 53 may take ~30–90 seconds to open (filter loading). If the Mac uses the Pi as its only DNS server, wait for the Pi to be ready first.
