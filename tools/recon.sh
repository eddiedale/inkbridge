#!/bin/sh
# Phase 1 recon: read-only probe of the reMarkable over SSH.
# Usage: tools/recon.sh [host]   (default 10.11.99.1, USB)
# Output goes to docs/recon-raw.txt and docs/pen-sample.bin.
# While "draw now" is shown: hover the pen, then draw a few strokes covering
# all four corners with light and hard pressure, tilt it, and try the eraser end.

HOST=${1:-10.11.99.1}
OUT=docs/recon-raw.txt
mkdir -p docs

# One shared SSH connection so the password is asked only once.
SOCK=$(mktemp -u /tmp/rm-recon.XXXXXX)
SSH="ssh -o ControlMaster=auto -o ControlPath=$SOCK -o ControlPersist=60"
trap '$SSH -O exit root@"$HOST" 2>/dev/null' EXIT

$SSH root@"$HOST" 'sh -s' > "$OUT" 2>&1 <<'REMOTE'
section() { echo; echo "=== $1"; }
section uname;        uname -a; uname -m
section os-release;   cat /etc/os-release 2>/dev/null
section devices;      cat /proc/bus/input/devices
section evtest;       command -v evtest || echo "no evtest"
section abs-bitmaps
for d in /sys/class/input/event*; do
  echo "$d: $(cat $d/device/name) abs=$(cat $d/device/capabilities/abs)"
done
section framebuffer
cat /sys/class/graphics/fb0/virtual_size 2>/dev/null
cat /sys/class/graphics/fb0/modes 2>/dev/null
ls /sys/class/drm 2>/dev/null
for m in /sys/class/drm/*/modes; do echo "$m: $(cat $m)"; done 2>/dev/null
REMOTE
if [ $? -ne 0 ]; then
  echo "SSH to $HOST failed:"; cat "$OUT"
  echo "Is the tablet awake, unlocked and connected by USB?"
  exit 1
fi

echo "Wrote $OUT"
grep -A1 -i 'N: Name' "$OUT" | grep -v '^--'
printf "Pen evdev node (e.g. event1): "
read NODE

if $SSH root@"$HOST" "command -v evtest" >/dev/null 2>&1; then
  echo "evtest present, dumping axis info"
  # pty (-tt) so evtest's output is line buffered and survives the kill.
  $SSH -tt root@"$HOST" "evtest /dev/input/$NODE & sleep 1; kill \$!" >> "$OUT" 2>&1
fi

echo "Draw now for 10 seconds (hover, light, hard, tilt, eraser)..."
# No `timeout` on the tablet. No pty here (-T) so the binary stream stays intact.
$SSH -T root@"$HOST" "cat /dev/input/$NODE & sleep 10; kill \$!" > docs/pen-sample.bin
echo "Captured $(wc -c < docs/pen-sample.bin) bytes to docs/pen-sample.bin"
