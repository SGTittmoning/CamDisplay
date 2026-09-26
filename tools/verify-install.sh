#!/bin/bash
# Prueft eine CamDisplay-Installation AUF DEM GERAET (nur lesend, aendert nichts).
# Gedacht als Abnahme nach install.yml: ein Befehl statt vieler Einzelchecks.
#
# Aufruf (root, sonst werden Pruefungen uebersprungen, die Root-Rechte brauchen):
#   sudo tools/verify-install.sh [Optionen]
#
# Optionen:
#   --expect-hardening   Firewall, SSH-Haertung, avahi/Bluetooth aus MUESSEN aktiv sein
#                        (sonst nur Information)
#   --expect-overlay     Read-only-Root (Overlay) und Boot-RO MUESSEN aktiv sein
#   --no-watchdog        Hardware-Watchdog wurde bewusst abgeschaltet
#   --service-user NAME  Service-User (Standard: camdisplay)
#   -h, --help
#
# Ausgabe: je Pruefung PASS / FAIL / WARN / INFO / SKIP. Zugangsdaten werden nie
# ausgegeben. Exit-Code 1, wenn mindestens eine Pruefung FAIL meldet.
#
# Testhaken (nur fuer die Testsuite): VERIFY_ROOT stellt allen Dateipfaden ein
# Praefix voran, VERIFY_ASSUME_ROOT=1 unterdrueckt die Root-Pruefung,
# VERIFY_OWNER ersetzt "root:root" bei den Besitzerangaben.

set -u

SERVICE_USER=camdisplay
EXPECT_HARDENING=0
EXPECT_OVERLAY=0
EXPECT_WATCHDOG=1

while [ $# -gt 0 ]; do
  case "$1" in
    --expect-hardening) EXPECT_HARDENING=1 ;;
    --expect-overlay)   EXPECT_OVERLAY=1 ;;
    --no-watchdog)      EXPECT_WATCHDOG=0 ;;
    --service-user)     shift; SERVICE_USER="${1:-camdisplay}" ;;
    -h|--help)          sed -n '2,24p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "Unbekannte Option: $1 (siehe --help)" >&2; exit 2 ;;
  esac
  shift
done

R="${VERIFY_ROOT:-}"
OWNER="${VERIFY_OWNER:-root:root}"
n_pass=0; n_fail=0; n_warn=0; n_skip=0

res() { # STATUS name [detail]
  case "$1" in PASS) n_pass=$((n_pass + 1));; FAIL) n_fail=$((n_fail + 1));; WARN) n_warn=$((n_warn + 1));; SKIP) n_skip=$((n_skip + 1));; esac
  printf '  %-5s %-58s %s\n' "$1" "$2" "${3:-}"
}
section() { printf '\n== %s ==\n' "$1"; }
is_root() { [ "${VERIFY_ASSUME_ROOT:-0}" = 1 ] || [ "$(id -u)" -eq 0 ]; }
have() { command -v "$1" >/dev/null 2>&1; }
# Pruefung, die Root braucht: bei fehlendem Root SKIP
root_only() { # name -> Rueckgabe 0 wenn Root vorhanden
  if is_root; then return 0; fi
  res SKIP "$1" "braucht root (sudo)"; return 1
}
# Pflicht-/Kann-Pruefung: bei --expect-X FAIL, sonst INFO-artiger WARN-freier Hinweis
expect() { # erwartet(0/1) bedingung(0=erfuellt) name detail-erfuellt detail-nicht
  if [ "$2" -eq 0 ]; then res PASS "$3" "$4"
  elif [ "$1" -eq 1 ]; then res FAIL "$3" "$5"
  else res INFO "$3" "$5 (nicht angefordert)"; fi
}

check_file() { # pfad modus besitzer name
  local p="$R$1" out
  if [ ! -e "$p" ]; then res FAIL "$4" "fehlt: $1"; return; fi
  out=$(stat -c '%a %U:%G' "$p" 2>/dev/null) || { res SKIP "$4" "nicht lesbar"; return; }
  if [ "$out" = "$2 $3" ]; then res PASS "$4" "$1 ($out)"; else res FAIL "$4" "$1 ist '$out', erwartet '$2 $3'"; fi
}

# ------------------------------------------------------------ Stream-URL lesen
STREAM_URL=""
if [ -r "$R/etc/camdisplay/stream.env" ]; then
  STREAM_URL=$(sed -n 's/^STREAM_URL=//p' "$R/etc/camdisplay/stream.env" | head -n 1)
  STREAM_URL=${STREAM_URL#\"}; STREAM_URL=${STREAM_URL%\"}; STREAM_URL=${STREAM_URL#\'}; STREAM_URL=${STREAM_URL%\'}
fi
HOST=""; PORT=""; SECRETS=""
if [[ "$STREAM_URL" == *://* ]]; then
  scheme=${STREAM_URL%%://*}; rest=${STREAM_URL#*://}
  authority=${rest%%[/?#]*}; query=""
  [[ "$rest" == *\?* ]] && query=${rest#*\?}
  hostport=${authority##*@}
  case "$scheme" in rtmp) PORT=1935;; rtmps|https) PORT=443;; rtsp) PORT=554;; rtsps) PORT=322;; http|rtmpt) PORT=80;; *) PORT="";; esac
  if [[ "$hostport" == \[* ]]; then
    HOST=${hostport%%]*}; HOST=${HOST#[}; [[ "${hostport#*]}" == :* ]] && PORT=${hostport#*]:}
  else
    HOST=${hostport%%:*}; [[ "$hostport" == *:* ]] && PORT=${hostport##*:}
  fi
  # Geheimnisse, nach denen im Log gesucht wird (mind. 4 Zeichen, sonst zu viele Fehlalarme)
  if [[ "$authority" == *@* ]]; then
    userinfo=${authority%@*}
    [[ "$userinfo" == *:* ]] && SECRETS="${userinfo#*:}"
  fi
  if [ -n "$query" ]; then
    oldifs=$IFS; IFS='&'
    for kv in $query; do
      key=$(printf '%s' "${kv%%=*}" | tr 'A-Z' 'a-z')
      case "$key" in pass|password|passwd|pwd|token|secret|key) SECRETS="$SECRETS
${kv#*=}";; esac
    done
    IFS=$oldifs
  fi
fi

echo "CamDisplay Installationspruefung ($(date '+%F %T'), Service-User: $SERVICE_USER)"
is_root || echo "Hinweis: ohne root werden einige Pruefungen uebersprungen (SKIP)."

# ----------------------------------------------------------------------- System
section "System"
model=$(tr -d '\0' < "$R/proc/device-tree/model" 2>/dev/null); res INFO "Modell" "${model:-unbekannt}"
osname=$(sed -n 's/^PRETTY_NAME=//p' "$R/etc/os-release" 2>/dev/null | tr -d '"'); res INFO "Betriebssystem" "${osname:-unbekannt} / Kernel $(uname -r 2>/dev/null)"
for pkg in ffmpeg libegl1 libegl-mesa0; do
  if dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null | grep -q 'install ok installed'; then res PASS "Paket $pkg installiert"
  else res FAIL "Paket $pkg installiert" "fehlt (ohne libegl: 'EGL not initialized')"; fi
done
have ffplay && res PASS "ffplay vorhanden" "$(ffplay -version 2>/dev/null | head -n 1 | cut -c1-40)" || res FAIL "ffplay vorhanden" "nicht im PATH"

# ------------------------------------------------------------------ Service-User
section "Service-User (unprivilegiert)"
if id "$SERVICE_USER" >/dev/null 2>&1; then
  res PASS "User $SERVICE_USER existiert"
  shell=$(getent passwd "$SERVICE_USER" | cut -d: -f7)
  case "$shell" in */nologin|*/false) res PASS "keine Login-Shell" "$shell" ;; *) res FAIL "keine Login-Shell" "Shell ist '$shell'" ;; esac
  groups=" $(id -nG "$SERVICE_USER" 2>/dev/null) "
  has_video=0; has_render=0
  case "$groups" in *" video "*) has_video=1 ;; esac
  case "$groups" in *" render "*) has_render=1 ;; esac
  if [ "$has_video" -eq 1 ] && [ "$has_render" -eq 1 ]; then res PASS "Gruppen video + render"; else res FAIL "Gruppen video + render" "Gruppen:$groups"; fi
  priv=""; for g in sudo adm wheel root; do case "$groups" in *" $g "*) priv="$priv $g";; esac; done
  [ -z "$priv" ] && res PASS "keine privilegierten Gruppen" || res FAIL "keine privilegierten Gruppen" "Mitglied in:$priv"
  if root_only "keine sudoers-Eintraege fuer $SERVICE_USER"; then
    if grep -rqE "^[[:space:]]*${SERVICE_USER}[[:space:]]" "$R/etc/sudoers" "$R/etc/sudoers.d" 2>/dev/null; then res FAIL "keine sudoers-Eintraege fuer $SERVICE_USER" "Eintrag gefunden"
    else res PASS "keine sudoers-Eintraege fuer $SERVICE_USER"; fi
  fi
else
  res FAIL "User $SERVICE_USER existiert" "fehlt"
fi

# ---------------------------------------------------------------------- Dateien
section "Dateien und Units"
check_file /usr/local/bin/camdisplay-run 755 "$OWNER" "Start-Wrapper"
if [ -e "$R/etc/camdisplay/stream.env" ]; then
  check_file /etc/camdisplay/stream.env 600 "$OWNER" "stream.env (nur root lesbar)"
  if [ -n "$STREAM_URL" ]; then res PASS "stream.env enthaelt STREAM_URL"
  elif is_root; then res FAIL "stream.env enthaelt STREAM_URL" "leer/fehlt"; else res SKIP "stream.env enthaelt STREAM_URL" "braucht root"; fi
else res FAIL "stream.env vorhanden" "fehlt"; fi
if root_only "Wartungsskripte in /root/bin (0700)"; then
  for s in camdisplay-update.sh camdisplay-writable.sh camdisplay-reboot-guard.sh camdisplay-reboot-count-reset.sh camdisplay-screenshot.sh; do
    check_file "/root/bin/$s" 700 "$OWNER" "  $s"
  done
fi
for u in camdisplay.service camdisplay-reboot.service camdisplay-reboot-count-reset.service camdisplay-reboot-count-reset.timer; do
  [ -e "$R/etc/systemd/system/$u" ] && res PASS "Unit $u" || res FAIL "Unit $u" "fehlt"
done
unit="$R/etc/systemd/system/camdisplay.service"
if [ -r "$unit" ]; then
  grep -qx "User=$SERVICE_USER" "$unit" && res PASS "Unit laeuft als $SERVICE_USER" || res FAIL "Unit laeuft als $SERVICE_USER" "$(grep '^User=' "$unit" | head -n 1)"
  grep -qx 'ExecStart=/usr/local/bin/camdisplay-run' "$unit" && res PASS "Unit startet den Wrapper" || res FAIL "Unit startet den Wrapper" "$(grep '^ExecStart=' "$unit" | head -n 1 | cut -c1-70)"
  grep -qx 'Environment=SDL_VIDEODRIVER=kmsdrm' "$unit" && res PASS "SDL_VIDEODRIVER=kmsdrm" || res FAIL "SDL_VIDEODRIVER=kmsdrm" "fehlt in der Unit"
  grep -qx 'Restart=always' "$unit" && res PASS "Restart=always (ffplay endet auch bei Fehlern mit 0)" || res FAIL "Restart=always" "fehlt"
fi

# ------------------------------------------------------------------------ Dienst
section "Dienst und Anzeige"
en=$(systemctl is-enabled camdisplay.service 2>/dev/null); [ "$en" = enabled ] && res PASS "camdisplay.service aktiviert" || res FAIL "camdisplay.service aktiviert" "Status: ${en:-unbekannt}"
act=$(systemctl is-active camdisplay.service 2>/dev/null); [ "$act" = active ] && res PASS "camdisplay.service laeuft" || res FAIL "camdisplay.service laeuft" "Status: ${act:-unbekannt}"
if [ "$act" = active ]; then
  enter=$(systemctl show --property=ActiveEnterTimestampMonotonic --value camdisplay.service 2>/dev/null)
  up_us=$(awk '{printf "%d", $1 * 1000000}' "$R/proc/uptime" 2>/dev/null)
  if [[ "$enter" =~ ^[0-9]+$ ]] && [ "$enter" -gt 0 ] && [[ "$up_us" =~ ^[0-9]+$ ]]; then
    secs=$(( (up_us - enter) / 1000000 ))
    if [ "$secs" -ge 300 ]; then res PASS "laeuft stabil seit mindestens 5 Minuten" "${secs}s"; else res WARN "laeuft stabil seit mindestens 5 Minuten" "erst seit ${secs}s (erneut pruefen)"; fi
  else res SKIP "Laufzeit des Dienstes" "nicht ermittelbar"; fi
  nr=$(systemctl show --property=NRestarts --value camdisplay.service 2>/dev/null)
  [[ "$nr" =~ ^[0-9]+$ ]] && { [ "$nr" -le 2 ] && res PASS "wenige Neustarts des Dienstes" "NRestarts=$nr" || res WARN "wenige Neustarts des Dienstes" "NRestarts=$nr"; }
  fp=$(ps -o user= -C ffplay 2>/dev/null | sort -u | tr -d ' ' | paste -sd, -)
  if [ -z "$fp" ]; then res FAIL "ffplay laeuft" "kein ffplay-Prozess"
  elif [ "$fp" = "$SERVICE_USER" ]; then res PASS "ffplay laeuft als $SERVICE_USER"
  else res FAIL "ffplay laeuft als $SERVICE_USER" "laeuft als: $fp"; fi
fi
conn=""; for f in "$R"/sys/class/drm/card*-*/status; do [ -r "$f" ] && [ "$(cat "$f")" = connected ] && conn="$conn $(basename "$(dirname "$f")")"; done
[ -n "$conn" ] && res PASS "Monitor erkannt (DRM-Connector connected)" "$conn" || res WARN "Monitor erkannt (DRM-Connector connected)" "kein verbundener Connector"
t=camdisplay-reboot-count-reset.timer
a=$(systemctl is-active "$t" 2>/dev/null); e=$(systemctl is-enabled "$t" 2>/dev/null)
if [ "$a" = active ] && [ "$e" = enabled ]; then res PASS "Timer $t aktiv"; else res FAIL "Timer $t aktiv" "active=$a enabled=$e"; fi

# --------------------------------------------------------------------- Kamera
section "Kamera und Zugangsdaten"
if [ -n "$HOST" ] && [[ "$PORT" =~ ^[0-9]+$ ]]; then
  if timeout 3 bash -c 'exec 3<>"/dev/tcp/$1/$2"' _ "$HOST" "$PORT" 2>/dev/null; then res PASS "Kamera per TCP erreichbar" "$HOST:$PORT"
  else res WARN "Kamera per TCP erreichbar" "$HOST:$PORT nicht erreichbar"; fi
else res SKIP "Kamera per TCP erreichbar" "kein TCP-Ziel aus STREAM_URL ableitbar"; fi
if [ -n "$SECRETS" ]; then
  if root_only "Zugangsdaten nicht im Journal/Fehlerlog"; then
    leaked=0; checked=0
    jtxt=$(journalctl -u camdisplay.service --no-pager -o cat -n 2000 2>/dev/null)
    ftxt=$(cat "$R/boot/firmware/camdisplay-failure-log.txt" 2>/dev/null)
    while IFS= read -r sec; do
      [ "${#sec}" -ge 4 ] || continue
      checked=$((checked + 1))
      printf '%s\n%s\n' "$jtxt" "$ftxt" | grep -qF -- "$sec" && leaked=$((leaked + 1))
    done <<< "$SECRETS"
    if [ "$checked" -eq 0 ]; then res SKIP "Zugangsdaten nicht im Journal/Fehlerlog" "keine pruefbaren Geheimnisse in der URL"
    elif [ "$leaked" -eq 0 ]; then res PASS "Zugangsdaten nicht im Journal/Fehlerlog" "$checked Geheimnis(se) in $(printf '%s\n' "$jtxt" | wc -l) Journalzeilen nicht gefunden"
    else res FAIL "Zugangsdaten nicht im Journal/Fehlerlog" "$leaked Geheimnis(se) im Klartext gefunden!"; fi
  fi
else res INFO "Zugangsdaten nicht im Journal/Fehlerlog" "URL ohne erkennbare Zugangsdaten"; fi
res INFO "Hinweis" "die URL steht systembedingt in der Prozessliste (ps) - Nur-Lese-Account an der Kamera empfohlen"
if have nmcli; then
  wl=$(nmcli -t -f TYPE connection show 2>/dev/null | grep -cE 'wireless|wifi')
  [ "$wl" -eq 0 ] && res PASS "keine gespeicherten WLAN-Profile (Zugangsdaten)" || res FAIL "keine gespeicherten WLAN-Profile (Zugangsdaten)" "$wl Profil(e) vorhanden"
fi

# ------------------------------------------------------------- Reboot-Guard/Log
section "Reboot-Guard (Zustand)"
cnt="$R/boot/firmware/.camdisplay-reboot-count"
[ -f "$cnt" ] && res INFO "Reboot-Zaehler" "$(cat "$cnt") von 5" || res PASS "Reboot-Zaehler" "keiner (keine Reboots durch den Guard)"
[ -f "$R/run/camdisplay-unreachable-count" ] && res INFO "Fehlversuche 'Kamera nicht erreichbar'" "$(cat "$R/run/camdisplay-unreachable-count") seit dem Boot"
fl="$R/boot/firmware/camdisplay-failure-log.txt"
if [ -f "$fl" ]; then res INFO "Fehlerlog vor Reboots" "$(grep -c '^=== Reboot' "$fl") Eintrag/Eintraege, $(wc -c < "$fl") Bytes (Datei: /boot/firmware/camdisplay-failure-log.txt)"; else res INFO "Fehlerlog vor Reboots" "keins (noch nie neu gestartet)"; fi
systemctl list-timers camdisplay-slow-retry.timer --no-legend 2>/dev/null | grep -q camdisplay-slow-retry && res WARN "geplanter Neustartversuch (Kamera weg?)" "camdisplay-slow-retry.timer ist gerade geplant"

# ----------------------------------------------------------- Schutz vor Stromausfall
section "Read-only-Schutz (Overlay/Boot-RO)"
if have raspi-config; then
  ov=$(raspi-config nonint get_overlay_now 2>/dev/null); br=$(raspi-config nonint get_bootro_now 2>/dev/null)
  expect "$EXPECT_OVERLAY" "$([ "$ov" = 0 ] && echo 0 || echo 1)" "Root-Overlay aktiv" "aktiv" "nicht aktiv (Root ist beschreibbar)"
  expect "$EXPECT_OVERLAY" "$([ "$br" = 0 ] && echo 0 || echo 1)" "Boot-Partition read-only" "read-only" "beschreibbar"
else res SKIP "Overlay/Boot-RO" "raspi-config fehlt"; fi

# ------------------------------------------------------------------- Watchdog
section "Hardware-Watchdog"
if [ "$EXPECT_WATCHDOG" -eq 1 ]; then
  [ -e "$R/dev/watchdog" ] && res PASS "/dev/watchdog vorhanden" || res FAIL "/dev/watchdog vorhanden" "fehlt (Treiber abgeschaltet oder anderes Board)"
  [ -e "$R/etc/systemd/system.conf.d/10-camdisplay-watchdog.conf" ] && res PASS "Watchdog-Drop-in vorhanden" || res FAIL "Watchdog-Drop-in vorhanden" "fehlt"
  wd=$(systemctl show --property=RuntimeWatchdogUSec --value 2>/dev/null)
  # Erwartet wird der im Drop-in konfigurierte Wert (camdisplay_watchdog_sec ist einstellbar)
  want=$(sed -n 's/^RuntimeWatchdogSec=\([0-9]\{1,\}\)$/\1/p' "$R/etc/systemd/system.conf.d/10-camdisplay-watchdog.conf" 2>/dev/null | head -n 1)
  want=${want:-10}
  case "$wd" in "${want}s"|"$((want * 1000000))") res PASS "Watchdog aktiv (RuntimeWatchdogUSec)" "$wd" ;; *) res WARN "Watchdog aktiv (RuntimeWatchdogUSec)" "meldet '${wd:-leer}', erwartet ${want}s (Manager neu gestartet? anderer Dienst haelt /dev/watchdog?)" ;; esac
else
  wd=$(systemctl show --property=RuntimeWatchdogUSec --value 2>/dev/null); res INFO "Watchdog bewusst aus" "RuntimeWatchdogUSec=${wd:-?}"
fi

# --------------------------------------------------------------------- Haertung
section "OS-Haertung ($( [ "$EXPECT_HARDENING" -eq 1 ] && echo erwartet || echo optional ))"
if is_root; then
  if have nft; then
    rules=$(nft list ruleset 2>/dev/null)
    expect "$EXPECT_HARDENING" "$(printf '%s' "$rules" | grep -q 'policy drop' && echo 0 || echo 1)" "Firewall: Default-Deny eingehend" "geladen" "keine Regeln mit policy drop"
    expect "$EXPECT_HARDENING" "$(printf '%s' "$rules" | grep -Eq 'dport 22|dport ssh' && echo 0 || echo 1)" "Firewall: SSH ausdruecklich erlaubt" "Regel vorhanden" "keine SSH-Regel"
  else res SKIP "Firewall" "nft fehlt"; fi
  if have sshd; then
    eff=$(sshd -T 2>/dev/null)
    for kv in "permitrootlogin no" "x11forwarding no" "passwordauthentication no" "kbdinteractiveauthentication no"; do
      expect "$EXPECT_HARDENING" "$(printf '%s\n' "$eff" | grep -qx "$kv" && echo 0 || echo 1)" "SSH wirksam: $kv" "gesetzt" "anders (sshd -T)"
    done
  else res SKIP "SSH-Werte" "sshd fehlt"; fi
else res SKIP "Firewall und wirksame SSH-Werte" "braucht root (sudo)"; fi
for u in avahi-daemon.service bluetooth.service; do
  s=$(systemctl is-enabled "$u" 2>&1 | head -n 1)
  case "$s" in masked|not-found|*"No such file"*) expect "$EXPECT_HARDENING" 0 "$u aus" "$s" "" ;; *) expect "$EXPECT_HARDENING" 1 "$u aus" "" "Status: ${s:-?}" ;; esac
done
grep -qs '^dtoverlay=disable-bt' "$R/boot/firmware/config.txt" && res PASS "Bluetooth-Funkmodul aus (dtoverlay)" || expect "$EXPECT_HARDENING" 1 "Bluetooth-Funkmodul aus (dtoverlay)" "" "dtoverlay=disable-bt fehlt"
grep -qs '^dtoverlay=disable-wifi' "$R/boot/firmware/config.txt" && res PASS "WLAN-Funkmodul aus (dtoverlay)" || res WARN "WLAN-Funkmodul aus (dtoverlay)" "dtoverlay=disable-wifi fehlt"

# ---------------------------------------------------------------- Netz und Zeit
section "Netz, Zeit, Stromversorgung"
res INFO "Hostname / Adressen" "$(hostname 2>/dev/null) / $(hostname -I 2>/dev/null | cut -c1-60)"
ntp=$(timedatectl show --property=NTPSynchronized --value 2>/dev/null)
case "$ntp" in yes) res PASS "Uhr per NTP synchronisiert" ;; no) res WARN "Uhr per NTP synchronisiert" "nicht synchron (kein RTC: Zeitstempel unzuverlaessig)" ;; *) res SKIP "Uhr per NTP synchronisiert" "nicht ermittelbar" ;; esac
if have vcgencmd; then
  th=$(vcgencmd get_throttled 2>/dev/null | sed 's/.*=//')
  if [ "$th" = "0x0" ]; then res PASS "Stromversorgung/Temperatur (get_throttled)" "0x0"
  else
    d=""; v=$((th)) 2>/dev/null
    [ $((v & 0x1)) -ne 0 ] && d="$d Unterspannung-jetzt"; [ $((v & 0x4)) -ne 0 ] && d="$d gedrosselt-jetzt"
    [ $((v & 0x10000)) -ne 0 ] && d="$d Unterspannung-seit-Boot"; [ $((v & 0x40000)) -ne 0 ] && d="$d gedrosselt-seit-Boot"
    res WARN "Stromversorgung/Temperatur (get_throttled)" "$th${d:+ ($d )} - Netzteil/Kuehlung pruefen"
  fi
  t=$(vcgencmd measure_temp 2>/dev/null | sed "s/[^0-9.]//g")
  if [ -n "$t" ]; then if awk "BEGIN{exit !($t > 80)}"; then res WARN "SoC-Temperatur" "${t} Grad (ueber 80)"; else res PASS "SoC-Temperatur" "${t} Grad"; fi; fi
else res SKIP "Stromversorgung/Temperatur" "vcgencmd fehlt"; fi

echo
printf 'Ergebnis: %d PASS, %d FAIL, %d WARN, %d SKIP\n' "$n_pass" "$n_fail" "$n_warn" "$n_skip"
[ "$n_fail" -eq 0 ]
