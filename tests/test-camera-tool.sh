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
