# SSD DNS-degraded aftercare Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use `superpowers:subagent-driven-development` (recommended) or `superpowers:executing-plans` to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** SSD USB kaybolunca paneller/forgejo ölür ama DNS (Unbound+AdGuard) SD üzerinde ayakta kalsın; recover compose recreate fırtınası dursun; disconnect log/Telegram net olsun.

**Architecture:** Hybrid fail-closed (`STORAGE_FALLBACK_SD=false`) korunur (tam app stack SD'ye taşınmaz). Yeni varsayılan `DNS_DEGRADED_ON_SSD_LOSS=true`: SSD yokken `enter_degraded_mode` + `COMPOSE_RECOVER_MODE=core-dns` (unbound/adguard/homepage/caddy). Hotplug aynı yolu izler. Journald persistent drop-in.

**Tech Stack:** bash, systemd, docker compose, journald

## File map

| File | Responsibility |
|------|----------------|
| `scripts/lib/stack-health.sh` | `dns_degraded_on_ssd_loss`, degraded cooldown |
| `scripts/pi/recover-readonly-root.sh` | SSD fail → DNS degraded (not exit 1) |
| `scripts/pi/ssd-hotplug-handler.sh` | Aynı; fail-closed sadece DNS flag kapalıysa |
| `scripts/pi/recover-compose-up.sh` | core-dns: force-recreate sadece core; SSD yokken full mode yok |
| `scripts/pi/health-check.sh` / `stack-watchdog.sh` | Degraded iken optional fail yok; storm azalt |
| `host/systemd/journald.conf.d/00-pi-gateway-persistent.conf` | Persistent journal |
| `scripts/pi/bootstrap.sh` | journald drop-in install |
| `.env.example`, `docs/ENV.md` | Yeni flag |
| `scripts/mac/validate-hybrid-contract.sh` | Kontrat güncelle |

## Task 1: stack-health helpers

- [ ] `dns_degraded_on_ssd_loss` ekle (default true veya STORAGE_FALLBACK_SD)
- [ ] `stack_recover_suppressed`: degraded iken uzun cooldown (900s)

## Task 2: recover + hotplug

- [ ] SSD mount fail → `dns_degraded_on_ssd_loss` ise `enter_degraded_mode` + core-dns
- [ ] Hotplug: aynı; false/false ise fail-closed + Telegram

## Task 3: compose storm

- [ ] core-dns mode'da asla full profile up
- [ ] SSD unmounted + not degraded + DNS flag: recover sadece degraded path

## Task 4: journal + docs + validate

- [ ] journald persistent conf + bootstrap
- [ ] ENV docs; hybrid contract; `./scripts/mac/validate-hybrid-contract.sh`
