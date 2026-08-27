# CamDisplay Ansible

Install and maintenance playbooks for Setup A (systemd + KMS/DRM) from the [top-level README](../README.md). Fresh Raspberry Pi OS Lite (64-bit), Pi 4 or newer.

## Setup

```bash
cp inventory.yml.dist inventory.yml
```

Edit `inventory.yml` (gitignored — holds real hostnames/credentials) with your host(s):

```yaml
camdisplay:
  vars:
    ansible_python_interpreter: /usr/bin/python3
  hosts:
    camdisplay1.example.lan:
      ansible_host: 192.0.2.10
      ansible_user: pi
      stream_url: "rtsp://user:pass@camera-host:554/stream"
```

`ansible_user` needs passwordless `sudo` on the target.

## Install

```bash
ansible-playbook -i inventory.yml install.yml --limit <host>
```

Installs `ffmpeg` + `libegl1`/`libegl-mesa0`, deploys `camdisplay.service` and the reboot-guard units, and copies the manual maintenance scripts to `/root/bin/`.

### Read-only root filesystem

Once you've confirmed the display works, harden it against unclean power-offs:

```bash
ansible-playbook -i inventory.yml install.yml --limit <host> -e camdisplay_enable_overlay=true
```

Enables `bootro` (read-only boot partition) and the root overlay together, in the order `raspi-config` requires (`bootro` first — it refuses to touch `/etc/fstab` once the overlay is already live). Triggers one reboot.

If a host already has the overlay active and you need to add `bootro` afterwards, `raspi-config` can no longer do it in one step — run `camdisplay-writable.sh rw` (reboot), then `camdisplay-writable.sh ro` (reboot) on the host directly instead (see `tasks/overlay.yml` for why).

## Maintain

```bash
ansible-playbook -i inventory.yml maintain.yml --limit <host>
```

Applies OS updates. Safe with a read-only root filesystem active — drives the same overlay/bootro-aware sequence as `camdisplay-update.sh` (temporarily lift read-only, `apt full-upgrade`, restore, reboot) rather than a plain `apt upgrade`, which would silently do nothing useful under an active overlay.

## Verifying the display headlessly (screenshot)

Since there's no X server, ordinary screenshot tools don't work — but `ffmpeg`'s `kmsgrab` input reads the composited framebuffer directly from the kernel, so you can grab exactly what's on screen over SSH. `install.yml` deploys [`camdisplay-screenshot.sh`](files/camdisplay-screenshot.sh) to `/root/bin/` for this:

```bash
sudo /root/bin/camdisplay-screenshot.sh              # writes to /tmp/camdisplay-screenshot-<timestamp>.png, prints the path
sudo /root/bin/camdisplay-screenshot.sh /tmp/out.png  # or pick the path yourself
```

Useful for an automated sanity check: grab a frame this way and diff/compare it against a frame pulled directly from the camera at roughly the same time, without needing a physical monitor or human eyes on the device.

The script auto-detects both things that are easy to get wrong doing this by hand:

- **Which `/dev/dri/cardN`** — scans `/sys/class/drm/card*-*/status` for a `connected` connector rather than assuming `card0`. Works the same regardless of which of the Pi 4's two HDMI ports the monitor is actually plugged into (both are exposed as connectors on the same card).
- **The pixel format for `hwdownload`** — must match the framebuffer's *real* format, not just any RGBA-ish guess; a mismatch fails immediately and clearly (`Invalid output format ... for hwframe download`), so this is auto-probed via `ffmpeg -v verbose ... | grep 'Format is'` rather than hardcoded (it was `bgra` on the test hardware, but that isn't guaranteed elsewhere). A second `format=rgba` conversion follows, since the PNG encoder doesn't accept `bgra` directly.

Note that `camdisplay.service` itself picks its output connector the same way, but only *at startup* — moving the monitor cable to the other HDMI port while it's already running doesn't retarget the running `ffplay`; `systemctl restart camdisplay.service` (or a reboot) is needed to pick up the change.

## Layout

| Path | Purpose |
|---|---|
| `install.yml` / `maintain.yml` | Entry-point playbooks |
| `tasks/base.yml` | Packages, groups, timezone, WiFi removal/disable |
| `tasks/maintenance_scripts.yml` | Deploys the `/root/bin/` scripts |
| `tasks/overlay.yml` | Read-only root FS + boot partition (see above) |
| `tasks/kiosk_service.yml` | `stream.env`, systemd units, service start |
| `templates/` | Jinja2 templates for the systemd units and `stream.env` |
| `files/` | Static files (the maintenance scripts) copied as-is |

## Notes

- `stream_url` holds camera credentials — keep `inventory.yml` out of version control (already gitignored).
- The maintenance scripts (`camdisplay-update.sh`, `camdisplay-writable.sh`) implement the overlay/bootro reboot dance described above; `tasks/overlay.yml` covers the same mechanism during install.
- Task ordering in `install.yml` matters: anything that can trigger a reboot runs *before* `kiosk_service.yml` starts the service, so it never starts into a stale environment and runs into the reboot-guard's failure counter needlessly.
