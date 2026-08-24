#!/usr/bin/env bash
# NetAlertX yeni cihaz — Hermes no_agent stdout.
exec "$(dirname "$0")/netalert-events.sh" new_device
