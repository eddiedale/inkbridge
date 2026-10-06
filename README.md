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
- A USB cable, at least for the first connection. After that Wi-Fi works
  too; see [Wi-Fi](#wi-fi).

## Setup

1. Enable developer mode on the tablet and finish the setup screens. The root
   SSH password is under Settings > Help > About > Copyrights and licenses,
   at the bottom of the GPLv3 Compliance section.
2. Connect the tablet by USB. Every reMarkable is at `10.11.99.1` over USB,
   which inkbridge uses by default.
3. Build:
   ```
   swiftc -O bridge/*.swift -o build/inkbridge
   ```
4. Allow your terminal app to control the computer, so it can post pen
   events: System Settings > Privacy & Security > Device control and data
   access (called Accessibility on older macOS versions).

## Usage

```
build/inkbridge
```

Hold the tablet in landscape with its top edge on the right. A live panel
shows the pen state and pressure, and lets you tune settings while drawing:

```
inkbridge   ● connected   USB 10.11.99.1

  pen          drawing
  pressure     ██████████░░░░░░░░░░░░░░░░░░░░░░ 0.33
  raw          ████████████████░░░░░░░░░░░░░░░░ 0.51

  ← → pressure curve  1.5 firm   ▁▁▂▂▂▃▃▃▄▄▅▆▆▇▇█
  ↓ ↑ min pressure    3%  less does not draw
  ⇧↓↑ max pressure    80%  more is full pressure
  s   smoothing       on
  r   rotation        90°  landscape, top edge right
  a   area map        fill screen
  w   connection      USB  switch to Wi-Fi

  498 reports/s   lag p50 0.3 ms   p95 0.6 ms
  q quit   settings are saved automatically
```

- **pressure curve**: below 1 is soft (light strokes get heavier), above 1
  is firm. Default 1.5.
- **min pressure**: how much pressure starts a stroke, so a resting pen
  leaves no ink. Default 3%.
- **max pressure**: how hard you need to press for full output, so you reach
  the thickest stroke without pushing the pen to its limit. Default 80%.
- **smoothing**: the pen reports pressure only ~38 times a second; smoothing
  removes the steps this would leave in tapered strokes.

Settings are saved to `~/.config/inkbridge/settings.json`. Press `q` to quit.

In Photoshop, set Brush Settings > Shape Dynamics > Size Jitter Control to
Pen Pressure to see pressure.

### Password and SSH key

On the first run, inkbridge offers to set up an SSH key so you never need the
tablet password again:

```
Set up an SSH key so you won't need the tablet password?
  1) use ~/.ssh/id_ed25519.pub
  n) create a new key just for the tablet (~/.ssh/id_ed25519_inkbridge)
  s) skip, and don't ask again
```

Pick one of your existing keys or `n` for a dedicated key (recommended), then
enter the password once to install it. The choice is saved in
`~/.config/inkbridge/`, and keys on the tablet survive reMarkable software
updates. Delete that folder to be asked again.

Without a key, inkbridge asks for the password and keeps the connection open
for 10 minutes, so restarts in between do not ask again.

### Wi-Fi

USB has the lowest and steadiest latency. Wi-Fi works too, with a bit more
lag and occasional short stalls.

**Easiest:** start inkbridge over USB and press `w` in the panel. inkbridge
turns on SSH over Wi-Fi on the tablet (once, it stays on), finds the
tablet's Wi-Fi address and switches to it. You can unplug the cable then.
Press `w` again to go back to USB.

You do not need to choose at start: inkbridge tries the link that worked
last, then the other one, so plugging or unplugging the cable just works
(the missing one costs a few seconds of timeout). This needs the SSH key
from above, since the panel cannot ask for a password.

**By hand:** with the cable in, run `ssh root@10.11.99.1 rm-ssh-over-wlan on`
once. Find the tablet's Wi-Fi address under Settings > Help > About on the
tablet, then:

```
build/inkbridge --host 192.168.1.23
```

Over Wi-Fi, inkbridge turns off the tablet's Wi-Fi power saving, which
noticeably lowers latency. It comes back on when the tablet reboots.

### Options


| option | default | |
|---|---|---|
| `--host` | `10.11.99.1` | tablet address |
| `--rotate 0\|90\|180\|270` | `90` | how far the tablet is turned clockwise from portrait |
| `--keep-aspect` | off | keep the tablet's proportions instead of filling the display |
| `--device` | `event2` | pen input device on the tablet |
| `--touch-device` | `event3` | touch input device, grabbed so gestures are ignored |
| `--no-grab` | off | leave pen and touch working on the tablet as well |
| `--plain` | off | print lines instead of the live panel |
| `--stats` | off | in plain mode, print report rate and link lag once a second |
| `--rate N` | `0` | cap motion events per second (0 = every report) |
| `--debug` | off | print every pen report |

### Other reMarkable models

The device names differ between models. Find the pen and touch devices with:

```
ssh root@10.11.99.1 cat /proc/bus/input/devices
```

and pass them with `--device` and `--touch-device`. The axis ranges in
`bridge/Pen.swift` are the Pure's; `tools/recon.sh` collects them for
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
