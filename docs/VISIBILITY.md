# Path B — Görünürlük (Visibility)

Tek bakışta durum + geçmiş grafikleri.

## Katmanlar

| Katman | URL / yol | Ne gösterir |
|--------|-----------|-------------|
| Homepage widget | https://gateway.home | `state.json`: SSD, yedek, drill |
| Prometheus | `127.0.0.1:9090` (LAN içi) | Metrik deposu |
| Grafana | https://grafana.home | CPU, disk, gateway SLO grafikleri |
| Dozzle | https://logs.home | Canlı container logları (Loki yerine) |

## Açma / kapatma

```bash
# .env
ENABLE_MONITORING=true   # varsayılan: prometheus + grafana + node-exporter
GRAFANA_ADMIN_PASSWORD=  # bos -> UNIFIED_LOGIN ile AGH_ADMIN_PASSWORD
make deploy-fast
```

`ENABLE_MONITORING=false` → monitoring profile kapalı (Pi RAM tasarrufu).

## Grafana

- Giriş: `GRAFANA_ADMIN_USER` / `GRAFANA_ADMIN_PASSWORD` (unified login = `AGH_ADMIN_*`)
- Caddy basic auth da geçerli (çift katman)
- Hazır dashboard: **Pi Gateway** (SSD, CPU, backup age, AdGuard blocked ratio / per-list rules / last_updated age)

## Metrik kaynakları

| Kaynak | Job | Not |
|--------|-----|-----|
| `node-exporter` | `node` | CPU, disk, host |
| Textfile | `/var/lib/pi-gateway/metrics/*.prom` | `export-gateway-state.sh` + `export-adguard-metrics.sh` |
| `prometheus` | `prometheus` | Self |

## Canary güncelleme

Deploy varsayılan: DNS önce → bekle → edge → kalan servisler.

```bash
ENABLE_CANARY_COMPOSE_UPDATE=true   # varsayılan — bu evde kapatma
CANARY_DNS_WAIT_SEC=10
```

`make deploy-fast` bunu kullanır. Kapatmak için `ENABLE_CANARY_COMPOSE_UPDATE=false`.

## Chaos / FSM

Bakım tatbikatı: `docs/runbooks/SSD-FSM.md` ve `make chaos-drill`.
