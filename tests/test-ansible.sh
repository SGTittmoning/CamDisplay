#!/bin/bash
# Tests fuer die Ansible-Teile (Haertung, Watchdog), die echtes Ansible, nft und
# sshd brauchen. Ohne root und ohne Hardware: Task-Ausschnitte laufen gegen
# localhost, Firewall-Regeln werden nur syntaktisch geprueft (nft -c), SSH-Werte
# gegen "sshd -T" mit einer Testkonfiguration.
#
# Aufruf:  tests/test-ansible.sh      (ansible-playbook/ansible muessen im PATH sein)
#
# Nicht testbar ohne Zielgeraet: apt/systemd-Aktionen auf einem echten Pi, das
# tatsaechliche Laden der Firewall, der Watchdog.

set -u

ROOT=$(cd "$(dirname "$0")/.." && pwd)
A="$ROOT/ansible"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
export ANSIBLE_LOCALHOST_WARNING=False ANSIBLE_INVENTORY_UNPARSED_WARNING=False

pass=0; fail=0; skipped=0
ok()   { pass=$((pass + 1)); printf '  ok    %s\n' "$1"; }
bad()  { fail=$((fail + 1)); printf '  FEHLER %s\n         %s\n' "$1" "${2:-}"; }
skip() { skipped=$((skipped + 1)); printf '  skip  %s (%s)\n' "$1" "$2"; }
check() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "erwartet '$2', erhalten '$3'"; fi; }

if ! command -v ansible-playbook >/dev/null 2>&1; then
  echo "ansible-playbook nicht gefunden - Tests uebersprungen"; exit 0
fi

# Task-Ausschnitt (von bis-vor Ueberschrift) aus einer Task-Datei holen
extract() { # datei start-Ueberschrift ende-Ueberschrift(exklusiv)
  awk -v s="$2" -v e="$3" '$0 ~ "^- name: " s {p=1} p && $0 ~ "^- name: " e {exit} p' "$1"
}
render() { # template zielpfad json-variablen
  ansible localhost -c local -m template -a "{\"src\": \"$1\", \"dest\": \"$2\"}" -e "$3" > "$WORK/render.log" 2>&1
}
play() { # playbook-datei -> Exit-Code, Ausgabe in $WORK/play.log
  ansible-playbook -i localhost, "$1" "${@:2}" > "$WORK/play.log" 2>&1; echo $?
}

# ---------------------------------------------------------------- Firewall
echo "== nftables =="
nft_check() { # datei -> 0 gueltig, 1 ungueltig, 9 nicht pruefbar
  local f=$1 out rc
  if [ "$(id -u)" -eq 0 ]; then out=$(nft -c -f "$f" 2>&1); rc=$?
  elif unshare -Urn true >/dev/null 2>&1; then out=$(unshare -Urn nft -c -f "$f" 2>&1); rc=$?
  elif sudo -n true >/dev/null 2>&1; then out=$(sudo -n nft -c -f "$f" 2>&1); rc=$?
  else return 9; fi
  echo "$out" > "$WORK/nft.out"
  [ "$rc" -eq 0 ] && return 0 || return 1
}
if ! command -v nft >/dev/null 2>&1; then skip "Syntaxpruefung der Firewall-Regeln" "nft nicht installiert"
else
  printf 'table inet filter { chain input { type filter hook input priority 0; policy drop; tcp dport ssh acceptt } }\n' > "$WORK/bad.nft"
  nft_check "$A/files/nftables.conf"; rc_good=$?
  if [ "$rc_good" -eq 9 ]; then skip "Syntaxpruefung der Firewall-Regeln" "weder root noch User-Namespace noch sudo"
  else
    check "nftables.conf ist syntaktisch gueltig" "0" "$rc_good"
    nft_check "$WORK/bad.nft"; check "Gegenprobe: eine kaputte Regel wird abgelehnt" "1" "$?"
  fi
fi
conf=$(grep -vE '^\s*#|^\s*$' "$A/files/nftables.conf")
check "eingehend: Default-Deny (policy drop)" "ja" "$(echo "$conf" | grep -q 'hook input.*policy drop' && echo ja || echo nein)"
check "SSH ist ausdruecklich erlaubt (kein Aussperren)" "ja" "$(echo "$conf" | grep -q 'tcp dport 22 accept' && echo ja || echo nein)"
check "ausgehend bleibt offen (Kamera-Stream, Erreichbarkeitspruefung)" "ja" "$(echo "$conf" | grep -q 'hook output.*policy accept' && echo ja || echo nein)"
check "etablierte Verbindungen erlaubt (laufende SSH-Sitzung ueberlebt den Neustart des Dienstes)" "ja" "$(echo "$conf" | grep -q 'ct state established,related accept' && echo ja || echo nein)"

# -------------------------------------------------------------------- SSH
echo "== SSH-Drop-in: wirksame Werte (sshd -T) =="
if ! command -v sshd >/dev/null 2>&1 || ! command -v ssh-keygen >/dev/null 2>&1; then
  skip "wirksame SSH-Konfiguration" "sshd/ssh-keygen nicht installiert"
else
  S="$WORK/sshd"; mkdir -p "$S/conf.d"; ssh-keygen -q -t ed25519 -N '' -f "$S/hostkey"
  # feindliche Ausgangslage: Hauptdatei UND ein spaeteres Drop-in (wie vom Imager) erlauben alles
  adverse() { printf 'Include %s/conf.d/*.conf\nHostKey %s/hostkey\nPasswordAuthentication yes\nPermitRootLogin yes\nX11Forwarding yes\nClientAliveInterval 0\n' "$S" "$S" > "$S/sshd_config"; }
  printf 'PasswordAuthentication yes\nKbdInteractiveAuthentication yes\nPermitRootLogin yes\n' > "$S/conf.d/50-imager.conf"
  eff() { sshd -T -f "$S/sshd_config" 2>&1; }
  hardened() { # pw-Flag
    rm -f "$S/conf.d/00-camdisplay-hardening.conf"; adverse
    render "$A/templates/sshd-hardening.conf.j2" "$S/conf.d/00-camdisplay-hardening.conf" "{\"camdisplay_ssh_disable_password_auth\": $1}"
  }
  hardened true; out=$(eff)
  have() { echo "$out" | grep -qx "$1" && echo ja || echo nein; }
  check "trotz gegenteiliger Hauptdatei und spaeterem Drop-in: PermitRootLogin no"        "ja" "$(have 'permitrootlogin no')"
  check "X11Forwarding no"                                                                "ja" "$(have 'x11forwarding no')"
  check "ClientAliveInterval 300 / CountMax 2"                                            "ja" "$( (echo "$out" | grep -qx 'clientaliveinterval 300' && echo "$out" | grep -qx 'clientalivecountmax 2') && echo ja || echo nein)"
  check "Passwort-Login aus (PasswordAuthentication + KbdInteractiveAuthentication)"      "ja" "$( (echo "$out" | grep -qx 'passwordauthentication no' && echo "$out" | grep -qx 'kbdinteractiveauthentication no') && echo ja || echo nein)"
  hardened false; out=$(eff)
  check "camdisplay_ssh_disable_password_auth=false: Passwort-Login bleibt unangetastet" "ja" "$( (echo "$out" | grep -qx 'passwordauthentication yes' && echo "$out" | grep -qx 'permitrootlogin no') && echo ja || echo nein)"
  # Gegenprobe: steht der Include am ENDE der Hauptdatei, gewinnen die frueheren Werte -
  # genau diesen Fall soll die Wirksamkeitspruefung im Playbook (sshd -T) erkennen.
  hardened true
  printf 'HostKey %s/hostkey\nPermitRootLogin yes\nInclude %s/conf.d/*.conf\n' "$S" "$S" > "$S/sshd_config"; out=$(eff)
  check "Gegenprobe: Include am Ende -> Haertung wird UEBERSTIMMT und ist in sshd -T sichtbar" "nein" "$(have 'permitrootlogin no')"
fi

# ----------------------------------------------- Vorpruefung gegen Aussperren
echo "== Vorpruefung: Key-Login vorhanden? (echte Tasks) =="
extract "$A/tasks/hardening.yml" "Vorpruefung fuer" "SSH-Haertung als Drop-in" > "$WORK/precheck.yml"
me=$(id -un)
printf -- '- hosts: localhost\n  connection: local\n  gather_facts: no\n  vars:\n    ansible_user: %s\n    camdisplay_ssh_disable_password_auth: true\n  tasks:\n    - import_tasks: precheck.yml\n' "$me" > "$WORK/pre_pb.yml"
: > "$WORK/empty_keys"; echo "ssh-ed25519 AAAA test" > "$WORK/full_keys"
pre() { (cd "$WORK" && play pre_pb.yml "$@"); }
check "kein authorized_keys vorhanden -> Abbruch"        "nonzero" "$([ "$(pre -e "camdisplay_ssh_authorized_keys_path=$WORK/gibt_es_nicht")" -ne 0 ] && echo nonzero || echo zero)"
check "authorized_keys leer -> Abbruch"                  "nonzero" "$([ "$(pre -e "camdisplay_ssh_authorized_keys_path=$WORK/empty_keys")" -ne 0 ] && echo nonzero || echo zero)"
check "authorized_keys mit Key -> weiter"                "zero"    "$([ "$(pre -e "camdisplay_ssh_authorized_keys_path=$WORK/full_keys")" -ne 0 ] && echo nonzero || echo zero)"
check "Ansible verbindet per Passwort -> Abbruch"        "nonzero" "$([ "$(pre -e "camdisplay_ssh_authorized_keys_path=$WORK/full_keys" -e ansible_password=x)" -ne 0 ] && echo nonzero || echo zero)"
check "Passwort-Login bleibt an: keine Vorpruefung noetig" "zero"  "$([ "$(pre -e "camdisplay_ssh_authorized_keys_path=$WORK/gibt_es_nicht" -e camdisplay_ssh_disable_password_auth=false)" -ne 0 ] && echo nonzero || echo zero)"
pre >/dev/null 2>&1; home=$(getent passwd "$me" | cut -d: -f6)
if [ -f "$home/.ssh/authorized_keys" ]; then
  check "ohne Pfadangabe: authorized_keys aus dem Home des Ansible-Users" "zero" "$([ "$(pre)" -ne 0 ] && echo nonzero || echo zero)"
else skip "Standardpfad ~/.ssh/authorized_keys" "auf diesem Rechner keine authorized_keys vorhanden"; fi

# ------------------------------------- ungenutzte Dienste: fehlende Units ok
echo "== avahi/Bluetooth: fehlende Unit ist kein Fehler, echte Fehler schon =="
extract "$A/tasks/hardening.yml" "avahi \\(mDNS\\) und Bluetooth" "Vorpruefung fuer" > "$WORK/units.yml"
sed -e 's/avahi-daemon.service/camdisplay-test-fehlt-1.service/; s/avahi-daemon.socket/camdisplay-test-fehlt-2.socket/; s/bluetooth.service/camdisplay-test-fehlt-3.service/' "$WORK/units.yml" > "$WORK/units_missing.yml"
printf -- '- hosts: localhost\n  connection: local\n  gather_facts: no\n  tasks:\n    - import_tasks: %s\n' "$WORK/units_missing.yml" > "$WORK/units_pb.yml"
if ! command -v systemctl >/dev/null 2>&1 || ! systemctl list-units >/dev/null 2>&1; then
  skip "fehlende Units" "kein laufendes systemd"
else
  check "nicht vorhandene Units: Task laeuft durch" "0" "$(play "$WORK/units_pb.yml")"
  if [ "$(id -u)" -eq 0 ]; then skip "echter Fehler wird NICHT verschluckt" "als root nicht pruefbar (wuerde wirklich maskieren)"
  else
    sed -e 's/avahi-daemon.service/systemd-journald.service/; /avahi-daemon.socket/d; /bluetooth.service/d' "$WORK/units.yml" > "$WORK/units_real.yml"
    printf -- '- hosts: localhost\n  connection: local\n  gather_facts: no\n  tasks:\n    - import_tasks: %s\n' "$WORK/units_real.yml" > "$WORK/units_pb2.yml"
    rc=$(play "$WORK/units_pb2.yml")
    check "echter Fehler (vorhandene Unit, keine Rechte) wird NICHT verschluckt" "nonzero" "$([ "$rc" -ne 0 ] && echo nonzero || echo zero)"
  fi
fi

# --------------------------------------------------------------- Watchdog
echo "== Hardware-Watchdog =="
W="$A/tasks/watchdog.yml"
render "$A/templates/watchdog.conf.j2" "$WORK/wd.conf" '{"camdisplay_watchdog_sec": 10}'
check "Drop-in: RuntimeWatchdogSec=10 und RebootWatchdogSec=2min" "RuntimeWatchdogSec=10 RebootWatchdogSec=2min" "$(grep -E '^(RuntimeWatchdogSec|RebootWatchdogSec)=' "$WORK/wd.conf" | paste -sd' ')"
render "$A/templates/watchdog.conf.j2" "$WORK/wd.conf" '{"camdisplay_watchdog_sec": 12}'
check "Drop-in folgt camdisplay_watchdog_sec" "RuntimeWatchdogSec=12" "$(grep -E '^RuntimeWatchdogSec=' "$WORK/wd.conf")"

# einzelne Tasks aus watchdog.yml (auch die verschachtelten) als Mini-Playbook herausziehen
wd_task() { # task-name-praefix vars-json -> Exit-Code des Mini-Playbooks (Ausgabe in play.log)
  python3 - "$W" "$1" "$2" "$WORK/wd_pb.yml" <<'EOF'
import sys, json, yaml
src, prefix, vars_json, out = sys.argv[1:5]
def walk(tasks):
    for t in tasks:
        if str(t.get('name', '')).startswith(prefix): return t
        for key in ('block', 'rescue', 'always'):
            if key in t:
                r = walk(t[key])
                if r: return r
task = walk(yaml.safe_load(open(src)))
assert task, prefix
pb = [{'hosts': 'localhost', 'connection': 'local', 'gather_facts': False, 'vars': json.loads(vars_json), 'tasks': [task]}]
yaml.safe_dump(pb, open(out, 'w'))
EOF
  play "$WORK/wd_pb.yml"
}
for v in 2 10 15; do check "Timeout $v s ist zulaessig" "0" "$(wd_task 'Watchdog-Timeout pruefen' "{\"camdisplay_watchdog_sec\": $v}")"; done
for v in 0 1 16 60; do check "Timeout $v s wird abgelehnt (Pi kann hoechstens ca. 15 s)" "nonzero" "$([ "$(wd_task 'Watchdog-Timeout pruefen' "{\"camdisplay_watchdog_sec\": $v}")" -ne 0 ] && echo nonzero || echo zero)"; done
check "Timeout 'abc' wird abgelehnt" "nonzero" "$([ "$(wd_task 'Watchdog-Timeout pruefen' '{"camdisplay_watchdog_sec": "abc"}')" -ne 0 ] && echo nonzero || echo zero)"
warned() { wd_task 'Warnung, falls' "{\"camdisplay_watchdog_sec\": 10, \"camdisplay_watchdog_effective\": {\"stdout\": \"$1\"}}" >/dev/null; grep -q 'RuntimeWatchdogUSec ist' "$WORK/play.log" && echo ja || echo nein; }
check "systemctl meldet '10s': keine Warnung"            "nein" "$(warned '10s')"
check "systemctl meldet '10000000': keine Warnung"       "nein" "$(warned '10000000')"
check "systemctl meldet '0' (Watchdog aus): Warnung"     "ja"   "$(warned '0')"
check "systemctl meldet '' (leer): Warnung"              "ja"   "$(warned '')"
check "systemctl meldet '5s' (anderer Wert): Warnung"    "ja"   "$(warned '5s')"
if [ -e /dev/watchdog ]; then skip "Ablauf ohne /dev/watchdog" "auf diesem Rechner existiert /dev/watchdog"
else
  printf -- '- hosts: localhost\n  connection: local\n  gather_facts: no\n  vars:\n    camdisplay_watchdog_sec: 10\n  tasks:\n    - import_tasks: %s\n' "$W" > "$WORK/wd_full.yml"
  rc=$(play "$WORK/wd_full.yml")
  check "ohne /dev/watchdog: Hinweis, nichts wird angefasst, Lauf endet erfolgreich" "0/ja" "$rc/$(grep -q 'wird nicht eingerichtet' "$WORK/play.log" && echo ja || echo nein)"
fi

echo
echo "Ergebnis: $pass ok, $fail Fehler, $skipped uebersprungen"
[ "$fail" -eq 0 ]
