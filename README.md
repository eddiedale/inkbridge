# inkbridge

Use a reMarkable as a pressure-sensitive drawing tablet on macOS.

inkbridge runs on the Mac, reads the pen over SSH and posts native macOS
tablet events, so Photoshop and other apps see pressure, tilt, hover and the
eraser end. Nothing is installed on the tablet.

> Status: early, but usable for drawing. Developed and tested on a
> reMarkable Pure (firmware 3.28) over USB with Photoshop on Apple Silicon.
> Other models may work with different device names; see below.

## What works

- Pressure (4096 levels), tilt, hover and the eraser end
- Landscape or portrait mapping onto the main display
- Pen and touch are grabbed while running, so the tablet UI does not react to
  drawing or finger gestures; released again on exit
- Around 500 reports per second over USB, with under 1 ms added by the link

Known limits:

- Hover lags a little. The pen firmware filters positions and delivers them
  in batches on a ~16 ms cycle, before inkbridge sees them. Drawing feels fine.
- No barrel rotation (twisting the pen); the hardware does not report it.

## Requirements

- macOS with Swift (Xcode or the Command Line Tools: `xcode-select --install`)
- A reMarkable in **developer mode**, which gives root SSH access.
  **Turning on developer mode factory resets the tablet.** Sync or export
  your notebooks first.
- A USB cable (Wi-Fi is untested)

## Setup

1. Enable developer mode on the tablet and finish the setup screens. The root
   SSH password is under Settings > Help > About > Copyrights and licenses,
   at the bottom of the GPLv3 Compliance section.
2. Connect the tablet by USB. Every reMarkable is at `10.11.99.1` over USB,
   which inkbridge uses by default.
3. Build:
   ```
   swiftc -O bridge/inkbridge.swift -o build/inkbridge
   ```
4. Allow your terminal app to control the computer, so it can post pen
   events: System Settings > Privacy & Security > Device control and data
   access (called Accessibility on older macOS versions).

## Usage

```
build/inkbridge
```

Enter the tablet password when asked; the connection is reused for 10
minutes, so restarts in between do not ask again. To skip the password
entirely, add your SSH key to the tablet once with
`ssh-copy-id root@10.11.99.1` (a reMarkable software update may remove it;
just run it again).

Hold the tablet in landscape with its top edge on the right. Ctrl-C to stop.

In Photoshop, set Brush Settings > Shape Dynamics > Size Jitter Control to
Pen Pressure to see pressure.

| option | default | |
|---|---|---|
| `--host` | `10.11.99.1` | tablet address |
| `--rotate 0\|90\|180\|270` | `90` | how far the tablet is turned clockwise from portrait |
| `--keep-aspect` | off | keep the tablet's proportions instead of filling the display |
| `--device` | `event2` | pen input device on the tablet |
| `--touch-device` | `event3` | touch input device, grabbed so gestures are ignored |
| `--no-grab` | off | leave pen and touch working on the tablet as well |
| `--stats` | off | print report rate and link lag once a second |
| `--rate N` | `0` | cap motion events per second (0 = every report) |
| `--debug` | off | print every pen report |

### Other reMarkable models

The device names differ between models. Find the pen and touch devices with:

```
ssh root@10.11.99.1 cat /proc/bus/input/devices
```

and pass them with `--device` and `--touch-device`. The axis ranges in
`bridge/inkbridge.swift` are the Pure's; `tools/recon.sh` collects them for
another model. Reports from other devices are welcome.

## How it works

inkbridge opens SSH to the tablet and runs its built-in `evtest --grab` on the
pen device, which takes exclusive access and prints each input event. The Mac
side parses those, groups them per report, maps tablet coordinates onto the
display and posts `CGEvent` tablet proximity and pointer events with pressure
and tilt. When the connection drops, the tablet releases the grab.

Background and measurements are in `docs/`:

- `docs/recon-pure.md`: the Pure's input devices, axis ranges, report rates
  and the firmware batching behind the hover lag
- `docs/results.md`: test results per phase

`tools/pressure-test.swift` checks, without a tablet, whether an app honours
synthetic pen pressure on your Mac.

## Credits

- [rm-pad](https://github.com/alvesvaren/rm-pad): the host-side, SSH-stream
  approach (for Linux)
- [tigertail](https://github.com/Ezjfc/tigertail): notes on reMarkable pen
  input

reMarkable is a trademark of reMarkable AS.

inkbridge is not affiliated with reMarkable or Wacom.

## License

MIT
