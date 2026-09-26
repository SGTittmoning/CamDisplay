#!/bin/bash
# Tests fuer tools/verify-install.sh: ein "gesundes" Fake-Geraet (Dateibaum unter
# VERIFY_ROOT plus Attrappen fuer systemctl, journalctl, nft, ...) wird gezielt
# verschlechtert - jede Schwaeche muss als FAIL bzw. WARN erscheinen. Kein root,
# keine Hardware. Abhaengigkeiten: bash, GNU coreutils/stat, python3.
#
# Aufruf: tests/test-verify.sh

set -u

ROOT=$(cd "$(dirname "$0")/.." && pwd)
VERIFY="$ROOT/tools/verify-install.sh"
WORK=$(mktemp -d)
LISTENER_PID=""
trap '[ -n "$LISTENER_PID" ] && kill "$LISTENER_PID" 2>/dev/null; rm -rf "$WORK"' EXIT

pass=0; fail=0
ok()  { pass=$((pass + 1)); printf '  ok    %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf '  FEHLER %s\n         %s\n' "$1" "${2:-}"; }
check() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "erwartet '$2', erhalten '$3'"; fi; }

SECRET_A="Zq9SecretPw"      # Passwort im Userinfo
SECRET_B="Qw7QuerySecret"   # password= in der Query

# ------------------------------------------------------ Kamera-Listener (TCP)
python3 - "$WORK" <<'EOF' &
import socket, sys
s = socket.socket(); s.bind(("127.0.0.1", 0)); s.listen(50)
d = socket.socket(); d.bind(("127.0.0.1", 0))
open(sys.argv[1] + "/ports", "w").write("%d %d\n" % (s.getsockname()[1], d.getsockname()[1]))
d.close()
while True:
    c, _ = s.accept(); c.close()
EOF
LISTENER_PID=$!
for _ in $(seq 1 50); do [ -s "$WORK/ports" ] && break; sleep 0.1; done
read -r LIVE_PORT DEAD_PORT < "$WORK/ports"

# ------------------------------------------------------------- Attrappen
STUBS="$WORK/stubs"; mkdir -p "$STUBS"
mk() { printf '#!/bin/bash\n%s\n' "$2" > "$STUBS/$1"; chmod +x "$STUBS/$1"; }
mk id 'if [ "${1:-}" = "-u" ]; then echo "${STUB_UID:-0}"; exit 0; fi
[ "${SVC_MISSING:-0}" = 1 ] && exit 1
if [ "${1:-}" = "-nG" ]; then echo "${SVC_GROUPS:-camdisplay video render}"; exit 0; fi
exit 0'
mk getent 'echo "camdisplay:x:999:985::/nonexistent:${SVC_SHELL:-/usr/sbin/nologin}"'
mk dpkg-query 'p="${@: -1}"; case " ${MISSING_PKG:-} " in *" $p "*) exit 1;; esac; printf "install ok installed"'
mk systemctl 'a="$*"
case "$a" in
  "is-enabled camdisplay.service") echo "${SVC_ENABLED:-enabled}" ;;
  "is-active camdisplay.service") echo "${SVC_ACTIVE:-active}" ;;
  "show --property=ActiveEnterTimestampMonotonic --value camdisplay.service") echo "${SVC_ENTER:-1000000000}" ;;
  "show --property=NRestarts --value camdisplay.service") echo "${SVC_NRESTARTS:-0}" ;;
  "is-active camdisplay-reboot-count-reset.timer") echo active ;;
  "is-enabled camdisplay-reboot-count-reset.timer") echo enabled ;;
  "show --property=RuntimeWatchdogUSec --value") echo "${WD_VALUE:-10s}" ;;
  "is-enabled avahi-daemon.service") echo "${AVAHI:-masked}" ;;
  "is-enabled bluetooth.service") echo "${BT:-masked}" ;;
  "list-timers camdisplay-slow-retry.timer --no-legend") [ -n "${SLOW_TIMER:-}" ] && echo "Thu 2026-09-27 10:00 camdisplay-slow-retry.timer camdisplay-slow-retry.service" ;;
esac
exit 0'
mk ps '[ "${FFPLAY_NONE:-0}" = 1 ] && exit 1; echo "${FFPLAY_USER:-camdisplay}"'
mk journalctl 'echo "camdisplay: Connection refused"
echo "camdisplay: <stream-url>: Connection refused"
[ "${LEAK:-0}" = 1 ] && echo "camdisplay: failed for user:$LEAK_A@host password=$LEAK_B"
exit 0'
mk raspi-config 'case "$2" in get_overlay_now) echo "${OVERLAY:-0}";; get_bootro_now) echo "${BOOTRO:-0}";; esac'
mk nft '[ "${NO_FW:-0}" = 1 ] && { echo "table inet filter {}"; exit 0; }
printf "table inet filter {\n chain input {\n type filter hook input priority 0; policy drop;\n tcp dport 22 accept\n }\n}\n"'
mk sshd 'printf "permitrootlogin no\nx11forwarding no\npasswordauthentication %s\nkbdinteractiveauthentication no\n" "${SSH_PW:-no}"'
mk vcgencmd 'case "$1" in get_throttled) echo "throttled=${THROTTLED:-0x0}";; measure_temp) echo "temp=${TEMP:-45.0}'"'"'C";; esac'
mk timedatectl 'echo "${NTP:-yes}"'
mk nmcli '[ "${WIFI:-0}" = 1 ] && echo "802-11-wireless"; echo "802-3-ethernet"'
mk hostname 'if [ "${1:-}" = "-I" ]; then echo "192.0.2.10"; else echo camdisplaytest; fi'
mk uname 'echo 6.12.0-test'
mk ffplay 'echo "ffplay version 7.1-test Copyright"'

# ------------------------------------------- gesundes Fake-Geraet bauen
F="$WORK/root"
build() {
  rm -rf "$F"
  mkdir -p "$F"/{proc/device-tree,etc/camdisplay,etc/systemd/system/../system.conf.d,usr/local/bin,root/bin,dev,run,boot/firmware,etc/sudoers.d,sys/class/drm/card1-HDMI-A-1}
  echo "Raspberry Pi 4 Model B Rev 1.4" > "$F/proc/device-tree/model"
  echo 'PRETTY_NAME="Debian GNU/Linux 13 (trixie)"' > "$F/etc/os-release"
  echo "5000.00 4000.00" > "$F/proc/uptime"
  printf 'STREAM_URL="rtmp://user:%s@127.0.0.1:%s/bcs/x.bcs?channel=0&stream=0&password=%s"\n' "$SECRET_A" "$LIVE_PORT" "$SECRET_B" > "$F/etc/camdisplay/stream.env"
  chmod 600 "$F/etc/camdisplay/stream.env"
  echo '#!/bin/bash' > "$F/usr/local/bin/camdisplay-run"; chmod 755 "$F/usr/local/bin/camdisplay-run"
  for s in camdisplay-update.sh camdisplay-writable.sh camdisplay-reboot-guard.sh camdisplay-reboot-count-reset.sh camdisplay-screenshot.sh; do
    echo '#!/bin/bash' > "$F/root/bin/$s"; chmod 700 "$F/root/bin/$s"
  done
  for u in camdisplay-reboot.service camdisplay-reboot-count-reset.service camdisplay-reboot-count-reset.timer; do echo "[Unit]" > "$F/etc/systemd/system/$u"; done
  "$ROOT/tools/sync-systemd-examples.sh" "$WORK/gen" >/dev/null
  cp "$WORK/gen/camdisplay.service" "$F/etc/systemd/system/camdisplay.service"     # die echte, erzeugte Unit
  printf '[Manager]\nRuntimeWatchdogSec=10\n' > "$F/etc/systemd/system.conf.d/10-camdisplay-watchdog.conf"
  : > "$F/dev/watchdog"
  echo connected > "$F/sys/class/drm/card1-HDMI-A-1/status"
  printf '[all]\ndtoverlay=disable-wifi\ndtoverlay=disable-bt\n' > "$F/boot/firmware/config.txt"
}
me=$(id -un); mygrp=$(id -gn)
export VERIFY_ROOT="$F" VERIFY_ASSUME_ROOT=1 VERIFY_OWNER="$me:$mygrp" LEAK_A="$SECRET_A" LEAK_B="$SECRET_B"

run() { # Optionen des Skripts; Umgebung steuert die Attrappen
  PATH="$STUBS:$PATH" bash "$VERIFY" "$@" > "$WORK/out.txt" 2>&1; V_RC=$?
}
line() { grep -E "^\s+$1 +$2" "$WORK/out.txt" | head -n 1; }   # Status + Namensanfang
has()  { [ -n "$(line "$1" "$2")" ] && echo ja || echo nein; }

echo "== gesundes Geraet =="
build; run --expect-hardening --expect-overlay
check "alles gesund: Exit 0, kein FAIL" "0/0" "$V_RC/$(grep -c '^\s*FAIL' "$WORK/out.txt")"
[ "$V_RC" -ne 0 ] && grep -E '^\s+(FAIL|WARN)' "$WORK/out.txt" | sed 's/^/         /'
check "Ergebnis-Zeile vorhanden" "ja" "$(grep -q '^Ergebnis: [0-9]* PASS, 0 FAIL' "$WORK/out.txt" && echo ja || echo nein)"
check "die echte, aus dem Template erzeugte Unit besteht die Pruefung" "ja/ja" "$(has PASS 'Unit laeuft als camdisplay')/$(has PASS 'Unit startet den Wrapper')"
check "Kamera per TCP erreichbar" "ja" "$(has PASS 'Kamera per TCP')"
check "Zugangsdaten (Userinfo + Query) nicht im Journal" "ja" "$(has PASS 'Zugangsdaten nicht im Journal')"
check "Geheimnisse stehen nie in der Ausgabe" "nein" "$(grep -qE "$SECRET_A|$SECRET_B" "$WORK/out.txt" && echo ja || echo nein)"

echo "== gezielte Verschlechterungen =="
mut() { # name  Erwartung(Status:Namensanfang)  Optionen -- Umgebung/Aenderung per Funktion davor
  local expect_status=${2%%:*} expect_name=${2#*:}
  check "$1" "ja/1" "$(has "$expect_status" "$expect_name")/$([ "$V_RC" -ne 0 ] && echo 1 || echo 0)"
}
build; SVC_GROUPS="camdisplay video render sudo" run;          check "Service-User in sudo-Gruppe -> FAIL" "ja" "$(has FAIL 'keine privilegierten Gruppen')"
build; SVC_SHELL=/bin/bash run;                                check "Service-User mit Login-Shell -> FAIL" "ja" "$(has FAIL 'keine Login-Shell')"
build; SVC_MISSING=1 run;                                      check "Service-User fehlt -> FAIL" "ja" "$(has FAIL 'User camdisplay existiert')"
build; echo "camdisplay ALL=(ALL) NOPASSWD: ALL" > "$F/etc/sudoers.d/x"; run
check "sudoers-Eintrag fuer den Service-User -> FAIL" "ja" "$(has FAIL 'keine sudoers-Eintraege')"
build; chmod 644 "$F/etc/camdisplay/stream.env"; run;         check "stream.env fuer alle lesbar (644) -> FAIL" "ja" "$(has FAIL 'stream.env')"
build; rm "$F/usr/local/bin/camdisplay-run"; run;             check "Wrapper fehlt -> FAIL" "ja" "$(has FAIL 'Start-Wrapper')"
build; sed -i 's/^User=.*/User=pi/' "$F/etc/systemd/system/camdisplay.service"; run
check "Unit laeuft als pi -> FAIL" "ja" "$(has FAIL 'Unit laeuft als')"
build; MISSING_PKG="libegl1" run;                              check "libegl1 fehlt -> FAIL" "ja" "$(has FAIL 'Paket libegl1')"
build; SVC_ACTIVE=inactive run;                                check "Dienst laeuft nicht -> FAIL" "ja" "$(has FAIL 'camdisplay.service laeuft')"
build; FFPLAY_USER=pi run;                                     check "ffplay laeuft als falscher User -> FAIL" "ja" "$(has FAIL 'ffplay laeuft als')"
build; FFPLAY_NONE=1 run;                                      check "kein ffplay-Prozess -> FAIL" "ja" "$(has FAIL 'ffplay laeuft')"
build; SVC_ENTER=4990000000 run;                               check "Dienst erst seit wenigen Sekunden -> WARN" "ja" "$(has WARN 'laeuft stabil')"
build; rm "$F/sys/class/drm/card1-HDMI-A-1/status"; run;      check "kein Monitor erkannt -> WARN" "ja" "$(has WARN 'Monitor erkannt')"
build; LEAK=1 run
check "Passwort im Klartext im Journal -> FAIL" "ja" "$(has FAIL 'Zugangsdaten nicht im Journal')"
check "... und auch dann wird das Geheimnis NICHT ausgegeben" "nein" "$(grep -qE "$SECRET_A|$SECRET_B" "$WORK/out.txt" && echo ja || echo nein)"
build; sed -i "s#:$LIVE_PORT/#:$DEAD_PORT/#" "$F/etc/camdisplay/stream.env"; run
check "Kamera nicht erreichbar -> WARN" "ja" "$(has WARN 'Kamera per TCP')"
build; WIFI=1 run;                                             check "gespeichertes WLAN-Profil -> FAIL" "ja" "$(has FAIL 'keine gespeicherten WLAN')"
build; SLOW_TIMER=1 run;                                       check "geplanter Retry-Timer -> WARN" "ja" "$(has WARN 'geplanter Neustartversuch')"
build; WD_VALUE=0 run;                                         check "Watchdog nicht aktiv (0) -> WARN" "ja" "$(has WARN 'Watchdog aktiv')"
build; printf '[Manager]\nRuntimeWatchdogSec=12\n' > "$F/etc/systemd/system.conf.d/10-camdisplay-watchdog.conf"; WD_VALUE=12s run
check "eigener Watchdog-Wert (12 s) im Drop-in und aktiv -> PASS" "ja" "$(has PASS 'Watchdog aktiv')"
build; printf '[Manager]\nRuntimeWatchdogSec=12\n' > "$F/etc/systemd/system.conf.d/10-camdisplay-watchdog.conf"; WD_VALUE=10s run
check "Drop-in sagt 12 s, systemd meldet 10 s -> WARN" "ja" "$(has WARN 'Watchdog aktiv')"
build; rm "$F/dev/watchdog"; run;                              check "kein /dev/watchdog -> FAIL" "ja" "$(has FAIL '/dev/watchdog')"
build; rm "$F/dev/watchdog" "$F/etc/systemd/system.conf.d/10-camdisplay-watchdog.conf"; WD_VALUE=0 run --no-watchdog
check "--no-watchdog: Watchdog bewusst aus, kein FAIL" "0/ja" "$V_RC/$(has INFO 'Watchdog bewusst aus')"
build; THROTTLED=0x50005 run;                                  check "Unterspannung (0x50005) -> WARN mit Klartext" "ja/ja" "$(has WARN 'Stromversorgung')/$(grep -q 'Unterspannung-jetzt' "$WORK/out.txt" && echo ja || echo nein)"
build; TEMP=85.2 run;                                          check "SoC ueber 80 Grad -> WARN" "ja" "$(has WARN 'SoC-Temperatur')"
build; NTP=no run;                                             check "Uhr nicht synchron -> WARN" "ja" "$(has WARN 'Uhr per NTP')"

echo "== Erwartungen (--expect-...) =="
build; NO_FW=1 run --expect-hardening;                         check "Haertung erwartet, Firewall fehlt -> FAIL" "ja" "$(has FAIL 'Firewall: Default-Deny')"
build; NO_FW=1 run;                                            check "Haertung nicht angefordert, Firewall fehlt -> nur INFO, Exit 0" "ja/0" "$(has INFO 'Firewall: Default-Deny')/$V_RC"
build; SSH_PW=yes run --expect-hardening;                      check "Haertung erwartet, Passwort-Login an -> FAIL" "ja" "$(has FAIL 'SSH wirksam: passwordauthentication no')"
build; AVAHI=enabled run --expect-hardening;                   check "Haertung erwartet, avahi laeuft -> FAIL" "ja" "$(has FAIL 'avahi-daemon.service aus')"
build; sed -i '/disable-bt/d' "$F/boot/firmware/config.txt"; run --expect-hardening
check "Haertung erwartet, Bluetooth-Overlay fehlt -> FAIL" "ja" "$(has FAIL 'Bluetooth-Funkmodul aus')"
build; OVERLAY=1 run --expect-overlay;                         check "Overlay erwartet, aber nicht aktiv -> FAIL" "ja" "$(has FAIL 'Root-Overlay aktiv')"
build; OVERLAY=1 BOOTRO=1 run;                                 check "Overlay nicht angefordert, nicht aktiv -> nur INFO, Exit 0" "ja/0" "$(has INFO 'Root-Overlay aktiv')/$V_RC"

echo "== ohne root, Optionen =="
build; STUB_UID=1000 VERIFY_ASSUME_ROOT=0 run --expect-hardening
check "ohne root: root-Pruefungen werden uebersprungen (SKIP), kein Absturz" "ja/ja" "$(has SKIP 'Wartungsskripte')/$(has SKIP 'Firewall und wirksame SSH')"
build; run --help;                                             check "--help: Exit 0 und Aufrufhilfe" "0/ja" "$V_RC/$(grep -q 'expect-hardening' "$WORK/out.txt" && echo ja || echo nein)"
build; run --unbekannt;                                        check "unbekannte Option: Exit 2" "2" "$V_RC"

echo
echo "Ergebnis: $pass ok, $fail Fehler"
[ "$fail" -eq 0 ]
