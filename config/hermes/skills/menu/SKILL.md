---
name: menu
description: "Pi Gateway durum kartı. ONLY when user message is exactly one of: /menu /start /linkler menu. Run hermes-menu.sh; do not chat."
version: 1.2.0
author: Pi Gateway
license: MIT
platforms: [linux]
metadata:
  hermes:
    tags: [Pi-Gateway, Telegram, Menu]
---
# Pi Gateway Durum Kartı

## When to Use

Kullanici mesaji **tam olarak** suysa:

- `/menu`, `/start`, `/linkler`
- `menu`

`/dns` `/ssd` `/backup` `/recover` icin ayri skill'ler var.

## Action

```bash
REMOTE_DIR=__REMOTE_DIR__ bash __REMOTE_DIR__/scripts/pi/hermes-menu.sh
```

Basarili: `Durum kartı güncellendi.`
