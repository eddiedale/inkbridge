// inkbridge: stream the reMarkable pen over SSH and post macOS tablet events.
//
// Usage:
//   swiftc -O bridge/*.swift -o build/inkbridge
//   build/inkbridge [--host 10.11.99.1] [--rotate 0|90|180|270] [--keep-aspect]
//                   [--device event2] [--touch-device event3] [--no-grab]
//                   [--plain] [--debug] [--stats] [--rate 0]
//
// Runs `evtest --grab` on the tablet through an SSH pty (line buffered output,
// and the grab is released when SSH drops). The touch panel is grabbed too, so
// finger gestures do not move the tablet UI while drawing; --no-grab releases
// both.
//
// In a terminal it shows a live panel where rotation, area map, pressure curve,
// min/max pressure and smoothing can be changed with single keys; they
// are saved to ~/.config/inkbridge/settings.json. --rotate and --keep-aspect
// override the saved values. --plain (or --debug) prints lines instead.
//
// --stats prints report rate and transport lag once a second in plain mode.
// --rate caps motion events per second (0 = every report); presses, lifts and
// proximity changes are never delayed.
//
// Requires permission to control the computer for the terminal running this
// (Privacy & Security > Device control and data access / Accessibility).

import Foundation

// MARK: Options

var host = "10.11.99.1"
var device = "event2"
var touchDevice = "event3"
var grab = true
var plain = false
var debug = false
var stats = false
var rate = 0.0
var args = CommandLine.arguments.dropFirst().makeIterator()
while let arg = args.next() {
    switch arg {
    case "--host": host = args.next() ?? host
    case "--device": device = args.next() ?? device
    case "--touch-device": touchDevice = args.next() ?? touchDevice
    case "--rotate":
        if let r = args.next().flatMap(Int.init), [0, 90, 180, 270].contains(r) { settings.rotation = r }
        else { print("--rotate takes 0, 90, 180 or 270"); exit(1) }
    case "--keep-aspect": settings.keepAspect = true
    case "--no-grab": grab = false
    case "--plain": plain = true
    case "--debug": debug = true
    case "--stats": stats = true
    case "--rate":
        guard let r = args.next().flatMap(Double.init), r >= 0 else { print("--rate takes a number"); exit(1) }
        rate = r
    default:
        print("unknown argument: \(arg)")
        exit(1)
    }
}
mapping = Mapping()

// MARK: Connect

offerKeySetup()
print("Connecting to \(host)...")
guard connect() else {
    print("Could not connect. Is the tablet awake and connected (USB: 10.11.99.1)?")
    exit(1)
}

// -tt: pty on the tablet so evtest line-buffers and gets SIGHUP (releasing the
// grab) when the connection drops. killall clears evtests orphaned by earlier
// runs, which would otherwise keep the grab and starve this one. The touch
// grab runs in the background of the same shell, so the hangup reaches it too.
let remote = grab
    ? "killall evtest 2>/dev/null; evtest --grab /dev/input/\(touchDevice) >/dev/null & "
      + "T=$!; evtest --grab /dev/input/\(device); kill $T"
    : "killall evtest 2>/dev/null; exec evtest /dev/input/\(device)"

// stdin is a pipe we never write to: with -tt, an immediate EOF on stdin (as
// from /dev/null) makes ssh close the session and drop all output.
var fds: [Int32] = [0, 0], stdinFDs: [Int32] = [0, 0]
pipe(&fds)
pipe(&stdinFDs)
// Keep our ends of the pipes out of the ssh process, so EOF arrives on exit.
_ = fcntl(fds[0], F_SETFD, FD_CLOEXEC)
_ = fcntl(stdinFDs[1], F_SETFD, FD_CLOEXEC)

var sshPID: pid_t = 0
var quitRequested = false
// Stop SSH on a signal; the read loop then sees EOF and cleans up. In the TUI,
// Ctrl-C arrives as a key instead.
for sig in [SIGINT, SIGTERM, SIGHUP] {
    signal(sig) { _ in
        quitRequested = true
        if sshPID > 0 { kill(sshPID, SIGTERM) }
    }
}

guard let pid = spawnSSH(["-tt"] + sshOptions + ["root@\(host)", remote],
                         stdin: stdinFDs[0], stdout: fds[1]) else { exit(1) }
sshPID = pid
close(fds[1])
close(stdinFDs[0])

tui = !plain && !debug && isatty(0) != 0 && isatty(1) != 0
if tui {
    enterTUI()
} else {
    print("Streaming \(device) from \(host), rotate \(settings.rotation), mapped to \(mapping.rect). Ctrl-C to stop.")
}

// MARK: Main loop

let fd = fds[0]
var buffer = [UInt8](repeating: 0, count: 65536)
var pending = Data()
var nextRender = 0.0
loop: while true {
    let now = Date().timeIntervalSince1970
    var timeout = -1.0
    if tui {
        if now >= nextRender {
            render()
            nextRender = now + 1.0 / 15
        }
        timeout = nextRender - now
    }
    // With --rate, a throttled motion must still go out if the pen stops moving.
    if let due = motionDue() { timeout = timeout < 0 ? due : min(timeout, due) }

    var pfds = [pollfd(fd: fd, events: Int16(POLLIN), revents: 0)]
    if tui { pfds.append(pollfd(fd: 0, events: Int16(POLLIN), revents: 0)) }
    let ready = poll(&pfds, nfds_t(pfds.count), timeout < 0 ? -1 : Int32((timeout * 1000).rounded(.up)))
    if ready < 0 {
        if errno == EINTR { continue }
        break
    }
    if let due = motionDue(), due <= 0 { flush() }

    if tui && pfds[1].revents & Int16(POLLIN) != 0 {
        let n = read(0, &buffer, buffer.count)
        if n > 0 && !handleKeys(Array(buffer[0..<n])) {
            quitRequested = true
            kill(sshPID, SIGTERM)
            break
        }
        nextRender = 0
    }
    if pfds[0].revents != 0 {
        let n = read(fd, &buffer, buffer.count)
        if n < 0 && errno == EINTR { continue }
        if n <= 0 { break }
        pending.append(buffer, count: n)
        while let nl = pending.firstIndex(of: UInt8(ascii: "\n")) {
            let lineData = pending[pending.startIndex..<nl]
            pending.removeSubrange(pending.startIndex...nl)
            if let line = String(data: lineData, encoding: .utf8) {
                parse(line: line.trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }
    }
}

// Leave macOS in a clean state: no stuck button, pen out of proximity.
releasePen()
leaveTUI()
if quitRequested { stopRemote() }
print("Disconnected (ssh exit \(wait(sshPID))).")
