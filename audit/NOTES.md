# Denetim notları — 2026-10-28

Salt okunur geçiş. Kaynak ağaca yazılmadı. Üretim Pi’ye bu geçişte bağlanılmadı.

## Geçiş 1 — Bağlam

- Tür: tek düğümlü ev ağ geçidi (Raspberry Pi 4B). DNS filtresi, panel, yedek, Telegram ops.
- Kod: bash + python3. Uygulama dili/framework yok. Compose imajları digest pinli.
- Kullanıcı: ev sahibi. LAN kısmen güvenilir (`docs/SECURITY.md`).
- Kritik varlıklar: DNS doğruluğu (`:53`), AdGuard/Caddy parolaları, `.env`, restic repo, modem oturumu.
- En kötü senaryo: `:53` boş veya filtresiz; yedek geri açılamaz; LAN’daki bir konteyner yönetim portuna gider.
- Bilinçli tavan: Pi L2 gateway değil. ZTE DNS2=`.1` ve IPv6 RA `fe80::1` yazılımla kapanmaz (`docs/ARCHITECTURE.md`).

## Geçiş 2 — Kanıt

- `gitleaks detect` (196 commit): 0 leak. Çıktı `/tmp/gitleaks-pi-gateway.json`.
- `shellcheck -S warning` tüm `scripts/{pi,mac,lib}/*.sh`: tek uyarı `dns-host-fallback.sh:68` SC2034.
- `bandit -ll`: High yok. Medium B108 `/tmp` çoğunlukla test. B608 `hermes-session-hygiene.py:56` SQL parçası sabit string; kullanıcı girdisi değil. Bulgu sayılmadı.
- `git log` `.env` ve `BEGIN OPENSSH PRIVATE` / `AKIA`: eşleşme yok.
- Satır: `adguard-filters.py` 1193, `ssd-alive.sh` 1084, `notify.sh` 881, `health-check.sh` 785, `zte-h3600p.py` 669.
- CI: `.github/workflows/validate.yml` shellcheck + gitleaks + `validate.sh`. Action ref’leri tag (`@v4`, `@v2`), SHA değil. Dependabot yalnız `docker`.
- Kısmi `:53` bind bu ağaçta kapatılmış (`bind_ready`). Açık bulgu değil.
- `prune -a` kaldırılmış. Açık bulgu değil.
- `devices.home` şablonunda `__CADDY_BASIC_AUTH__` var. Açık bulgu değil.
- Restic: `restic-repair.sh` check fail olursa reinit ister. Drill herhangi bir restic nonzero’da `die` + failure marker. 2026-10-21 operasyonunda son snapshot 52 blob hatasıyla açılmadı; bu geçişte restore tekrar koşulmadı.

## Geçiş 3 — Kaynaklar

- Martin Hicks, AdGuard+Unbound, güncelleme May 2026: https://martinhicks.dev/articles/adguard-unbound-dns-home
- selfhosting.sh AdGuard Home: https://selfhosting.sh/apps/adguard-home-dns/
- MakeUseOf, Unbound DoT Quad9: https://www.makeuseof.com/last-piece-added-home-dns-stack-most-important/
- OpenWrt DNS intercept: https://openwrt.org/docs/guide-user/firewall/fw3_configurations/intercept_dns
- OpenWrt forum 2026-01-06, hijack DoH/DoT’u kesmez: https://forum.openwrt.org/t/vlans-security-and-dns/244981/12
- RFC 8305: https://www.rfc-editor.org/info/rfc8305/
