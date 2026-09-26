# CamDisplay

![Built with AI](https://img.shields.io/badge/Built_with-AI-success)

Fullscreen kiosk display for a live camera stream (RTSP/RTMP) on a Raspberry Pi. Built for unattended, always-on operation: boots straight into the stream with no desktop or login step, restarts automatically if the stream drops, and reboots the device after repeated failures — quickly for local problems, only after a few minutes of patience if the camera itself is unreachable.

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
- A dedicated, unprivileged service user (in the `video` and `render` groups for `/dev/dri` access, no login shell, no sudo) — don't run `ffplay` as whatever account has SSH/sudo access; a compromised `ffplay` (e.g. via a malformed-stream decoder bug) shouldn't have a path to root

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
User=camdisplay
SupplementaryGroups=video render
Environment=SDL_VIDEODRIVER=kmsdrm
EnvironmentFile=/etc/camdisplay/stream.env
ExecStart=/usr/local/bin/camdisplay-run
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
```

`/usr/local/bin/camdisplay-run` ([`camdisplay-run.sh`](systemd/camdisplay-run.sh)) is a small wrapper that starts `ffplay` and masks credentials in its error output before it reaches the journal (see [Credentials](#credentials)). The flags it uses, and why:

| Flag | Why |
|---|---|
| `-autoexit` | Exit when the stream ends. Without it `ffplay` stays open on the last frame, so neither `Restart=always` nor the reboot guard ever fires and the display just freezes. |
| `-rw_timeout 5000000` | Socket I/O timeout in µs: exit if the connection hangs without a clean end (camera or switch gone). Measured with ffmpeg 6.1: `ffplay` exits after roughly 3× this value (~15 s). **Don't use `-timeout` instead** — for RTMP that option means "wait for an *incoming* connection" and turns `ffplay` into a server. |
| `-fflags +nobuffer` | Low latency. The `+` matters: `-nobuffer` *clears* the flag. |
| `-flags low_delay -framedrop` | Low-latency decoding; drop frames rather than fall behind. |
| `-analyzeduration 1` | Minimal stream analysis at startup. |
| `-an -nostats -loglevel error` | No audio, quiet output. |

`ffplay` also exits with status 0 when it can't connect, so the unit uses `Restart=always` (not `on-failure`). For RTSP sources add `STREAM_OPTS="-rtsp_transport tcp"` to `stream.env` (below) — it is deliberately not built in, because `ffplay` aborts on options the input doesn't know (`Option rtsp_transport not found`), which would kill the display for RTMP URLs. The freeze-detection timeout was verified with RTMP only, not with a real RTSP source.

`/etc/systemd/system/camdisplay-reboot.service` — triggered automatically once systemd gives up restarting (`StartLimitBurst` exceeded within `StartLimitIntervalSec`):

```ini
[Unit]
Description=Reboot after repeated CamDisplay failures (with a total-attempts cap)

[Service]
Type=oneshot
ExecStart=/root/bin/camdisplay-reboot-guard.sh
```

Plain `ExecStart=/sbin/reboot` would work but is a poor watchdog: it reboots forever on a *persistent* failure, and it reboots immediately when the camera is merely unreachable, which is usually over in a few minutes and would burn through any reboot budget. [`camdisplay-reboot-guard.sh`](systemd/camdisplay-reboot-guard.sh) decides instead:

- **Camera not reachable** (TCP probe to the host/port from `STREAM_URL`): be patient first — no reboot, nothing written to the boot partition, the service is started again after 2 minutes. A camera restart, firmware update or switch reboot is usually over by then.
- **Still unreachable after 3 attempts in a row** (≈ 9 minutes; the attempt counter lives in `/run` and starts over after every boot): reboot anyway. Waiting doesn't fix problems on the Pi's side (lost DHCP lease, hung network stack, changed infrastructure); a reboot rebuilds all of that.
- **Camera reachable but `ffplay` keeps failing**: reboot right away.
- **Reboot limit reached** (5 in total, shared by the two rules above): no further reboot — this stops a reboot loop on a persistent fault and limits writes to the boot partition — but also not switched off for good: the same slow retry every 2 minutes, so the display comes back once the cause is gone.

If the target can't be derived from the URL (e.g. `udp://`), the probe is skipped and the third rule applies. [`camdisplay-reboot-count-reset.timer`](systemd/camdisplay-reboot-count-reset.timer) checks every 5 minutes and clears the counters once `camdisplay.service` has been running without interruption for at least 5 minutes. Both scripts work whether or not the boot partition is mounted read-only (see [Storage hardening](#storage-hardening-optional) below), and they abort without rebooting if the reboot counter can't be persisted (e.g. a failed remount) rather than risk an uncapped reboot loop. The counter file is read defensively, since a power cut can leave a corrupt file on the FAT boot partition.

`/etc/camdisplay/stream.env` (mode `600` — keep this out of version control, it holds credentials):

```bash
STREAM_URL="rtsp://user:pass@camera-host:554/stream"
# optional, extra ffplay options — e.g. for RTSP:
#STREAM_OPTS="-rtsp_transport tcp"
```

### Setup

```bash
sudo apt install ffmpeg libegl1 libegl-mesa0
sudo useradd --system --shell /usr/sbin/nologin --no-create-home camdisplay
sudo usermod -aG video,render camdisplay

sudo mkdir -p /etc/camdisplay
sudo cp stream.env.example /etc/camdisplay/stream.env
sudo chmod 600 /etc/camdisplay/stream.env
sudo "$EDITOR" /etc/camdisplay/stream.env   # set STREAM_URL

sudo install -m 755 systemd/camdisplay-run.sh /usr/local/bin/camdisplay-run

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

### Credentials

The camera URL usually contains credentials, and `ffplay` needs it as a command-line argument. What that means:

- **Mitigated:** `stream.env` is mode `600`; the service runs as an unprivileged user; `camdisplay-run` masks the URL and credential-looking parts (`user:pass@`, `password=`, `token=`, ...) in `ffplay`'s error output, so they don't end up in the journal (`ffplay` prints the full URL on every connection error).
- **Not avoidable with `ffplay`:** the URL stays visible in the process command line (`ps`, `/proc/<pid>/cmdline`, and the process list in `systemctl status`) to every local user. Mind this when pasting `systemctl status` output somewhere. A local relay (e.g. MediaMTX or go2rtc on `127.0.0.1`, doing the camera login itself) would remove it, at the price of another component.
- **Recommended:** create a **read-only viewer account** on the camera for this display, so a leaked URL only allows watching the stream.
- Mounting `/proc` with `hidepid=2` hides other users' processes, but can interfere with other system services; it is not set up here and not tested with this setup.

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
CAMERA_HOST="camera-host"    # for the reachability check below
CAMERA_PORT=554
MAX_ERRORS=6
LOGFILE="$(dirname "$0")/play_it.log"

ERRORCOUNTER=0

while true; do
    # same flags as Setup A (see the table there); add -rtsp_transport tcp for RTSP
    ffplay -autoexit -rw_timeout 5000000 -fs -analyzeduration 1 \
        -fflags +nobuffer -flags low_delay -framedrop -an -nostats -loglevel error \
        "$STREAM_URL" >> "$LOGFILE" 2>&1

    # Only count failures while the camera is reachable: rebooting the Pi does
    # not fix a camera/network outage (and would loop forever during one).
    if timeout 3 bash -c 'exec 3<>"/dev/tcp/$0/$1"' "$CAMERA_HOST" "$CAMERA_PORT" 2>/dev/null; then
        ERRORCOUNTER=$((ERRORCOUNTER + 1))
        echo "$(date): stream stopped (attempt ${ERRORCOUNTER})" >> "$LOGFILE"

        if [ "${ERRORCOUNTER}" -ge "${MAX_ERRORS}" ]; then
            echo "$(date): too many failures, rebooting" >> "$LOGFILE"
            sudo reboot
        fi
    else
        echo "$(date): camera unreachable, retrying" >> "$LOGFILE"
    fi

    sleep 10
done
```

Unlike Setup A this has no cap on the number of reboots. `ffplay` writes the full URL, credentials included, to the log file on connection errors — keep the log readable only by the display user and see [Credentials](#credentials).

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
| `STREAM_OPTS`  | Optional extra `ffplay` options (e.g. `-rtsp_transport tcp` for RTSP) |
| `MAX_ERRORS` / `StartLimitBurst` | Consecutive failures within `StartLimitIntervalSec` before the device reboots |
| `MAX_REBOOTS` (in `camdisplay-reboot-guard.sh`) | Total reboots (default 5); afterwards only slow retries, no more reboots |
| `UNREACHABLE_ATTEMPTS` (in `camdisplay-reboot-guard.sh`) | Failed start bursts with the camera unreachable (default 3, ≈ 9 min) before rebooting anyway |
| `RETRY_DELAY` (in `camdisplay-reboot-guard.sh`) | Seconds (default 120) between restart attempts without a reboot |
| `ffplay` flags | See the table under [Setup A → Files](#files) (set in `camdisplay-run.sh`) |

## License

[MIT](LICENSE)
