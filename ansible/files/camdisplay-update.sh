#!/bin/bash
# Wartungs-Update-Zyklus fuer den CamDisplay-Pi mit aktivem OverlayFS.
#
# OverlayFS (raspi-config) macht das Root-Dateisystem nur zur Boot-Zeit
# beschreibbar/unbeschreibbar (Kernel-Cmdline-Parameter) - ein Toggle wirkt
# erst nach einem Reboot. Die Boot-Partition (/boot/firmware) dagegen kann
# live per remount umgeschaltet werden, die persistente fstab-Einstellung
# (raspi-config disable_bootro/enable_bootro) verweigert aber die Arbeit,
# solange das Root-Overlay live aktiv ist - deshalb der zweiphasige Ablauf
# mit genau einem Zwischen-Reboot.
#
# Nutzung:
#   sudo camdisplay-update.sh status   Aktuellen Zustand anzeigen
#   sudo camdisplay-update.sh begin    Phase 1: OverlayFS deaktivieren
#                                      -> danach manuell rebooten
#   sudo camdisplay-update.sh apply    Phase 2 (nach dem Reboot): Boot-RO
#                                      deaktivieren, Updates installieren,
#                                      bereinigen, Boot-RO + OverlayFS wieder
#                                      aktivieren -> danach nochmal manuell
#                                      rebooten
#
# Schlaegt "apply" nach dem ersten Eingriff fehl (z.B. apt ohne Netz), wird
# der geschuetzte Zustand (Boot-RO + OverlayFS) trotzdem wiederhergestellt und
# der Zyklus beendet - das Geraet bleibt nie unbemerkt beschreibbar. Ein
# einfaches Wiederholen von "apply" wuerde das nicht leisten: Boot-RO waere
# dann schon aus, bootro_now meldet "inaktiv", und der Lauf stellte es nach
# dem Erfolg nie wieder her. Nach einem Abbruch also mit "begin" neu starten.

set -euo pipefail

BOOT_DIR="/boot/firmware"
# WICHTIG: State-Datei liegt bewusst auf der Boot-Partition, nicht unter
# /var/lib (Root-Dateisystem)! Wenn OverlayFS beim Aufruf von 'begin' noch
# aktiv ist, landet jeder Schreibzugriff auf das Root-FS im fluechtigen
# tmpfs-Upper-Layer und ist nach dem noetigen Zwischen-Reboot wieder weg.
# /boot/firmware wird vom Overlay nie erfasst (overlayroot behandelt vfat
# als "fs-unsupported"), bleibt also ueber den Reboot hinweg garantiert
# erhalten.
STATE_FILE="$BOOT_DIR/.camdisplay-update.state"

overlay_now() { raspi-config nonint get_overlay_now; }   # 0=aktiv, 1=inaktiv
bootro_now()  { raspi-config nonint get_bootro_now; }     # 0=aktiv, 1=inaktiv

require_root() {
  if [ "$(id -u)" -ne 0 ]; then
    echo "Bitte mit sudo ausfuehren." >&2
    exit 1
  fi
}

write_state() {
  local was_ro=0
  [ "$(bootro_now)" -eq 0 ] && was_ro=1
  [ "$was_ro" -eq 1 ] && mount -o remount,rw "$BOOT_DIR"
  echo "$1" > "$STATE_FILE"
  [ "$was_ro" -eq 1 ] && mount -o remount,ro "$BOOT_DIR"
  return 0   # verhindert, dass "was_ro=0" (letzte Zeile liefert dann 1) unter set -e den Aufrufer abbricht
}

clear_state() {
  [ -f "$STATE_FILE" ] || return 0
  local was_ro=0
  [ "$(bootro_now)" -eq 0 ] && was_ro=1
  [ "$was_ro" -eq 1 ] && mount -o remount,rw "$BOOT_DIR"
  rm -f "$STATE_FILE"
  [ "$was_ro" -eq 1 ] && mount -o remount,ro "$BOOT_DIR"
  return 0   # verhindert, dass "was_ro=0" (letzte Zeile liefert dann 1) unter set -e den Aufrufer abbricht
}

print_status() {
  echo "OverlayFS aktiv (live):      $([ "$(overlay_now)" -eq 0 ] && echo ja || echo nein)"
  echo "Boot-Partition read-only:    $([ "$(bootro_now)" -eq 0 ] && echo ja || echo nein)"
  if [ -f "$STATE_FILE" ]; then
    echo "Update-Zyklus-Status:         $(cat "$STATE_FILE")"
  else
    echo "Update-Zyklus-Status:         idle"
  fi
  if systemctl is-active --quiet camdisplay.service; then
    echo "Hinweis: camdisplay.service laeuft aktiv - waehrend der beiden Reboots ist das Kamerabild kurz unterbrochen."
  fi
}

cmd_begin() {
  require_root
  if [ -f "$STATE_FILE" ]; then
    echo "Es laeuft bereits ein Update-Zyklus (Status: $(cat "$STATE_FILE"))." >&2
    echo "Bitte erst mit 'apply' abschliessen, oder $STATE_FILE manuell entfernen." >&2
    exit 1
  fi

  echo "--- Zustand vor Aenderung ---"
  print_status
  echo ""

  echo "Deaktiviere OverlayFS (wirkt erst nach Reboot)..."
  raspi-config nonint disable_overlayfs

  if [ "$(overlay_now)" -eq 1 ]; then
    write_state "awaiting-apply-no-reboot"
    echo ""
    echo "OverlayFS war bereits inaktiv (live) - kein Zwischenreboot noetig."
    echo "Weiter mit: sudo $0 apply"
  else
    write_state "awaiting-reboot-1"
    echo ""
    echo "Bitte jetzt rebooten, danach 'sudo $0 apply' ausfuehren:"
    echo "  sudo reboot"
  fi
}

# EXIT-Trap von cmd_apply: laeuft der Update-Lauf nicht bis zum Ende durch,
# wird der geschuetzte Zustand wiederhergestellt. Jeder Schritt einzeln mit
# "|| true", damit ein weiterer Fehler die Wiederherstellung nicht abbricht.
APPLY_COMPLETE=0
BOOTRO_WAS_ACTIVE=0
restore_protection_after_failure() {
  if [ "$APPLY_COMPLETE" -ne 1 ]; then
    {
      echo ""
      echo "!!! FEHLER: Der Update-Lauf ist abgebrochen (Ursache siehe Meldungen darueber)."
      echo "!!! Stelle den geschuetzten Zustand wieder her, damit das Geraet nicht"
      echo "!!! unbemerkt beschreibbar bleibt. Der Zyklus ist damit beendet; das System"
      echo "!!! kann unvollstaendig aktualisiert sein. Zum Wiederholen: sudo $0 begin"
    } >&2
    clear_state || true
    if [ "$BOOTRO_WAS_ACTIVE" -eq 1 ]; then
      raspi-config nonint enable_bootro || echo "!!! enable_bootro fehlgeschlagen - bitte pruefen: sudo $0 status" >&2
      mount -o remount,ro "$BOOT_DIR" || true
    fi
    raspi-config nonint enable_overlayfs || echo "!!! enable_overlayfs fehlgeschlagen - bitte pruefen: sudo $0 status" >&2
    echo "!!! Bitte jetzt rebooten, damit OverlayFS/Boot-RO wieder aktiv werden." >&2
  fi
  return 0
}

cmd_apply() {
  require_root
  if [ ! -f "$STATE_FILE" ]; then
    echo "Kein laufender Update-Zyklus gefunden. Bitte zuerst 'sudo $0 begin' ausfuehren." >&2
    exit 1
  fi
  ST=$(cat "$STATE_FILE")
  if [ "$ST" != "awaiting-reboot-1" ] && [ "$ST" != "awaiting-apply-no-reboot" ]; then
    echo "Unerwarteter Zustand '$ST' in $STATE_FILE. Bitte manuell pruefen." >&2
    exit 1
  fi
  if [ "$(overlay_now)" -eq 0 ]; then
    echo "OverlayFS ist noch aktiv (live) - Phase 1 ist noch nicht durch einen Reboot wirksam geworden." >&2
    echo "Bitte zuerst rebooten, dann diesen Befehl erneut ausfuehren." >&2
    exit 1
  fi

  echo "OverlayFS ist inaktiv (live), fahre fort."

  # ab hier wird das System veraendert: bei Abbruch Schutz wiederherstellen
  trap restore_protection_after_failure EXIT

  BOOTRO_WAS_ACTIVE=0
  if [ "$(bootro_now)" -eq 0 ]; then
    BOOTRO_WAS_ACTIVE=1
    echo "Deaktiviere Boot-Partition-Schreibschutz (fstab, persistent)..."
    raspi-config nonint disable_bootro
    echo "Mounte Boot-Partition live beschreibbar..."
    mount -o remount,rw "$BOOT_DIR"
  fi

  echo ""
  echo "=== apt update / full-upgrade ==="
  apt-get update
  DEBIAN_FRONTEND=noninteractive apt-get full-upgrade -y

  echo ""
  echo "=== Bereinigen ==="
  apt-get autoremove -y
  apt-get clean

  if [ "$BOOTRO_WAS_ACTIVE" -eq 1 ]; then
    echo ""
    echo "Setze Boot-Partition wieder read-only (fstab + live)..."
    raspi-config nonint enable_bootro
    mount -o remount,ro "$BOOT_DIR"
  fi

  echo ""
  echo "Aktiviere OverlayFS wieder (wirkt erst nach Reboot)..."
  raspi-config nonint enable_overlayfs

  clear_state
  APPLY_COMPLETE=1

  echo ""
  echo "Fertig. Bitte jetzt final rebooten, damit OverlayFS/Boot-RO wieder"
  echo "aktiv werden:"
  echo "  sudo reboot"
}

case "${1:-}" in
  status) print_status ;;
  begin)  cmd_begin ;;
  apply)  cmd_apply ;;
  *)
    echo "Usage: $0 {status|begin|apply}" >&2
    exit 1
    ;;
esac
