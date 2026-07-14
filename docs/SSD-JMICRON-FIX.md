# SSD Boot — Profesyonel Teşhis ve Düzeltme

Güncelleme: 2026-07-11

## Gerçekler (forum + resmi doküman)

1. **SSD / imaj Mac'te sağlam** olabilir; Pi USB **bootloader** aşaması ayrıdır.
2. `usb-storage.quirks` = **Linux kernel** ayarı. Renkli ekranda (kernel yok) **işe yaramaz**.
3. YongzhenWeiye = JMicron **JMS583** (`152d:0583`) — Pi 4'te bilinen uyumsuzluk ([rpi-eeprom#266](https://github.com/raspberrypi/rpi-eeprom/issues/266)).
4. Bootloader düzeltmeleri **EEPROM**'da: `USB_MSD_PWR_OFF_TIME=0`, `USB_MSD_DISCOVER_TIMEOUT`, `USB_MSD_STARTUP_DELAY`.

## Mac'te yapılanlar (`harden-ssd-boot.sh`)

- quirks + rootdelay=15
- quiet/splash kaldırıldı (boot log görünsün)
- boot_delay=5, hdmi_force_hotplug, usb_max_current
- ssh + cloud-init kontrolü

## Pi'de zorunlu — SD ile (elle)

```bash
sudo -E rpi-eeprom-config --edit
```

Ekle / guncelle:

```
BOOT_ORDER=0xf14
USB_MSD_PWR_OFF_TIME=0
USB_MSD_DISCOVER_TIMEOUT=25000
USB_MSD_STARTUP_DELAY=5000
```

Kaydet, `sudo reboot`. Sonra dogrula:

```bash
sudo rpi-eeprom-config | grep -E 'BOOT_ORDER|USB_MSD'
```

## Test sırası

1. SD açık → SSD tak → `lsusb` / `lsblk` (disk Linux'ta görünmeli)
2. EEPROM script → reboot → doğrula
3. SD çıkar → SSD USB **2.0** → aç
4. Olmazsa: ASMedia kutu veya SD'den `make install`

## Kalıcı çözüm

ASMedia chipsetli USB-SATA adaptör. JMicron ile 24/7 USB boot önerilmez.
