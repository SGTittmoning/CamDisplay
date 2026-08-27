#!/bin/bash
# Wird von camdisplay-reboot.service aufgerufen, wenn camdisplay.service
# wiederholt gescheitert ist (StartLimitBurst erreicht). Rebootet nur bis
# zu einer Obergrenze - bei einem DAUERHAFTEN Fehler (z.B. fehlendes Paket,
# falsche Konfiguration) soll das System nicht fuer immer neu starten,
# sondern anhalten und auf manuelle Untersuchung warten.
#
# Hintergrund: am 2026-08-21 fehlte auf einem Testsystem libegl1, wodurch
# ffplay bei jedem Versuch sofort scheiterte - ohne diese Grenze haette
# der Pi unbegrenzt oft neu gestartet.
#
# Zaehler liegt auf der Boot-Partition (siehe camdisplay-update.sh fuer
# die Begruendung: uebersteht auch ein aktives Overlay-Root).
#
# WICHTIG: /boot/firmware kann UNABHAENGIG vom Root-Overlay zusaetzlich per
# "bootro" (raspi-config) read-only gemountet sein - das ist der Normalzustand
# in Produktion (siehe camdisplay-writable.sh). Schreibzugriffe hier muessen
# daher denselben remount-Tanz machen wie camdisplay-update.sh/-writable.sh,
# sonst schlaegt das Schreiben schlicht fehl, sobald "ro" aktiv ist.

set -euo pipefail

BOOT_DIR="/boot/firmware"
COUNT_FILE="$BOOT_DIR/.camdisplay-reboot-count"
MAX_REBOOTS=5

bootro_now() { raspi-config nonint get_bootro_now; }   # 0=aktiv (ro), 1=inaktiv (rw)

write_count() {
  local was_ro=0
  [ "$(bootro_now)" -eq 0 ] && was_ro=1
  [ "$was_ro" -eq 1 ] && mount -o remount,rw "$BOOT_DIR"
  echo "$1" > "$COUNT_FILE"
  [ "$was_ro" -eq 1 ] && mount -o remount,ro "$BOOT_DIR"
}

count=0
[ -f "$COUNT_FILE" ] && count=$(cat "$COUNT_FILE")
count=$((count + 1))

if [ "$count" -gt "$MAX_REBOOTS" ]; then
  logger -t camdisplay-reboot-guard "Grenze von $MAX_REBOOTS Reboots erreicht - camdisplay.service wird deaktiviert statt weiter zu rebooten. Manuelle Pruefung noetig."
  write_count "$count"
  systemctl disable --now camdisplay.service || true
  exit 0
fi

write_count "$count"
logger -t camdisplay-reboot-guard "camdisplay.service wiederholt gescheitert, Reboot $count von $MAX_REBOOTS"
reboot
