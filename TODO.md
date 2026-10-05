# TODO

Phase 3 items, roughly in order of usefulness. See `docs/results.md` for what
already works.

- [ ] **Wi-Fi.** Enable with `rm-ssh-over-wlan on` on the tablet, run with
  `--host <tablet-ip>`, and compare `--stats` (rate, lag jitter) against USB.
- [ ] **Side button.** Map `BTN_STYLUS` (331) to right-click, maybe
  `BTN_STYLUS2` (332) to middle-click or a modifier. Check first which codes
  the Pure's pen actually sends.
- [ ] **Auto reconnect.** Restart the SSH stream when it drops (cable pulled,
  tablet sleeps) instead of exiting; release any held button first.
- [ ] **Pressure curve.** Configurable gamma or control points, plus an
  activation threshold. Pressure only updates at ~38 Hz while position runs at
  ~580 Hz; consider interpolating between pressure updates to avoid stepped
  strokes.
- [ ] **Prediction (experiment).** The pen firmware batches positions on a
  ~16 ms cycle and filters them, which shows as hover lag (drawing feels fine).
  Try extrapolating `--predict 0..20` ms from recent velocity, hover only at
  first, and watch for overshoot.
- [ ] **Touch gestures (optional).** The touch panel (`event3`) is grabbed
  but ignored; could become scroll / pinch zoom in Photoshop.
- [ ] **Tilt direction check.** Tilt is rotated with the mapping, but the sign
  (does leaning right give positive X?) is unverified. Record with `--debug`
  while leaning right, then toward you.
