# AdGuard DHCP Mode

With `NETWORK_MODE=adguard-dhcp`, the Pi serves both DNS and DHCP. All devices automatically use Pi DNS.

## Prerequisites

1. **Disable DHCP on the router** (only Pi distributes leases)
2. Pi static IP reserved on router or fixed via dhcpcd
3. `render-config.sh` writes the DHCP block into `AdGuardHome.yaml`

## .env

```env
NETWORK_MODE=adguard-dhcp
DHCP_RANGE_START=192.168.1.100
DHCP_RANGE_END=192.168.1.200
LAN_SUBNET_MASK=255.255.255.0
```

## Setup

```bash
make render && make deploy
```

## Router settings

1. Router admin → DHCP Server → **Disabled**
2. Keep Pi connected via ethernet
3. Only active DHCP: AdGuard

## Rollback

1. `NETWORK_MODE=router-dns`
2. `make render && make deploy`
3. Re-enable router DHCP
4. Router DNS = Pi static IP

## Risk

Wrong DHCP range or Pi down while router DHCP is off → new devices cannot get an IP. Prefer router DNS mode for initial setup; switch to DHCP mode in a planned maintenance window.
