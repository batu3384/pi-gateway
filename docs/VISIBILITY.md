# Path B — Görünürlük (Visibility)

Tek bakışta durum + geçmiş grafikleri.

## Katmanlar

| Katman | URL / yol | Ne gösterir |
|--------|-----------|-------------|
| Glance widget | https://gateway.home | `state.json`: SSD, DNS gecikmesi, yedek, drill |
| Gatus | https://status.home | Servis sağlığı ve SLO push kalp atışları |
| VictoriaMetrics | `127.0.0.1:9090` (loopback) | Hafif PromQL metrik deposu (`128MB` bellek sınırı) |
| Grafana | https://grafana.home | CPU, disk, DNS gecikmesi, AdGuard ve SLO grafikleri |
| Dozzle | https://logs.home | Canlı container logları (`docker-socket-proxy` üzerinden) |

## Açma / kapatma

```bash
# .env
ENABLE_MONITORING=true   # varsayılan: victoriametrics + grafana + node-exporter
GRAFANA_ADMIN_PASSWORD=  # bos -> UNIFIED_LOGIN ile AGH_ADMIN_PASSWORD
make deploy-code   # monitoring ilk kurulum / compose için: make deploy
```

`ENABLE_MONITORING=false` → monitoring profile kapalı (Pi RAM tasarrufu).

## Grafana

- Giriş: `GRAFANA_ADMIN_USER` / `GRAFANA_ADMIN_PASSWORD` (unified login = `AGH_ADMIN_*`)
- Caddy basic auth da geçerli (çift katman)
- Hazır dashboard: **Pi Gateway** (SSD, CPU %, backup age, AdGuard blocked ratio / top clients / top blocked domains / per-list rules, İBB HKI)

## Metrik kaynakları

| Kaynak | Job | Not |
|--------|-----|-----|
| `node-exporter` | `node` | CPU, disk, host |
| Textfile | `/var/lib/pi-gateway/metrics/*.prom` | `export-gateway-state.sh` + `export-adguard-metrics.sh` + `ibb-air-quality.sh` |
| `victoriametrics` | `victoriametrics` | Self |

## Canary güncelleme

**Full deploy** varsayılan: DNS önce → bekle → edge → kalan servisler. `make deploy-code` canary atlar.

```bash
ENABLE_CANARY_COMPOSE_UPDATE=true   # varsayılan — bu evde kapatma
CANARY_DNS_WAIT_SEC=10
make deploy
```

Kapatmak için full’da `ENABLE_CANARY_COMPOSE_UPDATE=false`.

## Chaos / FSM

Bakım tatbikatı: `docs/runbooks/SSD-FSM.md` ve `make chaos-drill`.
