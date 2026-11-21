---
name: ssd
description: "Pi Gateway SSD/USB sağlık. /ssd veya disk sağlığı sorulunca telegram-ops.sh --stdout ssd çalıştır; çıktıyı aynen yaz."
version: 1.1.0
author: Pi Gateway
license: MIT
platforms: [linux]
metadata:
  openbot:
    tags: [Pi-Gateway, OpenBot, SSD]
---
# SSD saglik

Run the command below and reply with its exact stdout text only (no extra intro, explanation, or HTML tags):

```bash
REMOTE_DIR=__REMOTE_DIR__ bash __REMOTE_DIR__/scripts/pi/telegram-ops.sh --stdout ssd
```
