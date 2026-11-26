# Elecrow 7" HDMI display on Jetson AGX Thor

This lets a Jetson AGX Thor (JetPack desktop image, GDM, NVIDIA X driver) use an
**Elecrow 7" 1024×600 HDMI LCD** while keeping the **original display settings** for
everything else. Normal monitors on HDMI or DisplayPort work exactly as before. The
Elecrow settings are only *added* when nothing is detected on HDMI.

## The problem

The Elecrow 7" is designed for the Raspberry Pi. It doesn't send the HDMI **hotplug**
signal or its **EDID**, the data that tells the computer what monitor it is and which
resolutions it supports. The NVIDIA driver therefore sees nothing on HDMI and never turns
the port on, so the screen stays black.

The fix is to tell the X driver that HDMI is connected and give it an EDID for the panel.
Doing that permanently would break normal monitors: they would get the Elecrow's
1024×600 mode and show "resolution / frame rate not supported". So the fix is applied
only when needed.

> Note: on the Thor, the kernel's `/sys/class/drm/*/status` showed `disconnected` for
> every port in testing, so it isn't used for detection. This tool uses what the NVIDIA X driver detects, read from `/var/log/Xorg.0.log`.

## How it works

```
boot
 ├─ elecrow-display.service        (before GDM)  original xorg.conf is restored
 ├─ GDM starts X → NVIDIA driver detects displays
 └─ elecrow-display-check.service  (after GDM)   reads /var/log/Xorg.0.log
       ├─ monitor detected on HDMI   → nothing changes (original settings)
       └─ nothing detected on HDMI   → Elecrow settings added to xorg.conf,
          (Elecrow, or empty port)     any detected DP monitors kept,
                                       GDM restarted once (~5 s)
```

With the Elecrow, the login screen therefore appears after one short restart.

The settings that get added (between marker comments in the `Device` section of
`/etc/X11/xorg.conf`):

```
# >>> elecrow-display (managed by setup-elecrow-display.sh)
Option "ConnectedMonitor" "DFP-1, DFP-0"                         # HDMI + monitors X detected (e.g. DP)
Option "CustomEDID"       "DFP-1:/etc/X11/elecrow-1024x600.bin"  # Elecrow EDID, HDMI only
Option "ModeValidation"   "AllowNonEdidModes"
# <<< elecrow-display
```

`ConnectedMonitor` makes the driver use **only** the outputs it lists. That's why every
monitor X detected (for example on DisplayPort) is added next to HDMI, so it keeps working.
`DFP-1` is the Thor's HDMI output (found automatically from the Xorg log line
`DFP-n: Internal TMDS`).

The EDID (`/etc/X11/elecrow-1024x600.bin`, embedded in the script) describes:
- preferred mode **1024×600 @ 60 Hz** (CVT timing, 49.00 MHz pixel clock,
  h 1024/1072/1168/1312, v 600/603/613/624, −hsync +vsync)
- fallback modes 640×480, 800×600, 1024×768 @ 60 Hz
- size 154 × 86 mm, name `ELC Elecrow7`

## Requirements

- Jetson AGX Thor with JetPack (Ubuntu desktop, GDM on Xorg, `/etc/X11/xorg.conf` present)
- `sudo` access

## Installation

1. **Connect the Elecrow:**
   - HDMI cable from the Thor's HDMI port to the display.
   - **Power it through its micro-USB port** (labelled "Power" or "Touch") from a Thor USB-A port
     or a 5 V / 2 A charger. HDMI does not power the panel. If that port also carries touch,
     connecting it to the Thor gives you touch input too.
   - Turn on the **backlight switch** on the back of the panel, if it has one.
2. **Copy this folder to the Thor** and run:
   ```bash
   cd jetson-elecrow-display
   chmod +x setup-elecrow-display.sh
   sudo ./setup-elecrow-display.sh
   ```
   The installer backs up the original `/etc/X11/xorg.conf` (to `xorg.conf.bak-before-elecrow`),
   installs the EDID and the two boot services, then restarts GDM and applies the right mode.

> **Note:** Restarting GDM logs out anyone using the desktop. SSH sessions are not affected.
> Use `--no-restart` to apply at the next boot instead.

## Using different displays

| Connected | Result |
|---|---|
| Normal monitor on HDMI | Original settings, monitor's own resolution |
| Elecrow on HDMI | Elecrow at 1024×600 |
| Elecrow on HDMI + monitor on DisplayPort | Both, as one extended desktop |
| Only a monitor on DisplayPort | Elecrow settings are added for the empty HDMI port, which can show up as an extra phantom 1024×600 screen. Set `FORCE_HDMI=never` if this setup is permanent |

**Swapping displays:** shut down, swap, boot. Without rebooting, swap and run:
```bash
sudo elecrow-display --apply
```
This restarts GDM with the original settings, checks what X detects, and adds the Elecrow
settings if needed. The desktop session is logged out.

Arrange screens, choose the primary one or mirror them in *Settings → Displays*, or with `xrandr`.

## Commands

| Command | Effect |
|---|---|
| `sudo ./setup-elecrow-display.sh` | Install and apply now |
| `sudo ./setup-elecrow-display.sh --no-restart` | Install; applies at the next boot |
| `sudo ./setup-elecrow-display.sh --uninstall` | Remove everything and restore the original `xorg.conf` |
| `elecrow-display --status` | Show detected outputs, the current mode and the services (no root needed) |
| `sudo elecrow-display --apply` | Detect the displays again now |

## Settings

`/etc/default/elecrow-display`:

| Setting | Default | Meaning |
|---|---|---|
| `FORCE_HDMI` | `auto` | `auto`: add the Elecrow settings only when X finds nothing on HDMI. `always`: always use them. `never`: original settings only |
| `HDMI_DFP` | *(empty)* | X name of the HDMI output. Empty means auto-detect (`DFP-1` on Thor) |

Run `sudo elecrow-display --apply` after editing.

## Checking that it worked

```bash
elecrow-display --status
```

Elecrow on HDMI:
```
X detected (connected): DFP-1    HDMI = DFP-1
mode: ORIGINAL config + Elecrow 1024x600 on HDMI
  Option      "ConnectedMonitor" "DFP-1"
HDMI-0 connected primary 1024x600+0+0 ... 154mm x 86mm
```

Normal monitor on HDMI:
```
X detected (connected): DFP-1    HDMI = DFP-1
mode: ORIGINAL config (all displays auto-detected)
HDMI-0 connected primary 1920x1080+0+0 ...
```

Boot decisions are logged: `journalctl -b -u elecrow-display-check`

## Troubleshooting

| Symptom | What to do |
|---|---|
| Normal monitor says "resolution / frame rate not supported" | The monitor wasn't detected when X started (it was off or asleep), so the Elecrow settings were added. Turn the monitor on and run `sudo elecrow-display --apply`. |
| Elecrow black, but `--status` shows `HDMI-0 connected 1024x600` | The Thor is sending a signal, so check the panel: micro-USB power, backlight switch, cable/adapter. |
| Elecrow shows "Out of range" or a garbled picture | `DISPLAY=:0 xrandr --output HDMI-0 --mode 1024x768` (or `800x600`). |
| DisplayPort monitor black | Run `sudo elecrow-display --apply`, then check whether `X detected` lists a DP output. If not, X sees no monitor on DP at all: check that you're using the DisplayPort socket, the cable or adapter (DP→HDMI needs an active adapter), and the monitor input. |
| Login screen restarts more than once at boot | It shouldn't. Check `journalctl -b -u elecrow-display -u elecrow-display-check`. |
| Desktop doesn't start | Over SSH, run `sudo ./setup-elecrow-display.sh --uninstall`, or `sudo cp /etc/X11/xorg.conf.bak-before-elecrow /etc/X11/xorg.conf && sudo systemctl disable elecrow-display elecrow-display-check && sudo systemctl restart display-manager`. |

`(EE) NVIDIA(GPU-1): Failed to initialize the NVIDIA graphics device!` can appear in the
Xorg log. It refers to a second GPU entry and can be ignored.

## Other panels

The same method works for other HDMI panels that don't report an EDID: replace `EDID_HEX` in the
script with an EDID for your panel's resolution. You can make one with a tool like
`edid-generator`, or copy it from a working monitor:
`od -An -tx1 -v /sys/class/drm/card*-HDMI-A-1/edid | tr -d ' \n'`.
Keep the pixel clock within the Thor's HDMI limit of 165 MHz.

## Files

| Path | Purpose |
|---|---|
| `setup-elecrow-display.sh` | Installer / uninstaller / status tool |
| `/usr/local/sbin/elecrow-display` | Installed copy of the tool |
| `/etc/systemd/system/elecrow-display.service` | Boot: restore original settings before GDM |
| `/etc/systemd/system/elecrow-display-check.service` | Boot: add Elecrow settings after GDM if HDMI is empty |
| `/etc/default/elecrow-display` | Settings |
| `/etc/X11/elecrow-1024x600.bin` | Elecrow EDID |
| `/etc/X11/xorg.conf.bak-before-elecrow` | Backup of the original X config |
