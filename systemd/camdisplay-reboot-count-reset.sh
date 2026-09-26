#!/bin/bash
# Wird vom camdisplay-reboot-count-reset.timer ausgefuehrt (5 Minuten nach dem
# Boot, danach alle 5 Minuten). Setzt den Reboot-Zaehler von
# camdisplay-reboot-guard.sh nur zurueck, wenn camdisplay.service tatsaechlich
# seit mindestens STABLE_SECS ununterbrochen laeuft - damit ein spaeterer,
# unabhaengiger Fehler wieder die volle Anzahl an Reboot-Versuchen hat, ein
# Dienst, der nur kurz oder immer wieder anlaeuft, den Zaehler aber nicht
# heimlich zuruecksetzt.
#
# Ein einmaliger Lauf 5 Minuten nach dem Boot reicht dafuer nicht: kommt die
# Anzeige erst spaeter zurueck (z.B. per langsamem Retry nach einem
# Kameraausfall), muss der Zaehler trotzdem noch geleert werden - deshalb
# wiederholt der Timer die Pruefung.
#
# Zeitbasis: monotone Zeit (systemd ActiveEnterTimestampMonotonic gegen
# /proc/uptime). Der Pi hat keine Echtzeituhr, die Wanduhr springt beim
# NTP-Sync und waere hier unbrauchbar.
#
# WICHTIG: /boot/firmware kann per "bootro" read-only gemountet sein,
# unabhaengig vom Root-Overlay - siehe camdisplay-reboot-guard.sh.

set -euo pipefail

# Pfade/Schwellwerte per Umgebungsvariable ueberschreibbar - nur fuer Tests.
BOOT_DIR="${CAMDISPLAY_BOOT_DIR:-/boot/firmware}"
UPTIME_FILE="${CAMDISPLAY_UPTIME_FILE:-/proc/uptime}"
STABLE_SECS="${CAMDISPLAY_STABLE_SECS:-300}"
RUN_DIR="${CAMDISPLAY_RUN_DIR:-/run}"
COUNT_FILE="$BOOT_DIR/.camdisplay-reboot-count"
UNREACHABLE_FILE="$RUN_DIR/camdisplay-unreachable-count"   # siehe camdisplay-reboot-guard.sh

# Nichts zu tun, wenn kein Zaehler existiert (kein Schreibzugriff auf die
# Boot-Partition in diesem Fall).
[ -f "$COUNT_FILE" ] || [ -f "$UNREACHABLE_FILE" ] || exit 0

# Laeuft camdisplay.service seit mindestens STABLE_SECS ununterbrochen?
service_stable() {
  local enter now_us
  systemctl is-active --quiet camdisplay.service || return 1
  enter=$(systemctl show --property=ActiveEnterTimestampMonotonic --value camdisplay.service 2>/dev/null || true)
  [[ "$enter" =~ ^[0-9]+$ ]] || return 1
  [ "$enter" -gt 0 ] || return 1
  now_us=$(awk '{printf "%d", $1 * 1000000}' "$UPTIME_FILE")
  [ $(( (now_us - enter) / 1000000 )) -ge "$STABLE_SECS" ]
}

# Noch nicht stabil: Zaehler behalten, der Timer prueft spaeter erneut.
if ! service_stable; then
  exit 0
fi

# Fehlversuchs-Zaehler fuer "Kamera nicht erreichbar" (liegt in /run, tmpfs)
rm -f "$UNREACHABLE_FILE"

# Persistenter Reboot-Zaehler auf der Boot-Partition
[ -f "$COUNT_FILE" ] || exit 0

bootro_now() { raspi-config nonint get_bootro_now; }

was_ro=0
[ "$(bootro_now)" -eq 0 ] && was_ro=1
[ "$was_ro" -eq 1 ] && mount -o remount,rw "$BOOT_DIR"
rm -f "$COUNT_FILE"
[ "$was_ro" -eq 1 ] && mount -o remount,ro "$BOOT_DIR"

exit 0   # verhindert, dass "was_ro=0" (letzte Zeile liefert dann 1) das Skript mit Exit-Code 1
         # beendet und den Type=oneshot-Service faelschlich als failed markiert
