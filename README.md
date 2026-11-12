# inkbridge

Use a reMarkable as a pressure-sensitive drawing tablet on macOS.

https://github.com/user-attachments/assets/3615dec1-4eb6-47ed-9bff-25e82229a9c6

(Early video shown above. Might not use correct build command as we go along. Read below on how to use the tool)

inkbridge runs on the Mac, reads the pen over SSH and posts native macOS
tablet events, so Photoshop and other apps see pressure, tilt, hover and the
eraser end. USB and Wi-Fi use the tablet's built-in tools. The experimental
Bluetooth connection uses a helper on the tablet.

> inkbridge is early and usable for drawing. USB was tested on a reMarkable
> Pure (firmware 3.28) with Photoshop on Apple Silicon and reported working on
> a Paper Pro. Experimental Bluetooth was tested on a Paper Pro (firmware
> 3.29.1.0), including automatic service startup after a reboot and
> reconnection after deep sleep with USB unplugged.

## What works

- Pressure (4096 levels), tilt, hover and the eraser end
- Landscape or portrait mapping onto the main display
- Pen and touch are grabbed while running, so the tablet UI does not react to
  drawing or finger gestures; released again on exit
- Around 500 reports per second over USB, with under 1 ms added by the link
- Experimental [Bluetooth](#bluetooth-experimental) on Paper Pro, with
  automatic startup on the tablet and reconnection on the Mac

Known limits:

- Hover lags a little. The pen firmware filters positions and delivers them
  in batches on a ~16 ms cycle, before inkbridge sees them. Drawing feels fine.
- No barrel rotation (twisting the pen); the hardware does not report it.

## Requirements

- macOS with Swift (Xcode or the Command Line Tools: `xcode-select --install`)
- A reMarkable in **developer mode**, which gives root SSH access.
  **Turning on developer mode factory resets the tablet.** Sync or export
  your notebooks first.
- A USB cable for initial setup. See [Wi-Fi](#wi-fi) or
  [Bluetooth](#bluetooth-experimental) for wireless use.

## Setup

1. Enable developer mode on the tablet and finish the setup screens. The root
   SSH password is under Settings > Help > About > Copyrights and licenses,
   at the bottom of the GPLv3 Compliance section.
2. Connect the tablet by USB. Every reMarkable is at `10.11.99.1` over USB,
   which inkbridge uses by default.
3. Download and build, in a terminal:
   ```
   git clone https://github.com/eddiedale/inkbridge.git
   cd inkbridge
   make
   ```
   `make` builds inkbridge and asks whether to add an `inkbridge` command,
   so you can start it from any folder (a link in `/usr/local/bin`). Say no
   and you start it with `./inkbridge` in this folder instead; your answer
   is remembered.

   To update later, run `git pull` and `make` again in the same folder.
   `inkbridge unlink` removes the link again (the next `make` asks again);
   `./inkbridge link` adds it any time. If linking needs admin rights on
   your Mac, use `sudo ./inkbridge link`, or
   `./inkbridge link --prefix ~/.local` if `~/.local/bin` is on your PATH.
4. Allow your terminal app to control the computer, so it can post pen
   events: System Settings > Privacy & Security > Device control and data
   access (called Accessibility on older macOS versions).

## Usage

```
inkbridge
```

Hold the tablet in landscape with its top edge on the right. A live panel
lets you tune settings while drawing:

```
  ╷╭╮╷╷╭ ╭╮ ╭─╮╷╶┬╮╭─╴╭─╴
  ││╰┤├┴╮├┴╮├┬╯│ │││╶╮├╴
  ╵╵ ╵╵ ╵╰─╯╵╰╴╵╶┴╯╰─╯╰─╴

  ● connected   USB 10.11.99.1

  ← → pressure curve   1.5 firm          ▁▁▂▂▂▃▃▃▄▄▅▆▆▇▇█
  ↓ ↑ min pressure     3%                less does not draw
  ⇧↓↑ max pressure     80%               more is full pressure
  s   smoothing        on                evens out steps in pressure
  r   rotation         90°               landscape, top edge right
  a   area map         crop to screen    middle 73% of tablet height
  p   padding          2%                margin at the tablet edge
  d   draw on tablet   off               the pen only drives the Mac
  t   touch on tablet  off               fingers are ignored by the tablet
  w   connection       USB               switch to Wi-Fi

  h help   q quit   settings are saved automatically
```

`inkbridge --full` also shows live pen meters (state, output and raw
pressure) at the top, handy while tuning the pressure settings, and the
report rate and link lag at the bottom.

| setting | key | default | what it does |
|---|---|---|---|
| pressure curve | ← → | 1.5 (firm) | below 1 is soft (light strokes get heavier), above 1 is firm |
| min pressure | ↓ ↑ | 3% | pressure below this does not draw, so a resting pen leaves no ink |
| max pressure | Shift ↓ ↑ | 80% | pressure from this point is full, so you reach the thickest stroke without pushing hard |
| smoothing | s | on | the pen reports pressure only ~38 times a second; smoothing removes the steps this leaves in tapered strokes, at about 10 ms of pressure delay |
| rotation | r | 90° | how the tablet is held; 90° is landscape with its top edge on the right |
| area map | a | crop to screen | *crop to screen*: a centred part of the tablet in your screen's shape, so shapes stay true and the whole screen is reachable (on a 16:9 screen, the middle ~73% of the tablet's height). *fill screen*: the whole tablet, shapes stretch a little. *keep proportions*: the whole tablet, with bars on the screen |
| padding | p | 2% | a margin around the tablet edge that maps just past the screen edge, so you reach the screen edges before the bezel (2% is about 3 mm) |
| draw on tablet | d | off | on: the tablet sees the pen too and draws on the open page with its current tool |
| touch on tablet | t | off | on: fingers work on the tablet; off keeps a resting hand from scrolling or zooming it |
| connection | w | USB | switch between USB (lowest lag) and Wi-Fi; see [Wi-Fi](#wi-fi) |

Press `h` in the panel for a help screen explaining each setting. Settings
are saved to `~/.config/inkbridge/settings.json`. Press `q` to quit.

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
./inkbridge --host 192.168.1.23
```

Over Wi-Fi, inkbridge turns off the tablet's Wi-Fi power saving, which
noticeably lowers latency. It comes back on when the tablet reboots.

### Bluetooth (experimental)

Bluetooth Low Energy is available as an experimental connection on the
reMarkable Paper Pro. The tablet needs developer mode and SSH access over USB
for the initial installation. The Mac build needs Clang and `ld.lld` for the
tablet helpers. If `ld.lld` is outside your `PATH`, pass
`LLD=/path/to/ld.lld` to `make`.

#### Install once over USB

Wake the tablet and connect it over USB. From the inkbridge folder, build
the Bluetooth helpers and install the tablet's startup service.

```sh
make bluetooth
sh tools/bluetooth.sh install
```

#### Connect and reconnect

```sh
./inkbridge --bluetooth
```

Allow Bluetooth access if macOS prompts. inkbridge checks the SSH host key
recorded over USB and uses the same tablet password or SSH key. Choose an
[SSH key](#password-and-ssh-key) during setup to enable automatic reconnection.
Once inkbridge shows `connected`, unplug the cable.

On later boots, the service starts as the tablet becomes ready. If the
connection drops during sleep, wake the Paper Pro and leave inkbridge open.
The tablet advertises again, and inkbridge retries with the configured SSH
key.

#### Manage the tablet service

Connect the tablet over USB to run these commands.

| Command | What it does |
| --- | --- |
| `sh tools/bluetooth.sh status` | Show whether startup is configured and the service is ready. |
| `sh tools/bluetooth.sh start` | Start the installed service, or run a temporary service until reboot on an unconfigured tablet. |
| `sh tools/bluetooth.sh stop` | Stop the current service. An installed service starts again on the next boot. |
| `sh tools/bluetooth.sh uninstall` | Stop the service and remove its startup registration and tablet helpers. |

After updating the source, rerun `make bluetooth`, then reinstall the
tablet helpers over USB with `sh tools/bluetooth.sh install`. Use the same
install command if a tablet firmware update replaces the startup
registration. Use `./inkbridge --bluetooth --full` to see the report rate
and link lag.

### Commands

| command | what it does |
|---|---|
| `make` | build inkbridge, and the first time offer to add the inkbridge link |
| `make bluetooth` | build inkbridge and the Bluetooth helpers for the Mac and Paper Pro |
| `make clean` | delete the built program and helpers |
| `inkbridge` | start inkbridge from any folder, once linked |
| `./inkbridge` | start inkbridge from the inkbridge folder, if you haven't linked it |
| `inkbridge link` | add the inkbridge link, so `inkbridge` runs from any folder (`--prefix DIR` puts it in `DIR/bin`) |
| `inkbridge unlink` | remove the inkbridge link |
| `git pull` then `make` | update the main app |

Before it is linked, use `./inkbridge link` from the inkbridge folder.

### Options


| option | default | |
|---|---|---|
| `--host` | `10.11.99.1` | tablet address |
| `--bluetooth` | off | use the experimental Paper Pro Bluetooth connection |
| `--rotate 0\|90\|180\|270` | `90` | how far the tablet is turned clockwise from portrait |
| `--area fill\|keep\|crop` | `crop` | how the tablet maps onto the display (see area map above) |
| `--device` | `event2` | pen input device on the tablet |
| `--touch-device` | `event3` | touch input device, grabbed so gestures are ignored |
| `--no-grab` | off | turn on draw on tablet and touch on tablet |
| `--full` | off | add pen meters and link stats to the panel |
| `--plain` | off | print lines instead of the live panel |
| `--stats` | off | in plain mode, print report rate and link lag once a second |
| `--rate N` | `0` | cap motion events per second (0 = every report) |
| `--debug` | off | print every pen report |

### Other reMarkable models

The device names differ between models. Find the pen and touch devices with:

```
ssh root@10.11.99.1 cat /proc/bus/input/devices
```

and pass them with `--device` and `--touch-device`. USB and Wi-Fi use the
Pure's axis ranges, and Bluetooth uses the Paper Pro's. `tools/recon.sh`
collects axis ranges for other models. Reports from other devices are welcome.

### Linking by hand

You only need this if `make` could not add the `inkbridge` command, or you
want it somewhere other than `/usr/local/bin`. The command is just a link to
the program in your inkbridge folder, placed in any folder on your PATH
(`echo $PATH` lists them).

From the inkbridge folder:

```
ln -sf "$PWD/inkbridge" /usr/local/bin/inkbridge
```

and to remove it:

```
rm /usr/local/bin/inkbridge
```

Use `sudo` in front of either if that folder needs admin rights, and swap
`/usr/local/bin` for your folder of choice. `inkbridge link --prefix DIR`
does the same for `DIR/bin` and remembers it, so `inkbridge unlink` can
remove it later; links made by hand outside `/usr/local/bin` it does not
know about.

## How it works

Over USB and Wi-Fi, inkbridge runs the tablet's built-in `evtest` over SSH
and groups its output by pen report. Over Bluetooth, a tablet helper sends
compact binary reports through an encrypted SSH session over a BLE L2CAP
channel. It coalesces position updates to limit traffic and sends contact,
proximity, and eraser changes as they happen.

On the Mac, inkbridge maps the reports to the display and posts `CGEvent`
tablet proximity and pointer events with pressure and tilt. A watchdog on
the tablet releases input grabs when the connection drops.

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
