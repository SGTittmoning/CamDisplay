#!/bin/bash
# Wird 5 Minuten nach jedem Boot ausgefuehrt (siehe
# camdisplay-reboot-count-reset.timer). Wenn das System so lange laeuft,
# ohne dass camdisplay-reboot-guard.sh erneut zugeschlagen hat, gilt der
# Zustand als stabil - der Reboot-Zaehler wird zurueckgesetzt, damit ein
# spaeterer, unabhaengiger Fehler wieder die volle Anzahl an Reboot-Versuchen
# zur Verfuegung hat.
# WICHTIG: /boot/firmware kann per "bootro" read-only gemountet sein,
# unabhaengig vom Root-Overlay - siehe camdisplay-reboot-guard.sh.

set -euo pipefail

BOOT_DIR="/boot/firmware"
COUNT_FILE="$BOOT_DIR/.camdisplay-reboot-count"

[ -f "$COUNT_FILE" ] || exit 0

bootro_now() { raspi-config nonint get_bootro_now; }

was_ro=0
[ "$(bootro_now)" -eq 0 ] && was_ro=1
[ "$was_ro" -eq 1 ] && mount -o remount,rw "$BOOT_DIR"
rm -f "$COUNT_FILE"
[ "$was_ro" -eq 1 ] && mount -o remount,ro "$BOOT_DIR"
