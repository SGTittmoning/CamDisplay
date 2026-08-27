#!/bin/bash
# Erzeugt einen Screenshot des tatsächlich angezeigten Bildes per kmsgrab -
# funktioniert ohne X11, ohne angeschlossenen Monitor am Bedienrechner, rein
# ueber SSH. Erkennt DRM-Geraet und Pixelformat automatisch, damit es
# unabhaengig davon funktioniert welcher der beiden HDMI-Ports (Pi 4 hat
# zwei) tatsaechlich genutzt wird oder welches /dev/dri/cardN das ist.
#
# Nutzung:
#   sudo camdisplay-screenshot.sh [Zielpfad]
# Ohne Zielpfad wird eine Datei mit Zeitstempel unter /tmp abgelegt und der
# Pfad auf stdout ausgegeben.

set -euo pipefail

require_root() {
  if [ "$(id -u)" -ne 0 ]; then
    echo "Bitte mit sudo ausfuehren." >&2
    exit 1
  fi
}
require_root

OUT="${1:-/tmp/camdisplay-screenshot-$(date +%Y%m%d-%H%M%S).png}"

# DRM-Geraet mit einem tatsaechlich verbundenen Connector finden (nicht
# hartkodiert auf card0/card1 - welches Geraet das ist, kann je nach
# Hardware/Treiber variieren).
DEV=""
for status_file in /sys/class/drm/card*-*/status; do
  if [ "$(cat "$status_file" 2>/dev/null)" = "connected" ]; then
    card_name=$(basename "$(dirname "$status_file")")
    card_num=$(echo "$card_name" | grep -oP '^card\K[0-9]+')
    DEV="/dev/dri/card${card_num}"
    break
  fi
done

if [ -z "$DEV" ]; then
  echo "Kein verbundener DRM-Connector gefunden (kein Monitor angeschlossen?)." >&2
  exit 1
fi

# Tatsaechliches Pixelformat des Framebuffers ermitteln (nicht raten - siehe
# ansible/README.md fuer den Hintergrund, warum das noetig ist).
FMT=$(ffmpeg -v verbose -f kmsgrab -device "$DEV" -i - -frames:v 1 -f null - 2>&1 \
  | grep -oP 'Format is \K\w+' | head -1)

if [ -z "$FMT" ]; then
  echo "Konnte Pixelformat nicht ermitteln (Geraet: $DEV)." >&2
  exit 1
fi

ffmpeg -y -loglevel error -f kmsgrab -device "$DEV" -i - -update 1 -frames:v 1 \
  -vf "hwdownload,format=${FMT},format=rgba" "$OUT"

echo "$OUT"
