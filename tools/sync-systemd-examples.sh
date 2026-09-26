#!/bin/bash
# Erzeugt die Beispieldateien unter systemd/ aus den Ansible-Quellen.
#
# Einzige Quelle ist ansible/ (files/*.sh und templates/*.j2) - systemd/ wird
# NICHT von Hand gepflegt. Von Hand gepflegte Kopien sind auseinandergelaufen
# (die Beispiel-Unit lief noch als User=pi, obwohl README und Template den
# unprivilegierten Service-User nutzten). tests/run-tests.sh (und damit die CI)
# schlaegt fehl, wenn systemd/ nicht dem entspricht, was dieses Skript erzeugt.
#
# Aufruf:  tools/sync-systemd-examples.sh [Zielverzeichnis]   (Standard: systemd/)

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
OUT="${1:-$ROOT/systemd}"
mkdir -p "$OUT"

for f in "$ROOT"/ansible/files/*.sh; do
  cp "$f" "$OUT/$(basename "$f")"
done

# Units: einzige Jinja-Variable ist der Service-User (Standardwert "camdisplay")
for u in camdisplay.service camdisplay-reboot.service camdisplay-reboot-count-reset.service camdisplay-reboot-count-reset.timer; do
  sed 's/{{ camdisplay_service_user }}/camdisplay/g' "$ROOT/ansible/templates/$u.j2" > "$OUT/$u"
done

echo "Beispieldateien erzeugt in: $OUT"
exit 0
