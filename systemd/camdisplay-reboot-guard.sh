#!/bin/bash
# Wird von camdisplay-reboot.service aufgerufen, wenn camdisplay.service
# wiederholt gescheitert ist (StartLimitBurst erreicht). Entscheidet, was dann
# sinnvoll ist:
#
#  1. Kamera per TCP NICHT erreichbar: zuerst Geduld - Kamera-Neustart,
#     Firmware-Update oder Switch-Reboot sind nach einigen Minuten vorbei, ein
#     Reboot des Pi bringt dabei nichts. Bis UNREACHABLE_ATTEMPTS Fehlversuche
#     lang: kein Reboot, kein Zaehler, nach RETRY_DELAY Sekunden erneuter
#     Startversuch.
#  2. Ab UNREACHABLE_ATTEMPTS Fehlversuchen in Folge trotzdem Reboot: Warten
#     loest keine Probleme auf dem Pi selbst (DHCP-Lease weg, Link/Netz-Stack
#     haengt, Infrastruktur-Aenderung) - ein Reboot baut das alles neu auf.
#     Der Versuchszaehler liegt in /run und beginnt nach jedem Boot neu.
#  3. Kamera erreichbar, ffplay scheitert trotzdem -> vermutlich lokales
#     Problem (Treiber, Speicher, ...): sofort Reboot.
#  Reboots aus 2. und 3. zaehlen gemeinsam gegen MAX_REBOOTS.
#  4. Limit erreicht -> kein weiterer Reboot (verhindert eine Reboot-Schleife
#     bei DAUERHAFTEM Fehler, z.B. fehlendes Paket, und begrenzt Schreibzugriffe
#     auf die Boot-Partition), aber auch kein endgueltiges Abschalten:
#     langsamer Retry im Abstand von RETRY_DELAY, damit die Anzeige
#     zurueckkommt, sobald die Ursache verschwunden ist. Den Zaehler setzt
#     camdisplay-reboot-count-reset.sh zurueck, sobald der Dienst stabil laeuft.
#
# Ist aus STREAM_URL kein TCP-Ziel ableitbar (z.B. udp://), wird die
# Kamera-Pruefung uebersprungen und wie unter 3. verfahren.
#
# Vor jedem Reboot werden die letzten Logzeilen von camdisplay.service (und der
# Grund des Reboots) in camdisplay-failure-log.txt auf der Boot-Partition
# gesichert: bei aktivem Overlay ist das Journal nach dem Reboot sonst weg, und
# genau dann will man wissen, WARUM neu gestartet wurde. Die Datei ist auf
# LOG_MAX_BYTES begrenzt (aelteste Eintraege fallen zuerst heraus), wird im
# selben Schreibfenster wie der Zaehler geschrieben (ein remount, kein
# zusaetzlicher FAT-Verschleiss durch Umschalten) und ist ueber einen PC
# lesbar (Boot-Partition ist FAT). Die Ausgabe von ffplay ist bereits durch
# camdisplay-run maskiert - keine Zugangsdaten im Log.
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
RUN_DIR="${CAMDISPLAY_RUN_DIR:-/run}"
COUNT_FILE="$BOOT_DIR/.camdisplay-reboot-count"
LOG_FILE="$BOOT_DIR/camdisplay-failure-log.txt"
LOG_LINES=60                                             # Logzeilen pro Reboot
LOG_MAX_BYTES="${CAMDISPLAY_LOG_MAX_BYTES:-32768}"       # Obergrenze der Datei (Umgebung: nur fuer Tests)
# Fehlversuche bei unerreichbarer Kamera seit dem Boot (tmpfs - kein Schreibzugriff
# auf die Boot-Partition, faellt beim Reboot von selbst weg)
UNREACHABLE_FILE="$RUN_DIR/camdisplay-unreachable-count"
MAX_REBOOTS=5
UNREACHABLE_ATTEMPTS=3   # Fehlversuche bei unerreichbarer Kamera bis zum Reboot (je ca. 3 min)
RETRY_DELAY=120          # Sekunden bis zum naechsten Startversuch ohne Reboot
PROBE_TIMEOUT=3     # Sekunden fuer die TCP-Erreichbarkeitspruefung

bootro_now() { raspi-config nonint get_bootro_now; }   # 0=aktiv (ro), 1=inaktiv (rw)

log() { logger -t camdisplay-reboot-guard "$*"; }

# Bericht fuer die Logdatei: Kopfzeile mit Reboot-Nummer, Uptime (Wanduhr ist ohne
# RTC unzuverlaessig) und Grund, danach die letzten Zeilen des Dienstes mit
# monotonen Zeitstempeln. Zeilen werden gekuerzt; fehlt journalctl, steht ein Hinweis da.
failure_report() { # nummer grund
  printf '=== Reboot %s von %s | Uptime %s s | %s\n' "$1" "$MAX_REBOOTS" \
    "$(awk '{print int($1)}' /proc/uptime 2>/dev/null || echo '?')" "$2"
  journalctl -u camdisplay.service -n "$LOG_LINES" --no-pager -o short-monotonic 2>/dev/null \
    | cut -c1-300 || echo "(journalctl nicht verfuegbar)"
  return 0
}

# Haengt den Bericht an die Logdatei an und kuerzt sie auf LOG_MAX_BYTES. Ueber
# eine Temp-Datei, damit ein Stromausfall keine halbe Datei hinterlaesst. Ein
# Fehler hier darf den Reboot nie verhindern - deshalb wird der Aufruf
# abgesichert und die Funktion liefert immer 0.
save_report() {
  local tmp="$BOOT_DIR/.camdisplay-failure-log.tmp"
  { [ -f "$LOG_FILE" ] && cat "$LOG_FILE"; printf '%s\n' "$1"; } | tail -c "$LOG_MAX_BYTES" > "$tmp" \
    && mv "$tmp" "$LOG_FILE"
  return 0
}

# Schreibt den Zaehler und - falls angegeben - den Bericht in EINEM Schreibfenster.
write_count() { # zaehler [bericht]
  local was_ro=0 ok=1
  [ "$(bootro_now)" -eq 0 ] && was_ro=1
  [ "$was_ro" -eq 1 ] && mount -o remount,rw "$BOOT_DIR"
  echo "$1" > "$COUNT_FILE" || ok=0
  if [ "$ok" -eq 1 ] && [ -n "${2:-}" ]; then
    save_report "$2" || true
  fi
  # Auch nach einem Schreibfehler die Boot-Partition wieder schuetzen, bevor abgebrochen wird
  [ "$was_ro" -eq 1 ] && mount -o remount,ro "$BOOT_DIR"
  # Zaehler nicht gespeichert -> Rueckgabe 1 -> "set -e" bricht den Guard ab, OHNE Reboot
  # (sonst waere eine Reboot-Schleife nicht mehr begrenzt). Das ist gewollt. Sonst 0; die
  # frueheren Zeilen "[ ... ] && ..." duerfen NICHT die letzte Anweisung sein (set -e-Falle).
  [ "$ok" -eq 1 ]
}

# Zaehler lesen. Auf der FAT-Boot-Partition kann ein Stromausfall die Datei
# leer oder beschaedigt hinterlassen - dann mit 0 weiterarbeiten statt an der
# Arithmetik (oder einer fuehrenden 0 als Oktalzahl) abzubrechen.
read_count() {
  local c=0
  if [ -f "$1" ]; then
    c=$(cat "$1" 2>/dev/null || true)
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
  # Ein gescheiterter transienter Dienst bliebe geladen und blockierte den Namen ("already exists")
  systemctl reset-failed camdisplay-slow-retry.timer camdisplay-slow-retry.service 2>/dev/null || true
  if ! systemd-run --quiet --unit=camdisplay-slow-retry --on-active="$RETRY_DELAY" \
        --timer-property=AccuracySec=5s \
        /bin/sh -c 'systemctl reset-failed camdisplay.service; systemctl restart camdisplay.service'; then
    log "Konnte den erneuten Startversuch nicht einplanen - camdisplay.service bleibt gestoppt, bitte manuell pruefen."
  fi
  return 0
}

reboot_reason="camdisplay.service wiederholt gescheitert, Kamera erreichbar (oder nicht pruefbar)"

if parse_stream_target; then
  if camera_reachable; then
    rm -f "$UNREACHABLE_FILE"
  else
    unreachable=$(( $(read_count "$UNREACHABLE_FILE") + 1 ))
    # /run nicht beschreibbar o.ae. darf den Retry nicht verhindern
    echo "$unreachable" > "$UNREACHABLE_FILE" 2>/dev/null || true
    if [ "$unreachable" -lt "$UNREACHABLE_ATTEMPTS" ]; then
      log "Kamera $STREAM_HOST:$STREAM_PORT nicht erreichbar (Versuch $unreachable von $UNREACHABLE_ATTEMPTS) - kein Reboot, naechster Startversuch in ${RETRY_DELAY}s; danach Reboot, falls es ein Problem des Pi selbst ist (DHCP/Netz)."
      schedule_slow_retry
      exit 0
    fi
    reboot_reason="Kamera $STREAM_HOST:$STREAM_PORT seit $unreachable Versuchen nicht erreichbar - Reboot, um DHCP/Netz des Pi neu aufzubauen"
  fi
fi

count=$(read_count "$COUNT_FILE")

if [ "$count" -ge "$MAX_REBOOTS" ]; then
  log "Grenze von $MAX_REBOOTS Reboots erreicht - kein weiterer Reboot, camdisplay.service wird im Abstand von ${RETRY_DELAY}s erneut gestartet. Manuelle Pruefung empfohlen."
  schedule_slow_retry
  exit 0
fi

count=$((count + 1))
write_count "$count" "$(failure_report "$count" "$reboot_reason")"
log "$reboot_reason: Reboot $count von $MAX_REBOOTS"
reboot
exit 0
