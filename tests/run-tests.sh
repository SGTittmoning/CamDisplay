#!/bin/bash
# Regressionstests fuer die Skripte unter ansible/files/ (Spiegel: systemd/).
#
# Braucht weder root noch Hardware: alle Systembefehle (raspi-config, mount,
# reboot, systemctl, systemd-run, logger, ...) werden durch Stubs ersetzt, die
# ihre Aufrufe protokollieren. Netzwerk (TCP-Erreichbarkeit) laeuft echt gegen
# einen lokalen Listener. Abhaengigkeiten: bash, coreutils, sed, awk, python3.
#
# Aufruf:  tests/run-tests.sh
#
# Was NICHT getestet wird (nur auf einem Pi mit echtem systemd/ffplay
# pruefbar): der OnFailure-Ablauf, transiente systemd-Timer, das Verhalten von
# ffplay gegen eine echte Kamera.

set -u

ROOT=$(cd "$(dirname "$0")/.." && pwd)
FILES="$ROOT/ansible/files"
WORK=$(mktemp -d)
LISTENER_PID=""
cleanup() { [ -n "$LISTENER_PID" ] && kill "$LISTENER_PID" 2>/dev/null; rm -rf "$WORK"; }
trap cleanup EXIT

pass=0; fail=0; skipped=0
ok()   { pass=$((pass + 1)); printf '  ok    %s\n' "$1"; }
bad()  { fail=$((fail + 1)); printf '  FEHLER %s\n         %s\n' "$1" "${2:-}"; }
skip() { skipped=$((skipped + 1)); printf '  skip  %s (%s)\n' "$1" "$2"; }
check() { # name erwartet tatsaechlich
  if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "erwartet '$2', erhalten '$3'"; fi
}
is_root() { [ "$(id -u)" -eq 0 ]; }

# ---------------------------------------------------------------- Stubs
STUBS="$WORK/stubs"; mkdir -p "$STUBS"
for c in logger reboot systemctl systemd-run; do
  printf '#!/bin/bash\necho "%s $*" >> "$STUB_LOG"\n' "$c" > "$STUBS/$c"
done
printf '#!/bin/bash\necho 0\n' > "$STUBS/id"
cat > "$STUBS/journalctl" <<'EOF'
#!/bin/bash
echo "journalctl $*" >> "$STUB_LOG"
[ "${FAIL_JOURNAL:-0}" = 1 ] && exit 1
pad=""; [ "${STUB_LONG:-0}" -gt 0 ] && pad=$(printf 'x%.0s' $(seq 1 "$STUB_LONG"))
for i in 1 2 3; do echo "[  $i.000] camdisplay: stub-journal-line-$i $pad"; done
EOF
cat > "$STUBS/apt-get" <<'EOF'
#!/bin/bash
echo "apt-get $*" >> "$STUB_LOG"
exit "${FAIL_APT:-0}"
EOF
cat > "$STUBS/systemd-run" <<'EOF'
#!/bin/bash
echo "systemd-run $*" >> "$STUB_LOG"
exit "${STUB_SYSTEMD_RUN_RC:-0}"
EOF
cat > "$STUBS/systemctl" <<'EOF'
#!/bin/bash
echo "systemctl $*" >> "$STUB_LOG"
case "$1" in
  is-active) exit "${STUB_INACTIVE:-0}" ;;
  show)      echo "${STUB_ENTER:-0}" ;;
esac
exit 0
EOF
cat > "$STUBS/raspi-config" <<'EOF'
#!/bin/bash
[ "${FAIL_RASPI:-0}" = 1 ] && exit 127
case "$2" in
  get_bootro_now)  echo "${BOOTRO:-1}" ;;
  get_overlay_now) echo "${OVERLAY:-1}" ;;
  *) echo "raspi-config $2" >> "$STUB_LOG" ;;
esac
exit 0
EOF
cat > "$STUBS/mount" <<'EOF'
#!/bin/bash
echo "mount $*" >> "$STUB_LOG"
case "$*" in
  *remount,rw*) [ "${FAIL_MOUNT_RW:-0}" = 1 ] && exit 32 ;;
  *remount,ro*) [ "${FAIL_MOUNT_RO:-0}" = 1 ] && exit 32 ;;
esac
exit 0
EOF
chmod +x "$STUBS"/*

# TCP-Listener ("Kamera erreichbar") und ein garantiert geschlossener Port
python3 - "$WORK" <<'EOF' &
import socket, sys
srv = socket.socket(); srv.bind(("127.0.0.1", 0)); srv.listen(50)
dead = socket.socket(); dead.bind(("127.0.0.1", 0))      # nur Port reservieren ...
open(sys.argv[1] + "/ports", "w").write("%d %d\n" % (srv.getsockname()[1], dead.getsockname()[1]))
dead.close()                                             # ... und wieder freigeben: geschlossen
while True:
    c, _ = srv.accept(); c.close()
EOF
LISTENER_PID=$!
for _ in $(seq 1 50); do [ -s "$WORK/ports" ] && break; sleep 0.1; done
read -r LIVE_PORT DEAD_PORT < "$WORK/ports"
LIVE="rtmp://user:pw@127.0.0.1:$LIVE_PORT/x"
DEAD="rtmp://user:pw@127.0.0.1:$DEAD_PORT/x"

# ------------------------------------------------- Umgebung pro Testlauf
new_env() { # setzt ein frisches Boot-/Run-Verzeichnis und leert das Stub-Log
  rm -rf "${WORK:?}/boot" "${WORK:?}/run"; mkdir -p "$WORK/boot" "$WORK/run"; : > "$WORK/stub.log"
}
export STUB_LOG="$WORK/stub.log"
called() { grep -qE "^$1" "$STUB_LOG" && echo ja || echo nein; }
logged() { grep '^logger' "$STUB_LOG" | tail -1; }

guard() { # url  (Zustand bleibt erhalten; new_env vorher aufrufen)
  printf 'STREAM_URL="%s"\n' "$1" > "$WORK/stream.env"
  PATH="$STUBS:$PATH" CAMDISPLAY_BOOT_DIR="$WORK/boot" CAMDISPLAY_RUN_DIR="$WORK/run" \
    CAMDISPLAY_STREAM_ENV="$WORK/stream.env" bash "$FILES/camdisplay-reboot-guard.sh" >/dev/null 2>&1
  G_RC=$?
}
count() { cat "$WORK/boot/.camdisplay-reboot-count" 2>/dev/null || echo -; }

echo "== Reboot-Guard =="
new_env; BOOTRO=1 guard "$LIVE"
check "beschreibbare Boot-Partition + Kamera erreichbar: Reboot (set -e darf nicht abbrechen)" "0/ja/1" "$G_RC/$(called reboot)/$(count)"

new_env; BOOTRO=0 guard "$LIVE"
check "read-only Boot-Partition: remount rw+ro, dann Reboot" "ja/ja/ja" \
  "$(grep -q 'remount,rw' "$STUB_LOG" && echo ja || echo nein)/$(grep -q 'remount,ro' "$STUB_LOG" && echo ja || echo nein)/$(called reboot)"

new_env; BOOTRO=1 guard "$DEAD"; a1="$(called reboot)/$(called systemd-run)/$(count)"
BOOTRO=1 guard "$DEAD"; a2="$(called reboot)"
: > "$STUB_LOG"; BOOTRO=1 guard "$DEAD"
check "Kamera weg: Versuch 1 nur Retry, Versuch 2 nur Retry, Versuch 3 Reboot" "nein/ja/-|nein|ja/1" "$a1|$a2|$(called reboot)/$(count)"

new_env; echo 5 > "$WORK/boot/.camdisplay-reboot-count"; BOOTRO=1 guard "$LIVE"
check "Limit (5) erreicht: kein Reboot, langsamer Retry, Zaehler bleibt" "nein/ja/5" "$(called reboot)/$(called systemd-run)/$(count)"

new_env; BOOTRO=1 guard "$DEAD"; BOOTRO=1 guard "$DEAD"; BOOTRO=1 guard "$LIVE"
check "Kamera kommt zurueck: Unreachable-Zaehler verworfen" "-" "$(cat "$WORK/run/camdisplay-unreachable-count" 2>/dev/null || echo -)"

for pair in "abc:1" ":1" "03:4"; do
  new_env; printf '%s' "${pair%%:*}" > "$WORK/boot/.camdisplay-reboot-count"; BOOTRO=1 guard "$LIVE"
  check "beschaedigter Zaehler '${pair%%:*}' -> Reboot mit Zaehler ${pair##*:}" "ja/${pair##*:}" "$(called reboot)/$(count)"
done

new_env; BOOTRO=0 FAIL_MOUNT_RW=1 guard "$LIVE"
check "echter Fehler (remount rw scheitert): Abbruch, KEIN Reboot" "nein/nonzero" "$(called reboot)/$([ "$G_RC" -ne 0 ] && echo nonzero || echo zero)"

new_env; BOOTRO=0 FAIL_MOUNT_RO=1 guard "$LIVE"
check "echter Fehler (remount ro scheitert): Abbruch, KEIN Reboot" "nein/nonzero" "$(called reboot)/$([ "$G_RC" -ne 0 ] && echo nonzero || echo zero)"

if is_root; then skip "Zaehler nicht schreibbar -> KEIN Reboot" "als root nicht pruefbar"
else
  new_env; chmod 555 "$WORK/boot"; BOOTRO=1 guard "$LIVE"; chmod 755 "$WORK/boot"
  check "echter Fehler (Zaehler nicht schreibbar): Abbruch, KEIN Reboot" "nein/nonzero" "$(called reboot)/$([ "$G_RC" -ne 0 ] && echo nonzero || echo zero)"
  new_env; chmod 555 "$WORK/boot"; BOOTRO=0 guard "$LIVE"; chmod 755 "$WORK/boot"
  check "Zaehler nicht schreibbar bei read-only Boot: Partition wird wieder read-only gesetzt, KEIN Reboot" "ja/nein/nonzero" \
    "$(grep -q 'remount,ro' "$STUB_LOG" && echo ja || echo nein)/$(called reboot)/$([ "$G_RC" -ne 0 ] && echo nonzero || echo zero)"
  new_env; chmod 555 "$WORK/run"; BOOTRO=1 guard "$DEAD"; chmod 755 "$WORK/run"
  check "/run nicht schreibbar: Retry wird trotzdem eingeplant" "0/ja/nein" "$G_RC/$(called systemd-run)/$(called reboot)"
fi

new_env; BOOTRO=1 guard "udp://239.0.0.1:1234"
check "nicht auswertbare URL (udp): keine Kamera-Pruefung, Reboot-Pfad" "ja" "$(called reboot)"

new_env; BOOTRO=1 STUB_SYSTEMD_RUN_RC=1 guard "$DEAD"
check "systemd-run scheitert: Hinweis im Log, Exit 0" "0/ja" "$G_RC/$(grep -q 'Konnte den erneuten' "$STUB_LOG" && echo ja || echo nein)"

for spec in \
  "rtmp://admin:p@ss:w0rd@127.0.0.1:$DEAD_PORT/bcs/x.bcs?user=a&password=b:c@d|127.0.0.1:$DEAD_PORT" \
  "rtsp://127.0.0.1/stream|127.0.0.1:554" \
  "rtmp://127.0.0.1/live|127.0.0.1:1935" \
  "rtmp://[::1]:$DEAD_PORT/x|::1:$DEAD_PORT"; do
  # Default-Port 1935 ist fest: lauscht dort gerade etwas (z.B. ein lokaler RTMP-Teststream),
  # ist das Ziel erreichbar und der Fall nicht pruefbar.
  if [ "${spec##*|}" = "127.0.0.1:1935" ] && (exec 3<>/dev/tcp/127.0.0.1/1935) 2>/dev/null; then
    skip "URL-Auswertung: Ziel 127.0.0.1:1935" "Port 1935 ist auf diesem Rechner belegt"; continue
  fi
  new_env; BOOTRO=1 guard "${spec%%|*}"
  check "URL-Auswertung: Ziel ${spec##*|}" "ja" "$(grep -q "Kamera ${spec##*|} nicht erreichbar" "$STUB_LOG" && echo ja || echo nein)"
done

echo "== Reboot-Guard: Log vor dem Reboot sichern =="
LOGF="$WORK/boot/camdisplay-failure-log.txt"
new_env; BOOTRO=1 guard "rtmp://u:Fake_TopSecret9@127.0.0.1:$LIVE_PORT/x?password=Fake_TopSecret9"
check "Reboot: Log mit Kopfzeile (Nummer, Grund) und Journalzeilen" "ja/ja/ja" \
  "$(grep -q '^=== Reboot 1 von 5 | Uptime [0-9?]* s |' "$LOGF" && echo ja || echo nein)/$(grep -q 'stub-journal-line-3' "$LOGF" && echo ja || echo nein)/$(grep -q -- '-u camdisplay.service' "$STUB_LOG" && echo ja || echo nein)"
check "Log enthaelt keine Zugangsdaten" "nein" "$(grep -q 'Fake_TopSecret9' "$LOGF" && echo ja || echo nein)"
new_env; BOOTRO=0 guard "$LIVE"
check "Boot read-only: Log liegt im selben Schreibfenster wie der Zaehler (genau 1x rw, 1x ro)" "1/1/ja" \
  "$(grep -c 'remount,rw' "$STUB_LOG")/$(grep -c 'remount,ro' "$STUB_LOG")/$([ -f "$LOGF" ] && echo ja || echo nein)"
new_env; BOOTRO=1 guard "$LIVE"; BOOTRO=1 guard "$LIVE"
check "zweiter Reboot haengt an (beide Eintraege vorhanden)" "ja/ja" "$(grep -q '^=== Reboot 1 von' "$LOGF" && echo ja || echo nein)/$(grep -q '^=== Reboot 2 von' "$LOGF" && echo ja || echo nein)"
new_env; for _ in 1 2 3 4; do CAMDISPLAY_LOG_MAX_BYTES=300 BOOTRO=1 guard "$LIVE"; done
check "Datei bleibt unter der Obergrenze, neuester Eintrag bleibt erhalten" "ja/ja" \
  "$([ "$(wc -c < "$LOGF")" -le 300 ] && echo ja || echo nein)/$(grep -q 'Reboot 4 von' "$LOGF" && echo ja || echo nein)"
new_env; STUB_LONG=400 BOOTRO=1 guard "$LIVE"
check "sehr lange Journalzeilen werden auf 300 Zeichen gekuerzt" "300" "$(awk '{ if (length($0) > m) m = length($0) } END { print m }' "$LOGF")"
new_env; FAIL_JOURNAL=1 BOOTRO=1 guard "$LIVE"
check "journalctl scheitert: Reboot trotzdem, Hinweis im Log" "0/ja/1/ja" "$G_RC/$(called reboot)/$(count)/$(grep -q 'journalctl nicht verfuegbar' "$LOGF" && echo ja || echo nein)"
new_env; mkdir "$WORK/boot/.camdisplay-failure-log.tmp"; BOOTRO=1 guard "$LIVE"
check "Log kann nicht geschrieben werden: Reboot und Zaehler trotzdem" "0/ja/1/nein" "$G_RC/$(called reboot)/$(count)/$([ -f "$LOGF" ] && echo ja || echo nein)"
new_env; BOOTRO=1 guard "$DEAD"
check "kein Reboot (nur Retry): keine Log-Datei" "nein" "$([ -f "$LOGF" ] && echo ja || echo nein)"
new_env; echo 5 > "$WORK/boot/.camdisplay-reboot-count"; BOOTRO=1 guard "$LIVE"
check "Limit erreicht (kein Reboot): keine Log-Datei" "nein" "$([ -f "$LOGF" ] && echo ja || echo nein)"

echo "== Reboot-Zaehler zuruecksetzen =="
reset() { # HAVE_COUNT HAVE_UNREACH ; Umgebung: STUB_ENTER STUB_INACTIVE BOOTRO
  new_env; [ "$1" = 1 ] && echo 3 > "$WORK/boot/.camdisplay-reboot-count"; [ "$2" = 1 ] && echo 2 > "$WORK/run/camdisplay-unreachable-count"
  echo "1000.50 2000.00" > "$WORK/uptime"
  PATH="$STUBS:$PATH" CAMDISPLAY_BOOT_DIR="$WORK/boot" CAMDISPLAY_RUN_DIR="$WORK/run" CAMDISPLAY_UPTIME_FILE="$WORK/uptime" \
    bash "$FILES/camdisplay-reboot-count-reset.sh" >/dev/null 2>&1; R_RC=$?
  R_STATE="$([ -f "$WORK/boot/.camdisplay-reboot-count" ] && echo da || echo weg)/$([ -f "$WORK/run/camdisplay-unreachable-count" ] && echo da || echo weg)"
}
if ! is_root; then
  new_env; echo 3 > "$WORK/boot/.camdisplay-reboot-count"; chmod 555 "$WORK/boot"
  PATH="$STUBS:$PATH" CAMDISPLAY_BOOT_DIR="$WORK/boot" CAMDISPLAY_RUN_DIR="$WORK/run" CAMDISPLAY_UPTIME_FILE="$WORK/uptime" STUB_ENTER=600000000 BOOTRO=0 \
    bash -c 'echo "1000.50 2000.00" > "$CAMDISPLAY_UPTIME_FILE"; bash "$0"' "$FILES/camdisplay-reboot-count-reset.sh" >/dev/null 2>&1; R_RC=$?
  chmod 755 "$WORK/boot"
  check "Zaehler nicht loeschbar bei read-only Boot: Partition wird wieder read-only gesetzt, Exit 1" "ja/nonzero" \
    "$(grep -q 'remount,ro' "$STUB_LOG" && echo ja || echo nein)/$([ "$R_RC" -ne 0 ] && echo nonzero || echo zero)"
fi
STUB_ENTER=600000000 BOOTRO=1 reset 1 1; check "stabil (400 s), Boot beschreibbar: beide Zaehler weg, Exit 0 (oneshot nicht 'failed')" "0/weg/weg" "$R_RC/$R_STATE"
STUB_ENTER=600000000 BOOTRO=0 reset 1 1; check "stabil, Boot read-only: beide weg, Exit 0" "0/weg/weg" "$R_RC/$R_STATE"
STUB_ENTER=700500000 BOOTRO=1 reset 1 1; check "genau 300 s stabil: zuruecksetzen" "0/weg/weg" "$R_RC/$R_STATE"
STUB_ENTER=701500000 BOOTRO=1 reset 1 1; check "299 s: Zaehler bleiben" "0/da/da" "$R_RC/$R_STATE"
STUB_INACTIVE=3 STUB_ENTER=600000000 BOOTRO=1 reset 1 1; check "Dienst inaktiv: Zaehler bleiben" "0/da/da" "$R_RC/$R_STATE"
STUB_ENTER=0 BOOTRO=1 reset 1 1; check "ActiveEnterTimestampMonotonic=0: Zaehler bleiben" "0/da/da" "$R_RC/$R_STATE"

echo "== Wartungsskripte update/writable (Boot-Pfad umgebogen) =="
for n in update writable; do
  sed "s#BOOT_DIR=\"/boot/firmware\"#BOOT_DIR=\"$WORK/boot\"#" "$FILES/camdisplay-$n.sh" > "$WORK/$n.sh"
done
maint() { # script args...   (Umgebung: OVERLAY BOOTRO FAIL_MOUNT_RW ; PRE_STATE)
  local s=$1; shift
  PATH="$STUBS:$PATH" bash "$WORK/$s.sh" "$@" > "$WORK/out.txt" 2>&1; M_RC=$?
}
new_env; OVERLAY=1 BOOTRO=1 maint update begin
check "update begin, Boot beschreibbar: Exit 0, State geschrieben, Hinweis vorhanden" "0/awaiting-apply-no-reboot/ja" \
  "$M_RC/$(cat "$WORK/boot/.camdisplay-update.state" 2>/dev/null)/$(grep -q 'Weiter mit' "$WORK/out.txt" && echo ja || echo nein)"
OVERLAY=1 BOOTRO=1 maint update apply
check "update apply danach: Exit 0, State aufgeraeumt" "0/weg" "$M_RC/$([ -f "$WORK/boot/.camdisplay-update.state" ] && echo da || echo weg)"
new_env; OVERLAY=1 BOOTRO=0 FAIL_MOUNT_RW=1 maint update begin
check "update begin, remount rw scheitert: Abbruch, kein Reboot-Hinweis" "nonzero/nein" \
  "$([ "$M_RC" -ne 0 ] && echo nonzero || echo zero)/$(grep -q 'rebooten' "$WORK/out.txt" && echo ja || echo nein)"
new_env; echo x > "$WORK/boot/.camdisplay-writable.state"; OVERLAY=1 BOOTRO=1 maint writable rw
check "writable rw, Boot beschreibbar: Exit 0, Abschlussmeldung vorhanden" "0/ja" "$M_RC/$(grep -q 'vollstaendig beschreibbar' "$WORK/out.txt" && echo ja || echo nein)"
new_env; echo x > "$WORK/boot/.camdisplay-writable.state"; OVERLAY=1 BOOTRO=0 FAIL_MOUNT_RW=1 maint writable rw
check "writable rw, remount rw scheitert: Abbruch" "nonzero" "$([ "$M_RC" -ne 0 ] && echo nonzero || echo zero)"

# apply bricht ab (z.B. apt ohne Netz): der geschuetzte Zustand muss wiederhergestellt werden
apply_case() { # BOOTRO-Ausgangszustand ; Umgebung: FAIL_APT
  new_env; echo awaiting-apply-no-reboot > "$WORK/boot/.camdisplay-update.state"; OVERLAY=1 BOOTRO=$1 maint update apply
  A_ENABLED="$(grep -o 'raspi-config enable_[a-z]*' "$STUB_LOG" | sed 's/raspi-config //' | paste -sd,)"
  A_STATE="$([ -f "$WORK/boot/.camdisplay-update.state" ] && echo da || echo weg)"
  A_MSG="$(grep -q 'Update-Lauf ist abgebrochen' "$WORK/out.txt" && echo ja || echo nein)"
}
FAIL_APT=100 apply_case 0
check "update apply, apt scheitert (Boot-RO war aktiv): Abbruch, Boot-RO + Overlay wiederhergestellt, Zyklus beendet, laute Meldung" \
  "nonzero/enable_bootro,enable_overlayfs/weg/ja" "$([ "$M_RC" -ne 0 ] && echo nonzero || echo zero)/$A_ENABLED/$A_STATE/$A_MSG"
FAIL_APT=100 apply_case 1
check "update apply, apt scheitert (Boot-RO war inaktiv): nur Overlay wiederhergestellt" "nonzero/enable_overlayfs/weg/ja" \
  "$([ "$M_RC" -ne 0 ] && echo nonzero || echo zero)/$A_ENABLED/$A_STATE/$A_MSG"
apply_case 0
check "update apply erfolgreich: Schutz genau einmal wieder ein, keine Fehlermeldung" "0/enable_bootro,enable_overlayfs/weg/nein" "$M_RC/$A_ENABLED/$A_STATE/$A_MSG"
new_env; OVERLAY=1 BOOTRO=0 maint update apply
check "update apply ohne laufenden Zyklus: Ablehnung OHNE Wiederherstellungs-Aktion" "nonzero/-/nein" \
  "$([ "$M_RC" -ne 0 ] && echo nonzero || echo zero)/$(grep -o 'raspi-config enable_[a-z]*' "$STUB_LOG" | paste -sd, | sed 's/^$/-/')/$(grep -q 'abgebrochen' "$WORK/out.txt" && echo ja || echo nein)"

echo "== Start-Wrapper camdisplay-run =="
cat > "$WORK/fake_ffplay" <<'EOF'
#!/bin/bash
{ printf 'ARGV:'; printf ' [%s]' "$@"; printf '\n'; } > "$ARGV_FILE"   # Datei: ffplays stdout geht im Wrapper nach /dev/null
echo "${!#}: Connection refused" >&2
echo "401 for http://camuser:Geh3im@camera.local/live?x=1" >&2
echo "retry &password=Sup3rSecret&other=1 Token=abc123 apikey=K3Y" >&2
echo "harmlos: user=admin channel=0" >&2
exit 7
EOF
chmod +x "$WORK/fake_ffplay"
wrap() { # url [opts] -> Ausgabe in $out, Exit-Code in $W_RC (ohne Subshell)
  ARGV_FILE="$WORK/argv.txt" STREAM_URL="$1" STREAM_OPTS="${2:-}" CAMDISPLAY_FFPLAY="$WORK/fake_ffplay" bash "$FILES/camdisplay-run.sh" > "$WORK/wrap.out" 2>&1
  W_RC=$?; out=$(cat "$WORK/wrap.out")
}
wrap 'rtmp://192.0.2.10:1935/bcs/x.bcs?channel=0&user=admin&password=Fake_TopSecret9' ""
check "Wrapper: Exit-Code von ffplay wird durchgereicht" "7" "$W_RC"
check "Wrapper: Passwort erscheint nirgends in der Ausgabe" "nein" "$(echo "$out" | grep -qE 'TopSecret9|Geh3im|Sup3rSecret|abc123|K3Y' && echo ja || echo nein)"
check "Wrapper: harmlose Zeilen bleiben erhalten" "ja" "$(echo "$out" | grep -q 'harmlos: user=admin channel=0' && echo ja || echo nein)"
check "Wrapper: -autoexit, -rw_timeout, low_delay, framedrop gesetzt" "ja" "$(grep ARGV "$WORK/argv.txt" | grep -q '\[-autoexit\].*\[-rw_timeout\] \[5000000\].*\[-flags\] \[low_delay\].*\[-framedrop\]' && echo ja || echo nein)"
check "Wrapper: KEIN fflags nobuffer (stoppt bei RTMP jede Bildausgabe)" "nein" "$(grep -qi 'nobuffer' "$WORK/argv.txt" && echo ja || echo nein)"
check "Wrapper: kein -timeout, kein -rtsp_transport ohne STREAM_OPTS" "nein" "$(grep ARGV "$WORK/argv.txt" | grep -qE '\[-timeout\]|rtsp_transport' && echo ja || echo nein)"
check "Wrapper: leere STREAM_OPTS erzeugen kein leeres Argument" "nein" "$(grep ARGV "$WORK/argv.txt" | grep -q '\[\]' && echo ja || echo nein)"
wrap 'rtsp://cam:p*a?s[s]|w$d@192.0.2.10:554/s' "-rtsp_transport tcp"
check "Wrapper: STREAM_OPTS werden getrennt vor der URL uebergeben, Sonderzeichen bleiben" "ja" \
  "$(grep ARGV "$WORK/argv.txt" | grep -qF '[-rtsp_transport] [tcp] [rtsp://cam:p*a?s[s]|w$d@192.0.2.10:554/s]' && echo ja || echo nein)"
out=$(env -u STREAM_URL CAMDISPLAY_FFPLAY="$WORK/fake_ffplay" bash "$FILES/camdisplay-run.sh" 2>&1); W_RC=$?
check "Wrapper: fehlende STREAM_URL wird abgelehnt" "nonzero" "$([ "$W_RC" -ne 0 ] && echo nonzero || echo zero)"

echo "== Statische Pruefung: set -e-Falle ([ cond ] && cmd als letzte Anweisung) =="
scan() { python3 "$ROOT/tests/trap-scan.py" "$@" > "$WORK/scan.out" 2>&1; echo $?; }
cat > "$WORK/fx_trap_fn.sh" <<'EOF'
f() {
  local x=0
  [ -n "$1" ] && x=1
  [ "$x" -eq 1 ] && echo hit
}
EOF
cat > "$WORK/fx_trap_end.sh" <<'EOF'
echo start
[ -f /nonexistent ] && rm /nonexistent
EOF
cat > "$WORK/fx_safe.sh" <<'EOF'
f() {
  [ -n "$1" ] && echo hit
  return 0
}
g() { [ -n "$1" ] && echo hit || true; }
k() { grep -q x "$1" && echo ja || echo nein; }
h() { true; }
[ -f /nonexistent ] && echo x
exit 0
EOF
check "Scanner erkennt die Falle am Funktionsende (Selbsttest)" "1" "$(scan "$WORK/fx_trap_fn.sh")"
check "Scanner erkennt die Falle am Skriptende (Selbsttest)" "1" "$(scan "$WORK/fx_trap_end.sh")"
check "Scanner meldet abgesicherte Faelle nicht (Selbsttest)" "0" "$(scan "$WORK/fx_safe.sh")"
rc=$(scan "$FILES"/*.sh "$ROOT"/systemd/*.sh)
check "kein Skript im Repo endet auf die Falle (Details: tests/trap-scan.py)" "0" "$rc"
[ "$rc" -ne 0 ] && sed 's/^/         /' "$WORK/scan.out"

echo "== Kamera-Werkzeug =="
wrapper_flags=$(sed -n '/^"\$FFPLAY_BIN"/,/extra_opts/p' "$FILES/camdisplay-run.sh" | grep -vE 'FFPLAY_BIN|extra_opts' | sed 's/\\$//' | tr -s ' \n' ' ' | sed 's/^ //; s/ $//')
tool_flags=$(sed -n 's/^FFPLAY_FLAGS="\(.*\)"$/\1/p' "$ROOT/tools/check-camera.sh")
check "tools/check-camera.sh testet mit denselben ffplay-Flags wie camdisplay-run" "$wrapper_flags" "$tool_flags"
check "die Flags wurden ueberhaupt gefunden (nicht leer)" "ja" "$([ -n "$wrapper_flags" ] && echo ja || echo nein)"

echo "== Beispieldateien systemd/ (werden aus ansible/ erzeugt) =="
"$ROOT/tools/sync-systemd-examples.sh" "$WORK/generated" > /dev/null
for f in "$WORK"/generated/*; do
  b=$(basename "$f")
  check "systemd/$b entspricht dem erzeugten Stand (sonst: tools/sync-systemd-examples.sh)" "gleich" \
    "$(cmp -s "$f" "$ROOT/systemd/$b" && echo gleich || echo ABWEICHUNG)"
done
check "in den erzeugten Units bleibt keine Jinja-Variable uebrig" "0" "$(grep -l '{{' "$WORK"/generated/*.service "$WORK"/generated/*.timer 2>/dev/null | wc -l | tr -d ' ')"
extra=""
for f in "$ROOT"/systemd/*; do [ -e "$WORK/generated/$(basename "$f")" ] || extra="$extra $(basename "$f")"; done
check "systemd/ enthaelt nur erzeugte Dateien" "" "${extra# }"

echo
echo "Ergebnis: $pass ok, $fail Fehler, $skipped uebersprungen"
[ "$fail" -eq 0 ]
