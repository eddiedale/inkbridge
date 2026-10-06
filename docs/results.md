# Phase 0 result

Date: 2026-10-05. macOS 27, Photoshop, Ghostty terminal.

`swift tools/pressure-test.swift` (default `--variant full`): stroke 1 tapers
thin to thick, stroke 2 constant. Photoshop honours synthetic CGEvent tablet
pressure. Gate passed.

# Phase 2 result

Date: 2026-10-05. `bridge/inkbridge.swift` draws pressure-sensitive strokes in
Photoshop over USB. Gate passed.

Lag measured with `--stats`: SSH/USB transport adds under 1 ms of jitter and no
backlog (p95 0.6 ms above best case, 300 to 500 reports/s). Optimized build
and `--rate` 125/250 made no perceptible difference. The remaining lag and
smoothing come from the tablet's pen firmware (see recon-pure.md).

# Mapping check

Landscape, `--rotate 90` (tablet top edge on the right), now the default.
Tracing the screen border reached raw X 23..9609 and Y 70..12966, so the full
digitizer range lines up with the visible screen; no calibration offset needed.
On a 2560x1440 display the letterboxed area was 2560x1402 (19 pt bars top and
bottom); the traced border landed at screen x 7..2546, y 22..1419.

Correction (2026-10-06): that letterbox used a wrong tablet aspect (0.548,
from misreading the evtest `Resolution` values). The display is 1404 x 1872
(0.75), matching the raw pen range, so in landscape the tablet is 4:3 and
`--keep-aspect` now gives 1920x1440 with 320 pt bars left and right. Fill
(the default) was not affected.

# Wi-Fi test

Date: 2026-10-05. Tablet on 5 GHz channel 36 (signal -69 dBm), Mac -64 dBm,
same channel. SSH over Wi-Fi enabled with `rm-ssh-over-wlan on` (persists).

- With default settings: ping average 30 ms, stddev 9 ms. Pen stream lag
  (`--stats`) was 3 to 4 ms above the best case in calm stretches, but every
  ~10 s there were stretches of 50 to 80 ms median with spikes up to 175 ms.
- `iw dev wlan0 set power_save off` on the tablet (not persistent, resets on
  reboot) cut idle ping to 5.7 ms +- 0.7, but the periodic 100 to 170 ms
  stalls in the pen stream remained.
- `sudo ifconfig awdl0 down` on the Mac (AirDrop/Continuity radio) did not
  remove them either.

Conclusion: Wi-Fi works but is not recommended for drawing yet. Remaining
suspects: router, tablet Wi-Fi driver, Mac Wi-Fi. USB is solid.
