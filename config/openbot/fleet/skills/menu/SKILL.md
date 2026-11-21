---
name: menu
description: "Pi Gateway durum kartı. Kullanıcı /menu, menü veya panel durumu isteyince gateway-status.sh çalıştır; çıktıyı aynen yaz."
version: 1.2.0
author: Pi Gateway
license: MIT
platforms: [linux]
metadata:
  openbot:
    tags: [Pi-Gateway, OpenBot, Menu]
---
# Pi Gateway Durum Kartı

## When to Use

Kullanıcı şunlardan birini isterse:

- `/menu`, `menü`, `panel`, `durum kartı`

`/dns` `/ssd` `/backup` `/recover` icin ayri skill'ler var.

## Action

```bash
REMOTE_DIR=__REMOTE_DIR__ bash __REMOTE_DIR__/scripts/pi/gateway-status.sh
```

Çıktıyı olduğu gibi sohbete yaz. Telegram’a gönderme.
