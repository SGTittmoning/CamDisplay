#!/bin/bash
# Startet ffplay fuer camdisplay.service (Ziel: /usr/local/bin/camdisplay-run).
#
# Erwartet STREAM_URL (und optional STREAM_OPTS) aus der Umgebung - beides
# liefert systemd ueber EnvironmentFile=/etc/camdisplay/stream.env.
#
# Warum ein Wrapper statt ffplay direkt in der Unit:
#  - ffplay gibt bei Verbindungsfehlern die komplette URL aus - inklusive
#    Zugangsdaten. Die Ausgabe wird hier gefiltert, bevor sie ins Journal geht.
#  - Alle ffplay-Flags stehen an einer Stelle und lassen sich ohne
#    systemd-Quoting-Fallen kommentieren.
#
# Grenze der Maskierung: Die URL steht weiterhin in der Kommandozeile des
# ffplay-Prozesses (ps, /proc/<pid>/cmdline, "systemctl status") - das laesst
# sich mit ffplay nicht vermeiden. Siehe Abschnitt "Credentials" in der README.
#
# Flags:
#  -autoexit                 beendet ffplay bei Stream-Ende (sonst friert das
#                            letzte Bild ein, und weder Restart= noch der
#                            Reboot-Guard greifen)
#  -rw_timeout 5000000       Socket-Timeout in Mikrosekunden: beendet ffplay,
#                            wenn die Verbindung haengt, ohne sauberes Ende
#                            (Kamera/Switch weg). Gemessen: ffplay beendet sich
#                            nach etwa dem 3-fachen dieses Werts. NICHT
#                            "-timeout" verwenden: bei RTMP bedeutet das
#                            "auf eingehende Verbindungen warten" und macht
#                            ffplay zum Server.
#  -fflags +nobuffer         geringe Latenz. Das "+" ist wichtig: "-nobuffer"
#                            schaltet das Flag AUS.
#  -flags low_delay          dito, fuer den Decoder
#  -framedrop                lieber Bilder verwerfen als hinterherzuhinken
#  -analyzeduration 1        minimale Stream-Analyse beim Start (Startzeit)
#
# Optionale Zusatz-Optionen ueber STREAM_OPTS in stream.env, z.B. fuer RTSP:
#   STREAM_OPTS="-rtsp_transport tcp"
# Nicht fest eingebaut, weil ffplay bei unbekannten Optionen abbricht
# ("Option rtsp_transport not found") - bei einer RTMP-URL waere die Anzeige
# sonst sofort tot.

set -euo pipefail

: "${STREAM_URL:?STREAM_URL ist nicht gesetzt (siehe /etc/camdisplay/stream.env)}"

FFPLAY_BIN="${CAMDISPLAY_FFPLAY:-/usr/bin/ffplay}"

# Maskiert Zugangsdaten in ffplay-Meldungen:
#  1. die exakte STREAM_URL (woertlich, unabhaengig von Sonderzeichen)
#  2. Fallback per Muster: "://benutzer:passwort@" und passwort-artige
#     Query-Parameter (z.B. "&password=...")
redact() {
  local line
  while IFS= read -r line || [ -n "$line" ]; do
    printf '%s\n' "${line//"$STREAM_URL"/"<stream-url>"}"
  done | sed -u -E \
    -e 's#(://)[^/@[:space:]]*@#\1***@#g' \
    -e "s#((pass(word|wd)?|pwd|token|secret|key)=)[^&[:space:]\"']*#\1***#Ig"
}

# Zusatz-Optionen an Leerzeichen trennen (leer -> leeres Array)
read -r -a extra_opts <<< "${STREAM_OPTS:-}"

# Bewusst KEIN "exec ffplay ... 2> >(redact)": Die Prozess-Substitution laeuft
# asynchron weiter, und systemd beendet beim Stoppen der Unit alle Prozesse der
# Control-Group - der Filter koennte abgeschossen werden, bevor er die Pipe
# leer gelesen hat. Dann ginge genau die letzte (meist wichtigste)
# Fehlermeldung verloren. Mit einer normalen Pipeline wartet dieses Skript, bis
# der Filter fertig ist, und gibt den Exit-Code von ffplay weiter.
# (stdout von ffplay ist ungenutzt und geht nach /dev/null.)
rc=0
"$FFPLAY_BIN" \
  -autoexit \
  -rw_timeout 5000000 \
  -fs \
  -analyzeduration 1 \
  -fflags +nobuffer \
  -flags low_delay \
  -framedrop \
  -an -nostats -loglevel error \
  "${extra_opts[@]}" \
  "$STREAM_URL" \
  2>&1 >/dev/null | redact >&2 || rc=${PIPESTATUS[0]}
exit "$rc"
