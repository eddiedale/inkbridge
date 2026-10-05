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
On a 2560x1440 display the letterboxed area is 2560x1402 (19 pt bars top and
bottom); the traced border landed at screen x 7..2546, y 22..1419.
