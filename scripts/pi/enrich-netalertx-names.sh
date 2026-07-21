#!/usr/bin/env bash
# NetAlertX: AdGuard'da isim yoksa vendor/tipe gore yedek isim (tahmin)
set -euo pipefail

REMOTE_DIR="${REMOTE_DIR:-/home/${USER}/pi-gateway}"
DB="${REMOTE_DIR}/data/netalertx/db/app.db"

log() { echo "[netalertx-names] $*"; }

[[ -f "$DB" ]] || { log "DB yok, atlandi"; exit 0; }

docker exec -i netalertx python3 <<'PY'
import sqlite3

DB = "/data/db/app.db"

def suggest(name, vendor, dtype, ip, mac):
    if ip == "192.168.1.1":
        return "Router (ZTE)"
    bad = {"", "(name not found)", ip}
    if name and name not in bad and not name.startswith("192.168."):
        return None
    if mac == "internet":
        return None
    v = (vendor or "").strip()
    vl = v.lower()
    t = (dtype or "").strip()
    if "raspberry" in vl:
        return "Pi Gateway"
    if t == "Gateway" and "zte" in vl:
        return "Router (ZTE)"
    if "apple" in vl:
        return "Apple iPhone/iPad" if t == "Phone" else "Apple cihaz"
    if "samjin" in vl or "samsung" in vl:
        return "Samsung akilli cihaz"
    if "locally administered" in vl:
        return "Gizli MAC cihaz (Mac/iPhone?)"
    if v and v not in ("(Unknown: locally administered)",):
        short = v.split(",")[0].strip()
        return f"{short} ({ip})" if ip else short
    if t:
        return f"{t} ({ip})"
    return f"Cihaz {ip}" if ip else None

conn = sqlite3.connect(DB)
rows = conn.execute(
    "SELECT devMac, devName, devVendor, devType, devLastIP FROM Devices"
).fetchall()
updated = 0
for mac, name, vendor, dtype, ip in rows:
    new = suggest(name, vendor, dtype, ip, mac)
    if not new or new == name:
        continue
    conn.execute("UPDATE Devices SET devName=? WHERE devMac=?", (new, mac))
    print(f"[netalertx-names] {ip or mac}: {name!r} -> {new!r}")
    updated += 1
conn.commit()
conn.close()
print(f"[netalertx-names] {updated} cihaz guncellendi")
PY
