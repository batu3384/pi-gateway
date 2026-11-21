---
name: recover
description: "Pi Gateway SSD kurtarma (/recover veya /recover onay). Run telegram-ops.sh --stdout recover [onay] and output ONLY its exact stdout text."
version: 1.3.0
author: Pi Gateway
license: MIT
platforms: [linux]
metadata:
  openbot:
    tags: [Pi-Gateway, OpenBot, Recovery]
---
# SSD kurtarma (`/recover` ve `/recover onay`)

Run the matching command below and reply with its exact stdout text only (no extra intro, explanation, or HTML tags):

- Kullanıcı mesajı yalnızca `/recover` ise onayı başlat:
```bash
REMOTE_DIR=__REMOTE_DIR__ bash __REMOTE_DIR__/scripts/pi/telegram-ops.sh --stdout recover
```

- Kullanıcı mesajı `/recover onay` ise (60 sn içinde) kurtarmayı çalıştır:
```bash
REMOTE_DIR=__REMOTE_DIR__ bash __REMOTE_DIR__/scripts/pi/telegram-ops.sh --stdout recover onay
```
