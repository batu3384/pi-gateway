---
name: menu
description: "Pi Gateway panel menusu. ONLY when user message is exactly one of: /menu /paneller /start /linkler menu paneller Paneller. Run hermes-menu.sh; do not chat."
version: 1.1.0
author: Pi Gateway
license: MIT
platforms: [linux]
metadata:
  hermes:
    tags: [Pi-Gateway, Telegram, Menu, Panels]
---
# Pi Gateway Panel Menu

## When to Use

Kullanici mesaji **tam olarak** suysa — baska hicbir sey yapma:

- `/menu`, `/paneller`, `/start`, `/linkler`
- `menu`, `paneller`, `Paneller`

Genel sohbet / soru icin bu skill'i **kullanma**.

## Action

Hemen terminal (web arama yok, uzun aciklama yok):

```bash
REMOTE_DIR=__REMOTE_DIR__ bash __REMOTE_DIR__/scripts/pi/hermes-menu.sh
```

Basarili: `Panel menusu gonderildi. Buton → Safari’de Aç.`

Hata: `Panel menusu gonderilemedi — Pi log.`
