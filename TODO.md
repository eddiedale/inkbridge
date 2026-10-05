# TODO

Phase 3 items, roughly in order of usefulness. See `docs/results.md` for what
already works.

- [ ] **Wi-Fi stalls.** Wi-Fi works (`--host <tablet-ip>`, after
  `rm-ssh-over-wlan on`) but has periodic 100 to 170 ms stalls; see
  `docs/results.md`. Not tablet power save, not AWDL. Could try another
  router/band, or turning power save off from inkbridge on connect.
- [ ] **Side button.** Map `BTN_STYLUS` (331) to right-click, maybe
  `BTN_STYLUS2` (332) to middle-click or a modifier. Check first which codes
  the Pure's pen actually sends.
- [ ] **Auto reconnect.** Restart the SSH stream when it drops (cable pulled,
  tablet sleeps) instead of exiting; release any held button first.
- [x] **Pressure curve.** Curve, activation threshold and smoothing of the
  ~38 Hz pressure updates, tunable live in the TUI.
- [ ] **Prediction (experiment).** The pen firmware batches positions on a
  ~16 ms cycle and filters them, which shows as hover lag (drawing feels fine).
  Try extrapolating `--predict 0..20` ms from recent velocity, hover only at
  first, and watch for overshoot.
- [ ] **Touch gestures (optional).** The touch panel (`event3`) is grabbed
  but ignored; could become scroll / pinch zoom in Photoshop.
- [ ] **Tilt direction check.** Tilt is rotated with the mapping, but the sign
  (does leaning right give positive X?) is unverified. Record with `--debug`
  while leaning right, then toward you.

## Ideas

- **Menu bar app.** Drag-to-Applications app with a menu bar icon: connect /
  disconnect, status, settings (host, rotation, fill, pressure curve) and
  auto-reconnect. Considerations:
  - No terminal for the SSH password: on first connect, ask once and install
    an app-owned SSH key on the tablet (or keep the password in Keychain and
    pass it via `SSH_ASKPASS`).
  - Unsigned builds trigger an "unidentified developer" warning; clean
    distribution needs a Developer ID and notarization ($99/year). Not
    possible on the App Store (posting input events needs no sandbox).
  - The app needs its own input-control permission; unsigned rebuilds can
    reset it during development.
  - Build the `.app` with a small script (binary, Info.plist, codesign)
    rather than an Xcode project. Refactor the bridge's top-level code into
    a start/stop object first.
  - Best done after the pressure curve, so the GUI exposes settings that are
    already tuned.
- **Localhost tuning page.** `inkbridge` serves a small settings page on
  `http://localhost:PORT`: connect button, status, and a live pressure-curve
  editor showing real pen pressure. Decent for tuning, but not an end
  product: the native binary still has to be started from a terminal and
  granted permission, and a browser alone cannot do the job (no SSH, and
  pages cannot post system-wide pen events).
- **Interactive TUI.** Done: live panel with pen state, pressure meters,
  link stats and single-key settings saved to `~/.config/inkbridge/`.
