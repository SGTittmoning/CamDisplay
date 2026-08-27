#!/bin/bash
# Ziel: /root/bin/camdisplay-writable.sh auf dem Raspberry Pi (CamDisplay)
#
# Schaltet das System zwischen "beschreibbar" (fuer manuelle
# Konfigurationsarbeiten) und "read-only" (OverlayFS + Boot-Partition-RO,
# Normalzustand) um.
#
# Fuer apt-Updates stattdessen camdisplay-update.sh verwenden (macht denselben
# Umschaltvorgang inkl. apt full-upgrade/autoremove/clean automatisch).
# Dieses Script hier ist fuer alles andere: manuelle Config-Edits, neue
# Pakete testen, Log-Dateien inspizieren, etc. - insbesondere wenn gerade
# kein Ansible-Zugriff moeglich ist.
#
# Hintergrund/Mechanik (siehe auch camdisplay-update.sh):
# - Root-OverlayFS ist ein Boot-Zeit-Mechanismus (Kernel-Cmdline-Parameter)
#   - ein Toggle wirkt erst nach einem Reboot.
# - Die Boot-Partition (/boot/firmware) kann live per remount umgeschaltet
#   werden, aber raspi-configs eigene disable_bootro/enable_bootro-
#   Funktionen (persistente fstab-Einstellung) verweigern die Arbeit,
#   solange das Root-Overlay LIVE aktiv ist.
# - Deshalb braucht "rw" ggf. einen Zwischen-Reboot (nur falls das Overlay
#   beim Aufruf noch aktiv war), "ro" braucht immer einen Reboot am Ende,
#   um das Overlay wieder scharf zu schalten.
#
# Nutzung:
#   sudo camdisplay-writable.sh status   Aktuellen Zustand anzeigen
#   sudo camdisplay-writable.sh rw       System beschreibbar machen (ggf. 2x
#                                        aufrufen, mit einem Reboot dazwischen -
#                                        das Script sagt an, was noetig ist)
#   sudo camdisplay-writable.sh ro       System wieder read-only setzen
#                                        (OverlayFS + Boot-RO), danach einmal
#                                        manuell rebooten
#
# Angepasst aus usv-pi-writable.sh (FFW-Tittmoning/ffw-usv-nut-proxmox).

set -euo pipefail

BOOT_DIR="/boot/firmware"
# WICHTIG: State-Datei liegt bewusst auf der Boot-Partition, nicht unter
# /var/lib (Root-Dateisystem)! Solange OverlayFS aktiv ist, landet jeder
# Schreibzugriff auf das Root-FS im fluechtigen tmpfs-Upper-Layer und ist
# nach einem Reboot wieder weg - /boot/firmware wird vom Overlay nie
# erfasst und bleibt garantiert erhalten. Aus demselben Grund: JEDE
# dauerhafte Aenderung an /etc/fstab (Root-FS!) ist nur zuverlaessig
# moeglich, wenn OverlayFS live inaktiv ist - siehe cmd_ro() unten.
STATE_FILE="$BOOT_DIR/.camdisplay-writable.state"

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
}

clear_state() {
  [ -f "$STATE_FILE" ] || return 0
  local was_ro=0
  [ "$(bootro_now)" -eq 0 ] && was_ro=1
  [ "$was_ro" -eq 1 ] && mount -o remount,rw "$BOOT_DIR"
  rm -f "$STATE_FILE"
  [ "$was_ro" -eq 1 ] && mount -o remount,ro "$BOOT_DIR"
}

print_status() {
  echo "OverlayFS aktiv (live):      $([ "$(overlay_now)" -eq 0 ] && echo ja || echo nein)"
  echo "Boot-Partition read-only:    $([ "$(bootro_now)" -eq 0 ] && echo ja || echo nein)"
  if [ -f "$STATE_FILE" ]; then
    echo "rw-Vorgang-Status:            $(cat "$STATE_FILE")"
  else
    echo "rw-Vorgang-Status:            idle"
  fi
}

cmd_rw() {
  require_root

  if [ "$(overlay_now)" -eq 0 ]; then
    echo "OverlayFS ist aktiv - deaktiviere (wirkt erst nach Reboot)..."
    raspi-config nonint disable_overlayfs
    write_state "awaiting-reboot"
    echo ""
    echo "Bitte jetzt rebooten, danach 'sudo $0 rw' erneut ausfuehren:"
    echo "  sudo reboot"
    return 0
  fi

  echo "OverlayFS ist bereits inaktiv (live)."

  if [ "$(bootro_now)" -eq 0 ]; then
    echo "Deaktiviere Boot-Partition-Schreibschutz (fstab, persistent)..."
    raspi-config nonint disable_bootro
    echo "Mounte Boot-Partition live beschreibbar..."
    mount -o remount,rw "$BOOT_DIR"
  else
    echo "Boot-Partition ist bereits beschreibbar."
  fi

  clear_state
  echo ""
  echo "System ist jetzt vollstaendig beschreibbar (Root + Boot-Partition)."
  echo "Nach Abschluss der Konfigurationsarbeiten: sudo $0 ro"
}

cmd_ro() {
  require_root

  OVERLAY_ALREADY_ACTIVE=0
  [ "$(overlay_now)" -eq 0 ] && OVERLAY_ALREADY_ACTIVE=1

  if [ "$(bootro_now)" -eq 1 ]; then
    if [ "$OVERLAY_ALREADY_ACTIVE" -eq 1 ]; then
      echo "Boot-Partition ist noch nicht read-only, OverlayFS aber schon aktiv." >&2
      echo "Eine Aenderung an /etc/fstab waere in diesem Zustand NICHT dauerhaft" >&2
      echo "(landet nur im RAM-Overlay). Bitte zuerst:" >&2
      echo "  sudo $0 rw" >&2
      echo "damit noetigen Reboot durchfuehren, Boot-RO dort setzen, dann" >&2
      echo "erneut 'sudo $0 ro' ausfuehren." >&2
      exit 1
    fi
    echo "Setze Boot-Partition wieder read-only (fstab + live)..."
    raspi-config nonint enable_bootro
    mount -o remount,ro "$BOOT_DIR"
  else
    echo "Boot-Partition ist bereits read-only."
  fi

  if [ "$OVERLAY_ALREADY_ACTIVE" -eq 1 ]; then
    clear_state
    echo ""
    echo "OverlayFS war bereits aktiv. Fertig - System ist jetzt vollstaendig read-only."
    print_status
    return 0
  fi

  echo "Aktiviere OverlayFS wieder (wirkt erst nach Reboot)..."
  raspi-config nonint enable_overlayfs

  clear_state
  echo ""
  echo "Fertig. Bitte jetzt rebooten, damit OverlayFS wieder aktiv wird:"
  echo "  sudo reboot"
}

case "${1:-}" in
  status) print_status ;;
  rw)     cmd_rw ;;
  ro)     cmd_ro ;;
  *)
    echo "Usage: $0 {status|rw|ro}" >&2
    exit 1
    ;;
esac
