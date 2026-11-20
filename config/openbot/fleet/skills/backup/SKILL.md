---
name: backup
description: "Pi Gateway yedek durumu. /backup veya yedek sorulunca telegram-ops.sh --stdout backup çalıştır; çıktıyı aynen yaz."
version: 1.1.0
author: Pi Gateway
license: MIT
platforms: [linux]
metadata:
  hermes:
    tags: [Pi-Gateway, Telegram, Backup]
---
# Yedek durumu

Run the command below and reply with its exact stdout text only (no extra intro, explanation, or HTML tags):

```bash
REMOTE_DIR=__REMOTE_DIR__ bash __REMOTE_DIR__/scripts/pi/telegram-ops.sh --stdout backup
```
