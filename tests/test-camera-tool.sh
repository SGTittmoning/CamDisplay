#!/bin/bash
# Testet tools/check-camera.sh gegen einen lokalen RTMP-Teststream (ffmpeg,
# synthetisches Testbild in der Aufloesung der echten Kamera). Braucht ffmpeg,
# ffprobe, ffplay und perl; ohne diese wird uebersprungen. Bewusst NICHT Teil der
# CI (ffmpeg muesste dort installiert werden) - lokal ausfuehren.
#
# Aufruf: tests/test-camera-tool.sh

set -u

ROOT=$(cd "$(dirname "$0")/.." && pwd)
TOOL="$ROOT/tools/check-camera.sh"
WORK=$(mktemp -d)
LOOP_PID=""
cleanup() {
  if [ -n "$LOOP_PID" ]; then
    for c in $(pgrep -P "$LOOP_PID" 2>/dev/null); do kill "$c" 2>/dev/null; done
    kill "$LOOP_PID" 2>/dev/null
  fi
  rm -rf "$WORK"
}
trap cleanup EXIT

pass=0; fail=0
ok()  { pass=$((pass + 1)); printf '  ok    %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf '  FEHLER %s\n         %s\n' "$1" "${2:-}"; }
check() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "erwartet '$2', erhalten '$3'"; fi; }
has() { grep -qE "$1" "$WORK/out.txt" && echo ja || echo nein; }

for t in ffmpeg ffprobe ffplay perl python3; do
  command -v "$t" >/dev/null 2>&1 || { echo "$t fehlt - Test uebersprungen"; exit 0; }
done

read -r PORT DEAD < <(python3 - <<'EOF'
import socket
a = socket.socket(); a.bind(("127.0.0.1", 0)); b = socket.socket(); b.bind(("127.0.0.1", 0))
print(a.getsockname()[1], b.getsockname()[1]); a.close(); b.close()
EOF
)

# Teststream in der Aufloesung/Bildrate der echten Kamera; "-listen 1" nimmt nur EINE
# Verbindung an, deshalb in einer Schleife.
cat > "$WORK/server.sh" <<EOF
#!/bin/bash
while true; do
  ffmpeg -nostdin -loglevel error -re -f lavfi -i "testsrc=size=896x672:rate=16" -t 120 \\
    -c:v libx264 -preset ultrafast -tune zerolatency -pix_fmt yuv420p -f flv -listen 1 "rtmp://127.0.0.1:$PORT/live/test"
done
EOF
chmod +x "$WORK/server.sh"
"$WORK/server.sh" >/dev/null 2>&1 &
LOOP_PID=$!
sleep 2

SECRET_A="Zq9CamSecret"; SECRET_B="Qw7CamQuery"
run() { STREAM_URL="$1" SDL_VIDEODRIVER=dummy bash "$TOOL" --seconds 5 > "$WORK/out.txt" 2>&1; T_RC=$?; }

echo "== Kamera erreichbar, Teststream laeuft =="
run "rtmp://user:$SECRET_A@127.0.0.1:$PORT/live/test"
check "Exit 0 (kein FAIL)" "0" "$T_RC"
[ "$T_RC" -ne 0 ] && sed 's/^/         /' "$WORK/out.txt" | tail -15
check "TCP-Verbindung erkannt" "ja" "$(has 'PASS +TCP-Verbindung zu 127.0.0.1')"
check "Standard-Analyse und schnelle Analyse liefen" "ja/ja" "$(has 'PASS +Standard-Analyse')/$(has 'PASS +Schnelle Analyse')"
check "Stream-Parameter erkannt: H.264, 896x672" "ja" "$(has 'Stream: .*codec_name=h264.*width=896.*height=672')"
check "Videocodec H.264 wird gemeldet" "ja" "$(has 'PASS +Videocodec H.264')"
check "Bilder wurden dekodiert" "ja" "$(has 'PASS +Bilder wurden dekodiert')"
check "ffplay akzeptiert alle Wrapper-Flags" "ja" "$(has 'PASS +ffplay akzeptiert alle Wrapper-Flags')"
check "ffplay rendert Bilder mit den Wrapper-Flags (Zeitposition laeuft)" "ja" "$(has 'PASS +ffplay rendert Bilder')"
check "Experiment -fflags +nobuffer wird ausgewertet und als 'keine Bilder' erkannt" "ja" "$(has 'Experiment -fflags \+nobuffer: es kommen KEINE Bilder an')"
check "nur die geschaetzte r_frame_rate weicht ab (kein Fehlalarm bei der Analyse)" "ja" "$(has 'PASS +Beide Analysen liefern identische')"
check "Zugangsdaten stehen nie in der Ausgabe" "nein" "$(has "$SECRET_A")"
check "RTMP-Hinweis zu -timeout/-rtsp_transport vorhanden" "ja" "$(has "RTMP: '-rtsp_transport' und '-timeout'")"

echo "== Abfrage-Parameter mit Passwort in der URL (Reolink-Schema) =="
run "rtmp://127.0.0.1:$PORT/live/test?channel=0&stream=0&user=admin&password=$SECRET_B"
check "Passwort aus der Query wird maskiert" "nein" "$(has "$SECRET_B")"

echo "== Maskierung (mask-Funktion direkt) =="
maskrun() { # URL Eingabezeile
  bash -c 'source <(sed -n "/^mask() {/,/^}/p" "$1"); URL="$2"; printf "%s\n" "$3" | mask' _ "$TOOL" "$1" "$2"
}
BS='pa\tss\\x'
check "URL mit Backslashes im Passwort wird exakt ersetzt" "x <stream-url> y" "$(maskrun "rtmp://h/p?u=a&password=$BS" "x rtmp://h/p?u=a&password=$BS y")"
check "Password= (Grossbuchstabe) wird maskiert" "x rtmp://h/p?Password=***&z=1 y" "$(maskrun "andere" 'x rtmp://h/p?Password=geheim&z=1 y')"
check "Passwort mit Backslash wird bis zum '&' maskiert" "x rtmp://h/p?password=***&z=1 y" "$(maskrun "andere" "x rtmp://h/p?password=$BS&z=1 y")"
check "TOKEN= und user:pass@ werden maskiert" "x rtmp://***@h/p?TOKEN=*** y" "$(maskrun "andere" 'x rtmp://u:p@h/p?TOKEN=abc y')"
bash "$TOOL" --seconds abc > "$WORK/out.txt" 2>&1; check "--seconds mit Nicht-Zahl: Exit 2" "2" "$?"

echo "== Port offen, aber kein Stream (ffplay endet mit Exit 0 und Fehlermeldung) =="
python3 - "$WORK" <<'EOF' &
import socket, sys
s = socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("127.0.0.1", 0)); s.listen(5)
open(sys.argv[1] + "/junk.port", "w").write(str(s.getsockname()[1]))
s.settimeout(90)
try:
    while True:
        c, _ = s.accept(); c.close()
except Exception:
    pass
EOF
JUNK_PID=$!
for _ in 1 2 3 4 5 6 7 8 9 10; do [ -s "$WORK/junk.port" ] && break; sleep 0.3; done
run "rtmp://user:$SECRET_A@127.0.0.1:$(cat "$WORK/junk.port")/live/test"
check "kein PASS fuer ffplay, sondern FAIL (Exit 1)" "1/nein/ja" "$T_RC/$(has 'PASS +ffplay akzeptiert alle Wrapper-Flags')/$(has 'FAIL +ffplay (meldet Fehler|lehnt|konnte)')"
kill "$JUNK_PID" 2>/dev/null

echo "== Kamera nicht erreichbar =="
run "rtmp://user:$SECRET_A@127.0.0.1:$DEAD/live/test"
check "Exit 1 und klare Meldung" "1/ja" "$T_RC/$(has 'FAIL +TCP-Verbindung zu 127.0.0.1:[0-9]+ nicht moeglich')"
check "auch hier keine Zugangsdaten in der Ausgabe" "nein" "$(has "$SECRET_A")"

echo "== Aufruf =="
bash "$TOOL" --help > "$WORK/out.txt" 2>&1; check "--help: Exit 0" "0/ja" "$?/$(has 'env-file')"
bash "$TOOL" --unbekannt > "$WORK/out.txt" 2>&1; check "unbekannte Option: Exit 2" "2" "$?"
env -u STREAM_URL bash "$TOOL" < /dev/null > "$WORK/out.txt" 2>&1; check "keine URL: Exit 2" "2" "$?"
printf 'STREAM_URL="rtmp://user:%s@127.0.0.1:%s/live/test"\n' "$SECRET_A" "$DEAD" > "$WORK/stream.env"
env -u STREAM_URL bash "$TOOL" --env-file "$WORK/stream.env" > "$WORK/out.txt" 2>&1
check "--env-file wird gelesen (Ziel-Host in der Ausgabe)" "ja" "$(has 'Host 127.0.0.1')"

echo
echo "Ergebnis: $pass ok, $fail Fehler"
[ "$fail" -eq 0 ]
