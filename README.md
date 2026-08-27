# CamDisplay

Fullscreen kiosk display for a live camera stream (RTSP/RTMP) on a Raspberry Pi. Built for unattended, always-on operation: boots straight into the stream with no desktop or login step, restarts automatically if the stream drops, and reboots the device after repeated consecutive failures.

Designed with power-loss resilience in mind — the device is assumed to be switched on/off via a hard power cut rather than a clean shutdown, so the moving parts are kept minimal.

The player is [`ffplay`](https://ffmpeg.org/ffplay.html) (part of ffmpeg) — lightweight, stateless, and near-instant to restart, which makes it well suited to unattended kiosk displays.

Two setups are documented here:

- **systemd + KMS/DRM** (recommended) — no X server at all, `ffplay` draws directly to the screen. Needs a Linux kernel with a working KMS driver (default on Raspberry Pi OS Bullseye/Bookworm/Trixie on Pi 4 and newer) and an SDL2 build with `kmsdrm` support (Debian/Raspberry Pi OS packages have this; some older vendor-specific SDL2 builds don't — check with `strings $(ldd $(which ffplay) | grep -o '/\S*libSDL2\S*') | grep kmsdrm` before relying on it).
- **X11 + autologin** (fallback) — for older boards or setups where a working KMS driver isn't available. Slightly more moving parts, but a well-proven, simple setup.

## Automated setup (Ansible)

The [`ansible/`](ansible/) directory has a complete, tested install/maintenance playbook for Setup A (systemd + KMS/DRM), including:

- `install.yml` — fresh install: packages, the systemd units below, and (optionally) a read-only root filesystem for power-loss resilience
- `maintain.yml` — safely applies OS updates even with a read-only root filesystem active
- `/root/bin/camdisplay-writable.sh` / `camdisplay-update.sh` — manual maintenance scripts for when Ansible access isn't available

```bash
cd ansible
cp inventory.yml.dist inventory.yml   # fill in your host(s) and stream_url
ansible-playbook -i inventory.yml install.yml --limit <host>

# optional, once you've confirmed the display works: read-only root FS
ansible-playbook -i inventory.yml install.yml --limit <host> -e camdisplay_enable_overlay=true
```

See [`ansible/README.md`](ansible/README.md) for details. The rest of this document explains the underlying setup manually, for anyone not using Ansible.

---

## Setup A: systemd + KMS/DRM (recommended)

No desktop, no X server, no login — `ffplay` renders straight to the framebuffer via SDL's `kmsdrm` backend, supervised by systemd.

### Requirements

- Raspberry Pi 4 or newer (or any SBC with a mainline KMS driver)
- `ffmpeg` (provides `ffplay`), built with SDL2 `kmsdrm` support (default in Debian/Raspberry Pi OS packages)
- `libegl1` and `libegl-mesa0` — **not** pulled in automatically by `ffmpeg`; without them `ffplay` fails with `Failed to create window: EGL not initialized`
- The service user must be in the `video` and `render` groups for `/dev/dri` access

### Files

`/etc/systemd/system/camdisplay.service`:

```ini
[Unit]
Description=CamDisplay - fullscreen camera stream
After=network-online.target
Wants=network-online.target
StartLimitIntervalSec=600
StartLimitBurst=6
OnFailure=camdisplay-reboot.service

[Service]
Type=simple
User=pi
SupplementaryGroups=video render
Environment=SDL_VIDEODRIVER=kmsdrm
EnvironmentFile=/etc/camdisplay/stream.env
ExecStart=/usr/bin/ffplay -fs -analyzeduration 1 -fflags -nobuffer -an -nostats -loglevel error "${STREAM_URL}"
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
```

`/etc/systemd/system/camdisplay-reboot.service` — triggered automatically once systemd gives up restarting (`StartLimitBurst` exceeded within `StartLimitIntervalSec`), reproducing a "reboot after N consecutive failures" watchdog without any custom scripting:

```ini
[Unit]
Description=Reboot after repeated CamDisplay failures (with a total-attempts cap)

[Service]
Type=oneshot
ExecStart=/root/bin/camdisplay-reboot-guard.sh
```

Plain `ExecStart=/sbin/reboot` works too, but has no upper bound: if the failure is *persistent* (a missing dependency, a bad config) rather than transient (a network blip), the device reboots forever. [`camdisplay-reboot-guard.sh`](systemd/camdisplay-reboot-guard.sh) caps this at a configurable number of reboots (default 5) and then disables the service instead of rebooting again, leaving the device reachable for a fix. [`camdisplay-reboot-count-reset.timer`](systemd/camdisplay-reboot-count-reset.timer) resets the counter a few minutes after a boot that stays up, so a later, unrelated failure gets the full budget again. Both scripts are careful to work whether or not the boot partition is mounted read-only (see [Storage hardening](#storage-hardening-optional) below).

`/etc/camdisplay/stream.env` (mode `600` — keep this out of version control, it holds credentials):

```bash
STREAM_URL="rtsp://user:pass@camera-host:554/stream"
```

### Setup

```bash
sudo apt install ffmpeg libegl1 libegl-mesa0
sudo usermod -aG video,render pi

sudo mkdir -p /etc/camdisplay
sudo cp stream.env.example /etc/camdisplay/stream.env
sudo chmod 600 /etc/camdisplay/stream.env
sudo "$EDITOR" /etc/camdisplay/stream.env   # set STREAM_URL

sudo mkdir -p /root/bin
sudo cp systemd/camdisplay-reboot-guard.sh systemd/camdisplay-reboot-count-reset.sh /root/bin/
sudo chmod 700 /root/bin/camdisplay-reboot-guard.sh /root/bin/camdisplay-reboot-count-reset.sh

sudo cp systemd/camdisplay.service systemd/camdisplay-reboot.service \
        systemd/camdisplay-reboot-count-reset.service systemd/camdisplay-reboot-count-reset.timer \
        /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now camdisplay.service camdisplay-reboot-count-reset.timer
```

Example files for the above are in [`systemd/`](systemd/) and [`stream.env.example`](stream.env.example).

### Storage hardening (optional)

Since the device is expected to be power-cycled without a clean shutdown, it's worth making the root filesystem (and boot partition) read-only, so an unlucky power cut can't corrupt them. Raspberry Pi OS has this built in via `raspi-config`:

```bash
sudo raspi-config nonint enable_bootro     # boot partition read-only - do this FIRST
sudo raspi-config nonint enable_overlayfs  # root filesystem read-only (tmpfs overlay)
sudo reboot
```

`enable_bootro` must run *before* `enable_overlayfs` — `raspi-config` refuses to touch `/etc/fstab` while the root overlay is already live (editing it would only land in the volatile overlay and vanish on reboot). The Ansible playbook (`camdisplay_enable_overlay=true`) does this in the right order automatically.

With both active, nothing on disk changes at runtime — updates need a small dance to temporarily lift the read-only state, apply them, and lock it back down. [`camdisplay-writable.sh`](systemd/camdisplay-writable.sh) (manual config edits) and [`camdisplay-update.sh`](systemd/camdisplay-update.sh) (apt upgrades) handle that; drop them in `/root/bin/` for when Ansible access isn't available. Their state files deliberately live on the boot partition (never covered by the root overlay) so they survive the reboot in the middle of the process.

---

## Setup B: X11 + autologin (fallback)

A minimal X session (no desktop environment) auto-starts a watchdog script that runs `ffplay` in a loop.

### Requirements

- Raspberry Pi (or any Linux SBC) with a display attached
- `ffmpeg` (provides `ffplay`)
- A minimal X11 setup: a lightweight window manager (e.g. `matchbox-window-manager`) plus an autologin mechanism (e.g. `nodm`)

### Watchdog script

```bash
#!/bin/bash

STREAM_URL="rtsp://user:pass@camera-host:554/stream"
MAX_ERRORS=6
LOGFILE="$(dirname "$0")/play_it.log"

ERRORCOUNTER=0

while true; do
    ffplay -fs -analyzeduration 1 -fflags -nobuffer -an -nostats "$STREAM_URL" \
        >> "$LOGFILE" 2>&1

    ERRORCOUNTER=$((ERRORCOUNTER + 1))
    echo "$(date): stream stopped (attempt ${ERRORCOUNTER})" >> "$LOGFILE"

    if [ "${ERRORCOUNTER}" -ge "${MAX_ERRORS}" ]; then
        echo "$(date): too many failures, rebooting" >> "$LOGFILE"
        sudo reboot
    fi

    sleep 10
done
```

### Setup

1. Install dependencies:
   ```bash
   sudo apt install ffmpeg matchbox nodm
   ```
2. Configure `nodm` for autologin into a minimal X session.
3. Point the X session at the watchdog script (e.g. via `~/.xsession`):
   ```bash
   #!/usr/bin/env bash
   xset s off -dpms &
   exec matchbox-window-manager &
   /home/pi/play_it
   ```
4. Set the stream URL and fullscreen options in the watchdog script above to match your camera.

---

## Configuration reference

| Setting        | Description                                      |
|----------------|---------------------------------------------------|
| `STREAM_URL`   | RTSP or RTMP URL of the camera stream              |
| `MAX_ERRORS` / `StartLimitBurst` | Consecutive failures within `StartLimitIntervalSec` before the device reboots |
| `MAX_REBOOTS` (in `camdisplay-reboot-guard.sh`) | Total reboots (default 5) before giving up and disabling the service instead of rebooting forever |
| `ffplay` flags | `-fs` fullscreen, `-fflags -nobuffer` low latency, `-an` no audio, `-nostats`/`-loglevel error` quiet output |

## License

TODO
