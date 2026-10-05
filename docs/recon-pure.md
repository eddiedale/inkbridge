# Phase 1 recon: reMarkable Pure

Date: 2026-10-05. Raw output in `recon-raw.txt`, a 6.5 s pen capture in
`pen-sample.bin` (collected with `tools/recon.sh`).

## System

- Kernel `6.12.49` on `imx93-tatsu`, **aarch64**: `struct input_event` is
  24 bytes (`<qqHHi`: sec, usec, type, code, value).
- OS: Codex Linux 5.8.203, firmware 3.28.0.172.
- `evtest` is on the device. `timeout` is not.
- DRM mode reports `260x1408` on `card0-DPI-1`, which looks like raw e-ink
  panel timing, not the visible resolution. Not needed for mapping.

## Input devices

| node   | name                  | notes                     |
|--------|-----------------------|---------------------------|
| event0 | 44440000.bbnsm:pwrkey | power button              |
| event1 | Hall effect sensors   | folio cover               |
| event2 | **Elan marker input** | pen (Elan, not Wacom EMR) |
| event3 | Elan touch input      | multitouch                |

## Pen (`/dev/input/event2`)

Keys: `BTN_TOOL_PEN`, `BTN_TOOL_RUBBER`, `BTN_TOUCH`, `BTN_STYLUS`,
`BTN_STYLUS2`.

| axis         | min   | max   | resolution |
|--------------|-------|-------|------------|
| ABS_X        | 0     | 9620  | 2400       |
| ABS_Y        | 0     | 13000 | 1776       |
| ABS_PRESSURE | 0     | 4096  |            |
| ABS_DISTANCE | 0     | 65535 |            |
| ABS_TILT_X   | -9000 | 9000  |            |
| ABS_TILT_Y   | -9000 | 9000  |            |

Observations from the capture:

- **X and Y have different resolutions**, so raw counts are not square. The
  physical aspect is (9620/2400) : (13000/1776) = 4.01 : 7.32, about 0.548,
  not the raw 0.74. Map using resolution-scaled units. Orientation (which axis
  is the long edge of the screen) still needs a check in Phase 2.
- **Position report rate**: about 580 Hz while drawing (median 1.7 ms between
  `SYN_REPORT`s), about 500 Hz while hovering. Frames carry only the axes that
  changed; X or Y alone happens.
- **Pressure updates only about 38 Hz** during contact, tilt about 61 Hz,
  while position runs at ~580 Hz. Full 12-bit range seen (0 to 4095). The
  host should hold the last pressure and probably interpolate or smooth
  between updates, or strokes will show steps.
- Tilt seen from -2992 to 5800, consistent with hundredths of a degree.
- Hover works: `BTN_TOOL_PEN=1` with `BTN_TOUCH=0` and position updates.
- Eraser end reports `BTN_TOOL_RUBBER=1` (pen goes to 0 first).
- `ABS_DISTANCE` is non-zero during contact (15682 to 22351) and climbs from 0
  while lifting, so it is not a clean "distance to surface". Do not rely on it
  for proximity; use `BTN_TOOL_PEN` / `BTN_TOOL_RUBBER`.
- **Positions arrive in bursts on a ~16 ms cycle.** Within a cycle, 8 reports
  come 1.2 to 2.3 ms apart, then a 4.4 ms gap. The position step per report is
  the same regardless of that gap, and steps are very smooth (second
  differences of 0 to 2 units). So the firmware samples or interpolates on a
  fixed grid and filters heavily, then delivers per ~60 Hz frame. That means
  up to ~16 ms batching delay plus filter lag inside the tablet, before the
  data reaches evdev. It matches the "laggy and smoothed" feel in Phase 2 and
  cannot be removed host-side; only prediction could hide it.
- Side buttons were not pressed in the capture; untested.

## Gate

Pen device readable over SSH and reports pressure: **passed**.
