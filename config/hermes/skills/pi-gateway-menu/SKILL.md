---
name: pi-gateway-menu
description: Pi Gateway Telegram panel menusu (/menu, /paneller, /start).
version: 1.0.0
author: Pi Gateway
license: MIT
platforms: [linux]
metadata:
  hermes:
    tags: [Pi-Gateway, Telegram, Menu, Panels]
---
# Pi Gateway Panel Menu

## When to Use

Kullanici **tam olarak** su mesajlardan birini gonderdiginde — baska hicbir sey yapma:

- `/menu`, `/paneller`, `/start`, `/linkler`
- `menu`, `paneller`, `Paneller` (tek kelime)

Genel sohbet, soru veya baska komutlar icin bu skill'i **kullanma**.

## Action

Hemen terminal calistir (web arama yok, uzun aciklama yok):

```bash
REMOTE_DIR=__REMOTE_DIR__ bash __REMOTE_DIR__/scripts/pi/hermes-menu.sh
```

Basarili olunca kullaniciya kisa Turkce yanit:

`Panel menusu gonderildi. Butonlardan panellere gidebilirsin.`

Hata olursa: `Panel menusu gonderilemedi — Pi loglarina bak.`
