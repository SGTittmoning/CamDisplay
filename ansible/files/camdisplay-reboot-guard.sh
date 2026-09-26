#!/bin/bash
# Wird von camdisplay-reboot.service aufgerufen, wenn camdisplay.service
# wiederholt gescheitert ist (StartLimitBurst erreicht). Entscheidet, was dann
# sinnvoll ist:
#
#  1. Kamera per TCP NICHT erreichbar -> Netz- oder Kameraproblem (Kamera-
#     Neustart, Switch, Kabel). Ein Reboot des Pi hilft dabei nicht. Kein
#     Reboot, kein Zaehler; nach RETRY_DELAY Sekunden wird camdisplay.service
#     erneut gestartet - so lange, bis die Kamera wieder da ist.
#  2. Kamera erreichbar, ffplay scheitert trotzdem -> vermutlich lokales
#     Problem (Treiber, Speicher, ...). Reboot, aber nur bis MAX_REBOOTS.
#  3. Limit erreicht -> kein weiterer Reboot (verhindert eine Reboot-Schleife
#     bei DAUERHAFTEM Fehler, z.B. fehlendes Paket), aber auch kein
#     endgueltiges Abschalten: derselbe langsame Retry wie unter 1., damit die
#     Anzeige zurueckkommt, sobald die Ursache (auch kameraseitig, z.B. zu
#     viele gleichzeitige Clients) verschwunden ist. Den Zaehler setzt
#     camdisplay-reboot-count-reset.sh zurueck, sobald der Dienst stabil laeuft.
#
# Ist aus STREAM_URL kein TCP-Ziel ableitbar (z.B. udp://), wird die
# Kamera-Pruefung uebersprungen und wie unter 2. verfahren.
#
# Der Zaehler liegt auf der Boot-Partition (siehe camdisplay-update.sh fuer
# die Begruendung: uebersteht auch ein aktives Overlay-Root).
#
# WICHTIG: /boot/firmware kann UNABHAENGIG vom Root-Overlay zusaetzlich per
# "bootro" (raspi-config) read-only gemountet sein - das ist der Normalzustand
# in Produktion (siehe camdisplay-writable.sh). Schreibzugriffe hier muessen
# daher denselben remount-Tanz machen wie camdisplay-update.sh/-writable.sh,
# sonst schlaegt das Schreiben schlicht fehl, sobald "ro" aktiv ist.

set -euo pipefail

# Pfade per Umgebungsvariable ueberschreibbar - nur fuer Tests, im Betrieb
# gelten die Standardwerte.
BOOT_DIR="${CAMDISPLAY_BOOT_DIR:-/boot/firmware}"
STREAM_ENV="${CAMDISPLAY_STREAM_ENV:-/etc/camdisplay/stream.env}"
COUNT_FILE="$BOOT_DIR/.camdisplay-reboot-count"
MAX_REBOOTS=5
RETRY_DELAY=120     # Sekunden bis zum naechsten Startversuch ohne Reboot
PROBE_TIMEOUT=3     # Sekunden fuer die TCP-Erreichbarkeitspruefung

bootro_now() { raspi-config nonint get_bootro_now; }   # 0=aktiv (ro), 1=inaktiv (rw)

log() { logger -t camdisplay-reboot-guard "$*"; }

write_count() {
  local was_ro=0
  [ "$(bootro_now)" -eq 0 ] && was_ro=1
  [ "$was_ro" -eq 1 ] && mount -o remount,rw "$BOOT_DIR"
  echo "$1" > "$COUNT_FILE"
  [ "$was_ro" -eq 1 ] && mount -o remount,ro "$BOOT_DIR"
  return 0   # verhindert, dass "was_ro=0" (letzte Zeile liefert dann 1) unter set -e den Aufrufer abbricht
}

# Zaehler lesen. Auf der FAT-Boot-Partition kann ein Stromausfall die Datei
# leer oder beschaedigt hinterlassen - dann mit 0 weiterarbeiten statt an der
# Arithmetik (oder einer fuehrenden 0 als Oktalzahl) abzubrechen.
read_count() {
  local c=0
  if [ -f "$COUNT_FILE" ]; then
    c=$(cat "$COUNT_FILE" 2>/dev/null || true)
  fi
  [[ "$c" =~ ^[0-9]+$ ]] || c=0
  echo $((10#$c))
}

# Setzt STREAM_HOST/STREAM_PORT aus STREAM_URL in stream.env. Rueckgabe 1, wenn
# kein TCP-basiertes Ziel erkennbar ist. Die Datei wird bewusst NICHT per
# "source" geladen (Zugangsdaten mit $ oder ` wuerden ausgewertet).
parse_stream_target() {
  local url scheme rest authority hostport port
  url=$(sed -n -e 's/^STREAM_URL=//p' "$STREAM_ENV" 2>/dev/null | head -n 1) || return 1
  url=${url#\"}; url=${url%\"}
  url=${url#\'}; url=${url%\'}
  [[ "$url" == *://* ]] || return 1

  scheme=${url%%://*}
  case "$scheme" in
    rtmp) port=1935 ;;
    rtmps) port=443 ;;
    rtmpt|http) port=80 ;;
    rtsp) port=554 ;;
    rtsps) port=322 ;;
    https) port=443 ;;
    *) return 1 ;;
  esac

  rest=${url#*://}
  authority=${rest%%[/?#]*}     # ohne Pfad/Query
  hostport=${authority##*@}     # ohne Benutzer:Passwort@ (auch bei '@' im Passwort)

  if [[ "$hostport" == \[* ]]; then                      # IPv6: [::1]:554
    STREAM_HOST=${hostport%%]*}; STREAM_HOST=${STREAM_HOST#[}
    [[ "${hostport#*]}" == :* ]] && port=${hostport#*]:}
  else
    STREAM_HOST=${hostport%%:*}
    [[ "$hostport" == *:* ]] && port=${hostport##*:}
  fi

  [ -n "$STREAM_HOST" ] || return 1
  [[ "$port" =~ ^[0-9]+$ ]] || return 1
  STREAM_PORT=$port
  return 0
}

# TCP-Verbindungsaufbau ohne Zusatzpakete (netcat ist auf Raspberry Pi OS Lite
# nicht garantiert vorhanden) - ueber bashs /dev/tcp, mit hartem Zeitlimit.
camera_reachable() {
  timeout "$PROBE_TIMEOUT" bash -c 'exec 3<>"/dev/tcp/$1/$2"' _ "$STREAM_HOST" "$STREAM_PORT" 2>/dev/null
}

# Plant einen erneuten Startversuch ohne Reboot. reset-failed ist noetig, weil
# der Dienst sonst wegen des erreichten Start-Limits nicht mehr startet.
# Transiente Timer liegen in /run und funktionieren auch mit Overlay/Bootro.
schedule_slow_retry() {
  systemctl stop camdisplay-slow-retry.timer camdisplay-slow-retry.service 2>/dev/null || true
  if ! systemd-run --quiet --unit=camdisplay-slow-retry --on-active="$RETRY_DELAY" \
        --timer-property=AccuracySec=5s \
        /bin/sh -c 'systemctl reset-failed camdisplay.service; systemctl restart camdisplay.service'; then
    log "Konnte den erneuten Startversuch nicht einplanen - camdisplay.service bleibt gestoppt, bitte manuell pruefen."
  fi
  return 0
}

if parse_stream_target && ! camera_reachable; then
  log "Kamera $STREAM_HOST:$STREAM_PORT nicht erreichbar - Netz-/Kameraproblem, ein Reboot hilft nicht. Kein Reboot, naechster Startversuch in ${RETRY_DELAY}s."
  schedule_slow_retry
  exit 0
fi

count=$(read_count)

if [ "$count" -ge "$MAX_REBOOTS" ]; then
  log "Grenze von $MAX_REBOOTS Reboots erreicht - kein weiterer Reboot, camdisplay.service wird im Abstand von ${RETRY_DELAY}s erneut gestartet. Manuelle Pruefung empfohlen."
  schedule_slow_retry
  exit 0
fi

count=$((count + 1))
write_count "$count"
log "camdisplay.service wiederholt gescheitert, Kamera erreichbar (oder nicht pruefbar): Reboot $count von $MAX_REBOOTS"
reboot
exit 0
