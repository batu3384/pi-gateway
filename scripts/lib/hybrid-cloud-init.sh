#!/usr/bin/env bash
# Hybrid: bootfs cloud-init (SSD veri diski + fresh install)
set -euo pipefail

hybrid_setup_script_path() {
  local project_dir="${1:-}"
  if [[ -n "$project_dir" && -f "${project_dir}/scripts/pi/setup-ssd-data.sh" ]]; then
    echo "${project_dir}/scripts/pi/setup-ssd-data.sh"
    return 0
  fi
  local lib
  lib="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  echo "${lib}/../pi/setup-ssd-data.sh"
}

hybrid_read_bootfs_identity() {
  local boot_dir="$1"
  PI_USER="${PI_USER:-batu}"
  PI_HOSTNAME="${PI_HOSTNAME:-batu}"
  if [[ -f "${boot_dir}/userconf" ]]; then
    PI_USER="$(cut -d: -f1 "${boot_dir}/userconf" | tr -d '[:space:]')"
    PI_HOSTNAME="${PI_USER}"
  fi
  if [[ -f "${boot_dir}/user-data" ]]; then
    local h
    h="$(grep -E '^hostname:' "${boot_dir}/user-data" 2>/dev/null | awk '{print $2}' | tr -d '[:space:]' || true)"
    [[ -n "$h" ]] && PI_HOSTNAME="$h"
  fi
}

hybrid_ssd_setup_script_b64() {
  local setup_script="$1"
  base64 < "$setup_script" | tr -d '\n'
}

# YAML write_files blogu (pi-setup-ssd-data + pi-ssd-data.service)
hybrid_ssd_write_files_yaml() {
  local b64="$1" pi_user="$2" remote_dir="$3" ssd_mount="${4:-/mnt/ssd}"
  cat <<EOF
  - path: /usr/local/sbin/pi-setup-ssd-data.sh
    encoding: b64
    permissions: '0755'
    content: ${b64}

  - path: /etc/systemd/system/pi-ssd-data.service
    permissions: '0644'
    content: |
      [Unit]
      Description=Pi Gateway USB SSD data disk setup
      After=local-fs-pre.target
      Before=remote-fs.target
      ConditionPathExists=!${ssd_mount}/.pi-gateway-initialized
      DefaultDependencies=no

      [Service]
      Type=oneshot
      RemainAfterExit=yes
      Environment=PI_USER=${pi_user}
      Environment=REMOTE_DIR=${remote_dir}
      Environment=PI_SSD_CONFIRM_FORMAT=yes
      ExecStart=/usr/local/sbin/pi-setup-ssd-data.sh
      TimeoutStartSec=300

      [Install]
      WantedBy=multi-user.target
EOF
}

hybrid_ssd_runcmd_yaml() {
  cat <<'EOF'
  - [ systemctl, daemon-reload ]
  - [ systemctl, enable, pi-ssd-data.service ]
  - [ systemctl, start, pi-ssd-data.service ]
EOF
}

hybrid_user_data_has_ssd_setup() {
  local ud="$1"
  [[ -f "$ud" ]] || return 1
  grep -q 'pi-ssd-data.service' "$ud" 2>/dev/null && \
    grep -q 'PI_SSD_CONFIRM_FORMAT=yes' "$ud" 2>/dev/null && \
    grep -q 'pi-setup-ssd-data.sh' "$ud" 2>/dev/null
}

# Mevcut user-data'ya SSD bloklarini ekle (users/keyboard vb. korunur)
hybrid_inject_ssd_into_user_data() {
  local user_data="$1" setup_script="$2" pi_user="$3" remote_dir="$4" ssd_mount="${5:-/mnt/ssd}"
  local b64 wf run
  b64="$(hybrid_ssd_setup_script_b64 "$setup_script")"
  wf="$(hybrid_ssd_write_files_yaml "$b64" "$pi_user" "$remote_dir" "$ssd_mount")"
  run="$(hybrid_ssd_runcmd_yaml)"

  python3 - "$user_data" "$wf" "$run" <<'PY'
import sys

path, wf_block, run_block = sys.argv[1], sys.argv[2], sys.argv[3]
text = open(path, encoding="utf-8").read()
if "pi-ssd-data.service" in text and "PI_SSD_CONFIRM_FORMAT=yes" in text:
    sys.exit(0)

def indent_block(block: str, base: int) -> str:
    lines = block.strip("\n").splitlines()
    return "\n".join((" " * base + ln) if ln.strip() else ln for ln in lines)

if "write_files:" in text:
    if "pi-setup-ssd-data.sh" not in text:
        marker = "write_files:"
        idx = text.index(marker) + len(marker)
        text = text[:idx] + "\n" + indent_block(wf_block, 0).lstrip() + text[idx:]
else:
    text = text.rstrip() + "\n\nwrite_files:\n" + wf_block

if "runcmd:" in text:
    if "pi-ssd-data.service" not in text.split("runcmd:", 1)[1]:
        marker = "runcmd:"
        idx = text.index(marker) + len(marker)
        text = text[:idx] + "\n" + run_block.strip("\n") + text[idx:]
else:
    text = text.rstrip() + "\n\nruncmd:\n" + run_block

open(path, "w", encoding="utf-8").write(text)
PY
}

# Sifirdan kurulum (setup-hybrid Imager)
hybrid_write_fresh_install_cloud_init() {
  local dir="$1" setup_script="$2" pi_user="$3" pi_hostname="$4" pi_password="$5"
  local pi_timezone="${6:-Europe/Istanbul}" pi_locale="${7:-tr_TR.UTF-8}" ssd_mount="${8:-/mnt/ssd}"

  local b64 hash remote_dir wf run
  mkdir -p "$dir"
  b64="$(hybrid_ssd_setup_script_b64 "$setup_script")"
  hash="$(printf '%s' "$pi_password" | openssl passwd -6 -stdin)"
  remote_dir="/home/${pi_user}/pi-gateway"
  wf="$(hybrid_ssd_write_files_yaml "$b64" "$pi_user" "$remote_dir" "$ssd_mount")"
  run="$(hybrid_ssd_runcmd_yaml)"

  cat > "${dir}/user-data" <<EOF
#cloud-config
hostname: ${pi_hostname}
manage_etc_hosts: true
timezone: ${pi_timezone}
locale: ${pi_locale}

keyboard:
  layout: tr
  model: pc105

users:
  - name: ${pi_user}
    gecos: Pi Gateway
    groups: users,adm,dialout,audio,netdev,video,plugdev,cdrom,games,input,gpio,spi,i2c,render,sudo
    shell: /bin/bash
    lock_passwd: false
    passwd: '${hash}'
    sudo: ALL=(ALL) NOPASSWD:ALL

enable_ssh: true
ssh_pwauth: true

package_update: true
package_upgrade: false

growpart:
  mode: off
resize_rootfs: false

write_files:
${wf}
runcmd:
  - [ localectl, set-locale, LANG=tr_TR.UTF-8, LC_ALL=tr_TR.UTF-8, LANGUAGE=tr_TR.UTF-8 ]
  - [ localectl, set-keymap, tr ]
  - [ timedatectl, set-timezone, Europe/Istanbul ]
  - [ bash, -lc, "raspi-config nonint do_configure_keyboard tr || true" ]
${run}
EOF

  cat > "${dir}/network-config" <<EOF
network:
  version: 2
  ethernets:
    eth0:
      dhcp4: true
      optional: false
EOF

  cat > "${dir}/meta-data" <<EOF
instance-id: pi-gateway-hybrid-001
local-hostname: ${pi_hostname}
EOF

  cat > "${dir}/userconf" <<EOF
${pi_user}:${hash}
EOF
}

# restore-hybrid: mevcut bootfs user-data korunarak SSD setup eklenir
hybrid_write_ssd_user_data() {
  local boot_dir="$1"
  local project_dir="${2:-}"
  local ssd_mount="${SSD_MOUNT:-/mnt/ssd}"

  hybrid_read_bootfs_identity "$boot_dir"

  local setup_script remote_dir ud
  setup_script="$(hybrid_setup_script_path "$project_dir")"
  [[ -f "$setup_script" ]] || return 1
  remote_dir="/home/${PI_USER}/pi-gateway"
  ud="${boot_dir}/user-data"

  if hybrid_user_data_has_ssd_setup "$ud"; then
    return 0
  fi

  [[ -f "$ud" ]] && cp "$ud" "${ud}.bak-hybrid-restore" 2>/dev/null || true

  if [[ -f "$ud" ]] && grep -qE '^(users:|enable_ssh:|package_update:)' "$ud" 2>/dev/null; then
    hybrid_inject_ssd_into_user_data "$ud" "$setup_script" "$PI_USER" "$remote_dir" "$ssd_mount"
    return 0
  fi

  local b64 wf run
  b64="$(hybrid_ssd_setup_script_b64 "$setup_script")"
  wf="$(hybrid_ssd_write_files_yaml "$b64" "$PI_USER" "$remote_dir" "$ssd_mount")"
  run="$(hybrid_ssd_runcmd_yaml)"

  cat > "$ud" <<EOF
#cloud-config
hostname: ${PI_HOSTNAME}
manage_etc_hosts: true

growpart:
  mode: off
resize_rootfs: false

write_files:
${wf}
runcmd:
${run}
EOF
}
