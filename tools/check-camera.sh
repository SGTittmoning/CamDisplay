#!/bin/bash
# Prueft den Kamera-Stream von einem Rechner aus, der die Kamera erreicht
# (z.B. Mac ueber VPN) - OHNE Pi. Liefert Belege dafuer, dass die Flags des
# Wrappers (camdisplay-run) zur echten Kamera passen, und beantwortet, ob die
# schnelle Stream-Analyse (-analyzeduration 1) den Stream richtig erkennt.
#
# Voraussetzung: ffmpeg, ffprobe (und optional ffplay) im PATH
#   macOS:  brew install ffmpeg        Debian/Ubuntu: apt install ffmpeg
#
# Die URL enthaelt Zugangsdaten - deshalb NICHT als Argument (landet in der
# Shell-Historie und in ps). Uebergabe:
#   STREAM_URL='rtmp://...' tools/check-camera.sh
#   tools/check-camera.sh --env-file /pfad/zu/stream.env   (Zeile STREAM_URL="...")
#   tools/check-camera.sh                                   (fragt verdeckt nach)
# Die Ausgabe zeigt die URL nie im Klartext und kann so zurueckgemeldet werden.
#
# Optionen:  --seconds N   Dauer des Dekodiertests (Standard 15)
#            -h, --help
#
# Portabel gehalten (bash 3.2 wie auf macOS, kein "timeout", nur POSIX-awk/sed).
# Aendert nichts und zeigt kein Bild an (ffplay laeuft mit dem SDL-Dummy-Treiber;
# NICHT mit -nodisp: das beendet sich bei einer nicht erreichbaren Quelle nie).

set -u

SECONDS_TEST=15
ENV_FILE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --seconds) shift; SECONDS_TEST="${1:-15}" ;;
    --env-file) shift; ENV_FILE="${1:-}" ;;
    -h|--help) sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "Unbekannte Option: $1 (siehe --help)" >&2; exit 2 ;;
  esac
  shift
done

# Muss mit den Flags in ansible/files/camdisplay-run.sh uebereinstimmen (die
# Testsuite prueft das). Ohne Zusatz-Optionen und ohne URL.
FFPLAY_FLAGS="-autoexit -rw_timeout 5000000 -fs -analyzeduration 1 -flags low_delay -framedrop -an -nostats -loglevel error"

URL="${STREAM_URL:-}"
if [ -z "$URL" ] && [ -n "$ENV_FILE" ]; then
  URL=$(sed -n 's/^STREAM_URL=//p' "$ENV_FILE" 2>/dev/null | head -n 1)
  URL=${URL#\"}; URL=${URL%\"}; URL=${URL#\'}; URL=${URL%\'}
fi
if [ -z "$URL" ]; then
  printf 'Stream-URL (Eingabe wird nicht angezeigt): ' >&2
  read -rs URL; echo >&2
fi
[ -n "$URL" ] || { echo "Keine URL angegeben." >&2; exit 2; }

n_fail=0; n_warn=0
# Filter: exakte URL und Zugangsdaten-Muster maskieren (awk statt bash-Ersetzung: portabel)
mask() {
  awk -v u="$URL" '{
    while (u != "" && (i = index($0, u)) > 0) $0 = substr($0, 1, i - 1) "<stream-url>" substr($0, i + length(u))
    print
  }' | sed -E -e 's#(://)[^/@[:space:]]*@#\1***@#g' \
                -e 's#((pass(word|wd)?|pwd|token|secret|key)=)[^\&[:space:]"'"'"']*#\1***#g'
}
say()  { printf '%s\n' "$*" | mask; }
pass() { say "  PASS  $*"; }
fail() { n_fail=$((n_fail + 1)); say "  FAIL  $*"; }
warn() { n_warn=$((n_warn + 1)); say "  WARN  $*"; }
info() { say "  INFO  $*"; }
now()  { date +%s; }
# Harte Zeitobergrenze fuer einen Befehl (macOS hat kein "timeout"; perl ist ueberall da)
limit() { # sekunden befehl...
  local secs=$1; shift
  if command -v perl >/dev/null 2>&1; then perl -e 'alarm shift @ARGV; exec @ARGV or exit 127' "$secs" "$@"; else "$@"; fi
}

echo "CamDisplay Kamera-Pruefung"
echo
echo "== Werkzeuge =="
for t in ffmpeg ffprobe; do
  if command -v "$t" >/dev/null 2>&1; then pass "$t vorhanden ($("$t" -version 2>/dev/null | head -n 1 | cut -c1-48))"
  else fail "$t fehlt - Installation siehe Kopf dieses Skripts"; fi
done
HAVE_FFPLAY=0; command -v ffplay >/dev/null 2>&1 && HAVE_FFPLAY=1
[ "$HAVE_FFPLAY" -eq 1 ] && pass "ffplay vorhanden" || warn "ffplay fehlt - der Flag-Test mit ffplay wird uebersprungen"
[ "$n_fail" -eq 0 ] || { echo; echo "Abbruch: benoetigte Werkzeuge fehlen."; exit 1; }

# ------------------------------------------------------------------ URL zerlegen
scheme=${URL%%://*}; rest=${URL#*://}
authority=${rest%%[/?#]*}; hostport=${authority##*@}
case "$scheme" in rtmp) port=1935;; rtmps|https) port=443;; rtsp) port=554;; rtsps) port=322;; http|rtmpt) port=80;; *) port="";; esac
if [ "${hostport#\[}" != "$hostport" ]; then host=${hostport%%]*}; host=${host#[}; case "${hostport#*]}" in :*) port=${hostport#*]:};; esac
else host=${hostport%%:*}; case "$hostport" in *:*) port=${hostport##*:};; esac; fi
echo
echo "== Ziel =="
info "Protokoll $scheme, Host $host, Port ${port:-?}"
case "$scheme" in
  rtsp|rtsps) info "RTSP: fuer die Anzeige ggf. STREAM_OPTS=\"-rtsp_transport tcp\" setzen (nicht im Wrapper eingebaut)" ;;
  rtmp|rtmps) info "RTMP: '-rtsp_transport' und '-timeout' duerfen NICHT verwendet werden (bricht ffplay bzw. macht es zum Server)" ;;
esac

# ----------------------------------------------------------------- TCP-Erreichbarkeit
echo
echo "== Erreichbarkeit =="
if [ -n "$port" ] && command -v perl >/dev/null 2>&1 && \
   perl -MIO::Socket::INET -e 'IO::Socket::INET->new(PeerAddr=>$ARGV[0],PeerPort=>$ARGV[1],Timeout=>4) or exit 1' "$host" "$port" 2>/dev/null; then
  pass "TCP-Verbindung zu $host:$port moeglich"
else
  fail "TCP-Verbindung zu $host:$port nicht moeglich (VPN aktiv? Kamera an?)"
  echo; echo "Ergebnis: Kamera nicht erreichbar - weitere Pruefungen sind sinnlos."; exit 1
fi

# --------------------------------------------------------------------- Stream-Analyse
retry() { # Befehl... -> bis zu 3 Versuche (Kameras/Testserver nehmen manchmal nicht sofort an)
  local n=0 out rc
  while [ $n -lt 3 ]; do
    out=$("$@" 2>&1); rc=$?
    if [ $rc -eq 0 ] && [ -n "$out" ]; then printf '%s\n' "$out"; return 0; fi
    n=$((n + 1)); sleep 1
  done
  printf '%s\n' "$out"; return 1
}
FIELDS="stream=codec_type,codec_name,profile,level,width,height,pix_fmt,r_frame_rate,avg_frame_rate"
probe() { # weitere ffprobe-Optionen
  retry limit 40 ffprobe -v error "$@" -show_entries "$FIELDS" -of compact=p=0 "$URL"
}
echo
echo "== Stream-Analyse (ffprobe) =="
t0=$(now); std=$(probe -rw_timeout 10000000); rc_std=$?; t1=$(now)
if [ $rc_std -eq 0 ]; then pass "Standard-Analyse in $((t1 - t0)) s"; else fail "Standard-Analyse fehlgeschlagen: $(printf '%s' "$std" | tail -n 2 | tr '\n' ' ')"; fi
t0=$(now); fast=$(probe -rw_timeout 10000000 -analyzeduration 1); rc_fast=$?; t1=$(now)
if [ $rc_fast -eq 0 ]; then pass "Schnelle Analyse (-analyzeduration 1, wie im Wrapper) in $((t1 - t0)) s"; else fail "Schnelle Analyse fehlgeschlagen: $(printf '%s' "$fast" | tail -n 2 | tr '\n' ' ')"; fi
printf '%s\n' "$std" | while IFS= read -r l; do info "Stream: $l"; done
# r_frame_rate ist nur eine Schaetzung (bei -analyzeduration 1 z.B. doppelt so hoch) und fuer die
# Wiedergabe ohne Belang - verglichen werden Codec, Profil, Level, Groesse, Pixelformat, avg_frame_rate.
norm() { printf '%s\n' "$1" | sed -E 's/\|?r_frame_rate=[^|]*//'; }
if [ $rc_std -eq 0 ] && [ $rc_fast -eq 0 ]; then
  if [ "$(norm "$std")" = "$(norm "$fast")" ]; then
    pass "Beide Analysen liefern identische Stream-Parameter (O4: -analyzeduration 1 ist unkritisch)"
    [ "$std" = "$fast" ] || info "nur die geschaetzte r_frame_rate weicht ab (Standard vs. schnell) - ohne Belang fuer die Wiedergabe"
  else
    warn "Die schnelle Analyse erkennt den Stream ANDERS als die Standard-Analyse:"
    printf '%s\n' "$fast" | while IFS= read -r l; do info "schnell: $l"; done
    info "-> -analyzeduration erhoehen (z.B. 1000000) und -probesize setzen, sonst drohen falsch erkannte Codec-Parameter"
  fi
fi
vid=$(printf '%s\n' "$std" | grep 'codec_type=video' | head -n 1)
case "$vid" in *codec_name=h264*) pass "Videocodec H.264 (Software-Dekodierung auf dem Pi 4 unkritisch)" ;; "") warn "kein Videostream erkannt" ;; *) warn "Videocodec ist nicht H.264: $vid" ;; esac

# -------------------------------------------------------------------- Dekodiertest
echo
echo "== Dekodiertest (${SECONDS_TEST} s, mit den Wrapper-Flags) =="
log=$(mktemp); ws=$(now); attempt=0
while :; do
  attempt=$((attempt + 1))
  limit $((SECONDS_TEST + 40)) ffmpeg -nostdin -hide_banner -loglevel info -stats -rw_timeout 5000000 -analyzeduration 1 -flags low_delay \
    -i "$URL" -t "$SECONDS_TEST" -an -f null - > "$log" 2>&1; rc=$?
  # Kameras und Testserver nehmen manchmal nicht sofort an: bis zu 3 Versuche
  if [ "$rc" -ne 0 ] && [ $attempt -lt 3 ] && grep -q 'Connection refused' "$log"; then sleep 1; ws=$(now); continue; fi
  break
done
we=$(now); wall=$((we - ws))
frames=$(tr '\r' '\n' < "$log" | grep -o 'frame= *[0-9]*' | tail -n 1 | tr -dc '0-9')
speed=$(tr '\r' '\n' < "$log" | grep -o 'speed= *[0-9.]*x' | tail -n 1 | tr -d ' ')
errs=$(grep -ciE 'error|corrupt|missing|concealing|invalid|non-existing' "$log")
if [ "$rc" -eq 0 ]; then pass "ffmpeg beendete den Test regulaer (rc=0)"; else fail "ffmpeg endete mit rc=$rc: $(tail -n 3 "$log" | tr '\n\r' '  ' | cut -c1-140)"; fi
info "Dauer ${wall} s fuer ${SECONDS_TEST} s Material (Startverzoegerung etwa $((wall - SECONDS_TEST)) s), Bilder: ${frames:-?}, Geschwindigkeit: ${speed:-?}"
if [ -n "$frames" ] && [ "$frames" -gt 0 ]; then
  fps=$(awk -v f="$frames" -v s="$SECONDS_TEST" 'BEGIN{printf "%.1f", f/s}'); info "Mittlere Bildrate ca. ${fps} fps"
  pass "Bilder wurden dekodiert"
else fail "keine Bilder dekodiert"; fi
if [ "${errs:-0}" -eq 0 ]; then pass "keine Dekodier-/Verbindungsfehler im Log"; else warn "$errs Zeile(n) mit Fehlerbegriffen im Log (Auszug unten)"; grep -iE 'error|corrupt|missing|concealing|invalid|non-existing' "$log" | head -n 5 | while IFS= read -r l; do info "log: $(printf '%s' "$l" | cut -c1-120)"; done; fi
rm -f "$log"

# ------------------------------------------------------------------ ffplay-Flags
echo
echo "== ffplay mit den Flags des Wrappers (Dummy-Treiber, kein Fenster) =="
if [ "$HAVE_FFPLAY" -eq 1 ]; then
  log=$(mktemp); attempt=0
  while :; do
    attempt=$((attempt + 1))
    # shellcheck disable=SC2086  # FFPLAY_FLAGS ist absichtlich eine Wortliste
    SDL_VIDEODRIVER="${SDL_VIDEODRIVER:-dummy}" SDL_AUDIODRIVER=dummy limit 10 ffplay -t 6 $FFPLAY_FLAGS "$URL" > "$log" 2>&1; rc=$?
    if grep -q 'Connection refused' "$log" && [ $attempt -lt 3 ]; then sleep 1; continue; fi
    break
  done
  if grep -qi 'not found' "$log"; then fail "ffplay lehnt eine Option ab: $(grep -i 'not found' "$log" | head -n 1 | cut -c1-100)"
  elif grep -q 'Connection refused' "$log"; then fail "ffplay konnte die Quelle nicht oeffnen: $(grep -i 'refused' "$log" | head -n 1 | cut -c1-100)"
  elif [ "$rc" -eq 142 ] || [ "$rc" -eq 14 ] || [ "$rc" -eq 0 ]; then pass "ffplay akzeptiert alle Wrapper-Flags und laeuft ohne Fehlermeldung (bei Live-Streams greift das Zeitlimit regulaer)"
  else warn "ffplay endete mit rc=$rc: $(tail -n 2 "$log" | tr '\n' ' ' | cut -c1-120)"; fi
  rm -f "$log"
  # Kommen wirklich Bilder an? Nur "ffplay laeuft ohne Fehler" reicht nicht: die Statistik
  # zeigt eine laufende Zeitposition ("M-V: 0.000"), oder "nan" wenn kein Bild dekodiert wird.
  render_check() { # zusaetzliche Flags -> ok | nan | none | refused
    local extra=$1 rlog base line n=0
    rlog=$(mktemp); base=${FFPLAY_FLAGS/ -nostats -loglevel error/}
    while :; do
      n=$((n + 1))
      # shellcheck disable=SC2086
      SDL_VIDEODRIVER="${SDL_VIDEODRIVER:-dummy}" SDL_AUDIODRIVER=dummy limit 14 ffplay -stats -loglevel info -t 5 $base $extra "$URL" > "$rlog" 2>&1
      grep -q 'Connection refused' "$rlog" && [ $n -lt 3 ] && { sleep 1; continue; }
      break
    done
    line=$(tr '\r' '\n' < "$rlog" | grep 'M-V' | tail -n 1)
    grep -q 'Connection refused' "$rlog" && line=refused
    rm -f "$rlog"
    case "$line" in "") echo none ;; refused) echo refused ;; *nan*) echo nan ;; *) echo ok ;; esac
  }
  case "$(render_check "")" in
    ok) pass "ffplay rendert Bilder mit den Wrapper-Flags (Zeitposition laeuft)" ;;
    nan) fail "ffplay bekommt KEINE Bilder mit den Wrapper-Flags (Statistik 'nan M-V') - Flags nicht produktiv einsetzen" ;;
    refused) fail "ffplay konnte die Quelle nicht oeffnen" ;;
    *) warn "ffplay-Statistik nicht auswertbar (kein 'M-V' im Log)" ;;
  esac
  # Experiment: -fflags +nobuffer (bewusst nicht im Wrapper - siehe camdisplay-run.sh)
  case "$(render_check "-fflags +nobuffer")" in
    ok) info "Experiment -fflags +nobuffer: Bilder kommen an - kann per STREAM_OPTS=\"-fflags +nobuffer\" fuer geringere Latenz erprobt werden" ;;
    nan) info "Experiment -fflags +nobuffer: es kommen KEINE Bilder an - so lassen (nicht setzen)" ;;
    *) info "Experiment -fflags +nobuffer: nicht auswertbar" ;;
  esac
else info "uebersprungen (ffplay nicht installiert)"; fi

echo
echo "Ergebnis: $n_fail FAIL, $n_warn WARN"
echo "Bitte diese Ausgabe zurueckmelden (die URL ist maskiert)."
[ "$n_fail" -eq 0 ]
