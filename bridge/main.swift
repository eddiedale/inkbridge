// inkbridge: stream the reMarkable pen over SSH and post macOS tablet events.
//
// Usage:
//   make                      (builds build/inkbridge)
//   build/inkbridge [--host 10.11.99.1] [--rotate 0|90|180|270]
//                   [--area fill|keep|crop]
//                   [--device event2] [--touch-device event3] [--no-grab]
//                   [--plain] [--debug] [--stats] [--rate 0]
//
// Runs `evtest --grab` on the tablet through an SSH pty (line buffered output).
// The grab keeps the tablet's own app from seeing the pen; the touch panel is
// grabbed too, so finger gestures do not move the tablet UI while drawing.
// "draw on tablet" (d) and "touch on tablet" (t) release them; --no-grab
// releases both.
//
// In a terminal it shows a live panel where rotation, area map, pressure curve,
// min/max pressure and smoothing can be changed with single keys; they
// are saved to ~/.config/inkbridge/settings.json. --rotate and --area
// override the saved values. --plain (or --debug) prints lines instead.
//
// USB is the default. Over Wi-Fi, press w in the panel (it enables SSH over
// Wi-Fi on the tablet and finds its address while on USB), or pass --host.
// At start the link that worked last is tried first, then the other one.
//
// --stats prints report rate and transport lag once a second in plain mode.
// --rate caps motion events per second (0 = every report); presses, lifts and
// proximity changes are never delayed.
//
// Requires permission to control the computer for the terminal running this
// (Privacy & Security > Device control and data access / Accessibility).

import Foundation

// MARK: Options

let usbHost = "10.11.99.1"
var host = usbHost
var hostGiven = false
var device = "event2"
var touchDevice = "event3"
var plain = false
var debug = false
var stats = false
var rate = 0.0
var args = CommandLine.arguments.dropFirst().makeIterator()
while let arg = args.next() {
    switch arg {
    case "--host":
        host = args.next() ?? host
        hostGiven = true
    case "--device": device = args.next() ?? device
    case "--touch-device": touchDevice = args.next() ?? touchDevice
    case "--rotate":
        if let r = args.next().flatMap(Int.init), [0, 90, 180, 270].contains(r) { settings.rotation = r }
        else { print("--rotate takes 0, 90, 180 or 270"); exit(1) }
    case "--area":
        guard let a = args.next().flatMap(Area.init) else { print("--area takes fill, keep or crop"); exit(1) }
        settings.area = a
    case "--keep-aspect": settings.area = .keep   // older name
    case "--no-grab":
        settings.drawOnTablet = true
        settings.touchOnTablet = true
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

/// Connects without prompting; for use once the TUI owns the terminal.
func connectQuietly() -> Bool {
    guard let pid = spawnSSH(["-o", "BatchMode=yes"] + sshOptions + ["root@\(host)", "true"],
                             stdin: nil, stdout: nil, quiet: true) else { return false }
    return wait(pid) == 0
}

// Try the last-used link first, then the other one (Wi-Fi only once its
// address is known), so an unplugged cable or an absent network just works.
var connected = false
if !hostGiven && !settings.wifiHost.isEmpty {
    let order = settings.useWifi ? [settings.wifiHost, usbHost] : [usbHost, settings.wifiHost]
    for candidate in order {
        host = candidate
        print("Connecting to \(host) (\(host == usbHost ? "USB" : "Wi-Fi"))...")
        connected = connectQuietly()
        if connected { break }
    }
    if !connected { host = order[0] }
}
if !connected {
    offerKeySetup()
    print("Connecting to \(host)...")
    guard connect() else {
        print("""
        Could not connect to \(host). Check that the tablet is awake and connected
        (USB: \(usbHost)\(settings.wifiHost.isEmpty ? "" : ", Wi-Fi: \(settings.wifiHost)")). If ssh said \
        "Connection reset", the tablet's SSH server is refusing connections;
        restarting the tablet fixes it.
        """)
        exit(1)
    }
}
// Remember which link worked, so the next start tries it first.
if !hostGiven && settings.useWifi != (host != usbHost) {
    settings.useWifi = host != usbHost
    settings.save()
}

// MARK: Stream

/// The command run on the tablet. -tt gives evtest a pty so it line-buffers.
/// Evtests on our devices left by earlier runs or connections are stopped
/// first, as they would otherwise keep the grab and starve this one. Unless
/// touch is left to the tablet, a second evtest grabs the touch panel in the
/// background of the same shell. Without the pen grab the tablet draws too.
/// Over Wi-Fi, power saving is turned off for lower latency (until the
/// tablet reboots).
///
/// The evtests run in the background while the shell acts as a watchdog: it
/// expects a heartbeat line from us every second (see the main loop) and
/// kills them, releasing the grabs, after 5 s of silence or on EOF. Without
/// it, a dropped connection (cable pulled, Wi-Fi gone, terminal closed) could
/// leave the tablet's pen and touch grabbed until the next run or a reboot.
func remoteCommand() -> String {
    var command = stopOurEvtests() + "; stty -echo 2>/dev/null; "
    if host != usbHost { command += "iw dev wlan0 set power_save off 2>/dev/null; " }
    if !settings.touchOnTablet { command += "evtest --grab /dev/input/\(touchDevice) >/dev/null & T=$!; " }
    command += "evtest \(settings.drawOnTablet ? "" : "--grab ")/dev/input/\(device) & E=$!; "
    return command + "while read -t 5 x; do :; done; kill -9 $E $T 2>/dev/null"
}

/// Restarts the stream so a changed grab setting takes effect.
func restartStream() {
    stopStream()
    if !startStream() {
        statusMessage = "Could not restart the stream"
        quitRequested = true
    }
}

var sshPID: pid_t = 0
var streamFD: Int32 = -1       // evtest output
var streamStdin: Int32 = -1    // kept open: with -tt, EOF on stdin ends the session
var pending = Data()

func startStream() -> Bool {
    var output: [Int32] = [0, 0], input: [Int32] = [0, 0]
    pipe(&output)
    pipe(&input)
    // Keep our ends of the pipes out of the ssh process, so EOF arrives on exit.
    _ = fcntl(output[0], F_SETFD, FD_CLOEXEC)
    _ = fcntl(input[1], F_SETFD, FD_CLOEXEC)
    // -q: no "Shared connection closed" message drawn over the panel.
    let pid = spawnSSH(["-tt", "-q"] + sshOptions + ["root@\(host)", remoteCommand()], stdin: input[0], stdout: output[1])
    close(output[1])
    close(input[0])
    guard let pid else {
        close(output[0])
        close(input[1])
        return false
    }
    sshPID = pid
    streamFD = output[0]
    streamStdin = input[1]
    return true
}

func stopStream() {
    releasePen()
    if sshPID > 0 {
        kill(sshPID, SIGTERM)
        _ = wait(sshPID)
        sshPID = 0
    }
    close(streamFD)
    close(streamStdin)
    pending.removeAll()
}

/// Runs a command on the tablet and returns its output.
func remoteOutput(_ command: String) -> String? {
    var output: [Int32] = [0, 0]
    pipe(&output)
    _ = fcntl(output[0], F_SETFD, FD_CLOEXEC)
    let pid = spawnSSH(["-o", "BatchMode=yes"] + sshOptions + ["root@\(host)", command],
                       stdin: nil, stdout: output[1], quiet: true)
    close(output[1])
    var data = Data()
    var chunk = [UInt8](repeating: 0, count: 4096)
    while true {
        let n = read(output[0], &chunk, chunk.count)
        if n <= 0 { break }
        data.append(chunk, count: n)
    }
    close(output[0])
    guard let pid, wait(pid) == 0 else { return nil }
    return String(data: data, encoding: .utf8)
}

/// Switches between USB and Wi-Fi from the panel. Going to Wi-Fi from USB
/// enables SSH over Wi-Fi on the tablet if needed and looks up its address.
func switchConnection() {
    let previous = host
    let target: String
    if host == usbHost {
        statusMessage = "Setting up Wi-Fi..."
        render()
        let setup = "[ -f /data/internal/rm_enable_ssh_wifi_marker ] || rm-ssh-over-wlan on >/dev/null; "
            + "ip -4 -o addr show wlan0"
        guard let output = remoteOutput(setup),
              let r = output.range(of: #"inet (\d+\.\d+\.\d+\.\d+)"#, options: .regularExpression) else {
            statusMessage = "The tablet has no Wi-Fi address. Is its Wi-Fi on?"
            return
        }
        target = String(output[r].dropFirst(5))
        settings.wifiHost = target
    } else {
        target = usbHost
    }
    let name = target == usbHost ? "USB" : "Wi-Fi \(target)"
    statusMessage = "Switching to \(name)..."
    render()
    stopStream()
    host = target
    if connectQuietly() && startStream() {
        settings.useWifi = host != usbHost
        settings.save()
        statusMessage = ""
    } else {
        host = previous
        statusMessage = "Could not reach \(name)" + (target == usbHost ? " (is the cable in?)" : "")
        if !startStream() { quitRequested = true }
    }
}

var quitRequested = false
// Stop SSH on a signal; the read loop then sees EOF and cleans up. In the TUI,
// Ctrl-C arrives as a key instead.
for sig in [SIGINT, SIGTERM, SIGHUP] {
    signal(sig) { _ in
        quitRequested = true
        if sshPID > 0 { kill(sshPID, SIGTERM) }
    }
}

guard startStream() else { exit(1) }

tui = !plain && !debug && isatty(0) != 0 && isatty(1) != 0
if tui {
    enterTUI()
} else {
    print("Streaming \(device) from \(host), rotate \(settings.rotation), mapped to \(mapping.rect). Ctrl-C to stop.")
}

// MARK: Main loop

var buffer = [UInt8](repeating: 0, count: 65536)
var nextRender = 0.0
var nextHeartbeat = 0.0
loop: while !quitRequested {
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
    // Heartbeat for the watchdog on the tablet (see remoteCommand).
    if now >= nextHeartbeat {
        _ = write(streamStdin, "\n", 1)
        nextHeartbeat = now + 1
    }
    timeout = timeout < 0 ? nextHeartbeat - now : min(timeout, nextHeartbeat - now)

    var pfds = [pollfd(fd: streamFD, events: Int16(POLLIN), revents: 0)]
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
            break
        }
        nextRender = 0
        if restartRequested {
            restartRequested = false
            restartStream()
            continue
        }
        if switchRequested {
            switchRequested = false
            switchConnection()
            continue
        }
    }
    if pfds[0].revents != 0 {
        let n = read(streamFD, &buffer, buffer.count)
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
stopStream()
leaveTUI()
if quitRequested { stopRemote() }
print(quitRequested ? "Stopped." : "Connection to \(host) lost.")
