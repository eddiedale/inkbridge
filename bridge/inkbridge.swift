// inkbridge: stream the reMarkable pen over SSH and post macOS tablet events.
//
// Usage:
//   swiftc -O bridge/inkbridge.swift -o build/inkbridge
//   build/inkbridge [--host 10.11.99.1] [--device event2] [--rotate 0|90|180|270]
//                   [--keep-aspect] [--touch-device event3] [--no-grab]
//                   [--debug] [--stats] [--rate 0]
//
// Runs `evtest --grab` on the tablet through an SSH pty (line buffered output,
// and the grab is released when SSH drops). The touch panel is grabbed too, so
// finger gestures do not move the tablet UI while drawing; --no-grab releases
// both. --rotate is how far the tablet is turned clockwise from portrait
// (default 90: top edge on the right). The pen area fills the whole display;
// --keep-aspect keeps the tablet's proportions with bars at the edges instead.
// --stats prints report rate and transport lag once a second. --rate caps
// motion events per second (0 = every report); presses, lifts and proximity
// changes are never delayed. Ctrl-C to stop.
//
// Requires Accessibility permission for the terminal running this.

import CoreGraphics
import Foundation

// MARK: Options

var host = "10.11.99.1"
var device = "event2"
var rotation = 90
var grab = true
var keepAspect = false
var touchDevice = "event3"
var debug = false
var stats = false
var rate = 0.0
var args = CommandLine.arguments.dropFirst().makeIterator()
while let arg = args.next() {
    switch arg {
    case "--host": host = args.next() ?? host
    case "--device": device = args.next() ?? device
    case "--rotate":
        if let r = args.next().flatMap(Int.init), [0, 90, 180, 270].contains(r) { rotation = r }
        else { print("--rotate takes 0, 90, 180 or 270"); exit(1) }
    case "--keep-aspect": keepAspect = true
    case "--touch-device": touchDevice = args.next() ?? touchDevice
    case "--no-grab": grab = false
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

// MARK: Pen geometry (from docs/recon-pure.md)

let maxX = 9620.0, maxY = 13000.0
let resX = 2400.0, resY = 1776.0      // units per inch, differ per axis
let maxPressure = 4096.0
let maxTilt = 9000.0                  // hundredths of a degree

let evSyn: UInt16 = 0, evKey: UInt16 = 1, evAbs: UInt16 = 3
let absX: UInt16 = 0, absY: UInt16 = 1, absPressure: UInt16 = 24
let absTiltX: UInt16 = 26, absTiltY: UInt16 = 27
let btnToolPen: UInt16 = 320, btnToolRubber: UInt16 = 321, btnTouch: UInt16 = 330

/// Maps raw pen coordinates to global display points on the main display,
/// filling it, or keeping the physical aspect ratio (letterboxed) with --keep-aspect.
struct Mapping {
    let rect: CGRect

    init(display: CGRect) {
        if !keepAspect { rect = display; return }
        let portraitW = maxX / resX, portraitH = maxY / resY
        let (w, h) = rotation % 180 == 0 ? (portraitW, portraitH) : (portraitH, portraitW)
        let scale = min(display.width / w, display.height / h)
        let size = CGSize(width: w * scale, height: h * scale)
        rect = CGRect(x: display.midX - size.width / 2, y: display.midY - size.height / 2,
                      width: size.width, height: size.height)
    }

    func point(x: Int32, y: Int32) -> CGPoint {
        let nx = Double(x) / maxX, ny = Double(y) / maxY
        let (u, v): (Double, Double)
        switch rotation {
        case 90: (u, v) = (1 - ny, nx)
        case 180: (u, v) = (1 - nx, 1 - ny)
        case 270: (u, v) = (ny, 1 - nx)
        default: (u, v) = (nx, ny)
        }
        return CGPoint(x: rect.minX + u * rect.width, y: rect.minY + v * rect.height)
    }

    /// Rotates raw tilt the same way as position, scaled to -1...1.
    func tilt(x: Int32, y: Int32) -> (x: Double, y: Double) {
        let tx = Double(x) / maxTilt, ty = Double(y) / maxTilt
        switch rotation {
        case 90: return (-ty, tx)
        case 180: return (-tx, -ty)
        case 270: return (ty, -tx)
        default: return (tx, ty)
        }
    }
}

// MARK: Event output

guard let source = CGEventSource(stateID: .hidSystemState) else {
    print("Could not create event source")
    exit(1)
}

// Same identifiers as tools/pressure-test.swift, which Photoshop accepted.
let deviceID: Int64 = 0x5A
let vendorID: Int64 = 0x056A
let tabletID: Int64 = 0x0001
let capabilityMask: Int64 = 0x0001 | 0x0002 | 0x0004 | 0x0400 | 0x0080 | 0x0100

func postProximity(enter: Bool, eraser: Bool, at point: CGPoint) {
    let pointerType: Int64 = eraser ? 3 : 1   // NX_TABLET_POINTER_ERASER / _PEN
    func fill(_ e: CGEvent) {
        e.setIntegerValueField(.tabletProximityEventVendorID, value: vendorID)
        e.setIntegerValueField(.tabletProximityEventTabletID, value: tabletID)
        e.setIntegerValueField(.tabletProximityEventPointerID, value: eraser ? 2 : 1)
        e.setIntegerValueField(.tabletProximityEventDeviceID, value: deviceID)
        e.setIntegerValueField(.tabletProximityEventSystemTabletID, value: deviceID)
        e.setIntegerValueField(.tabletProximityEventVendorPointerType, value: eraser ? 0x080A : 0x0802)
        e.setIntegerValueField(.tabletProximityEventPointerType, value: pointerType)
        e.setIntegerValueField(.tabletProximityEventCapabilityMask, value: capabilityMask)
        e.setIntegerValueField(.tabletProximityEventEnterProximity, value: enter ? 1 : 0)
    }
    if let e = CGEvent(source: source) {
        e.type = .tabletProximity
        e.location = point
        fill(e)
        e.post(tap: .cghidEventTap)
    }
    if let m = CGEvent(mouseEventSource: source, mouseType: .mouseMoved,
                       mouseCursorPosition: point, mouseButton: .left) {
        m.setIntegerValueField(.mouseEventSubtype,
                               value: Int64(CGEventMouseSubtype.tabletProximity.rawValue))
        fill(m)
        m.post(tap: .cghidEventTap)
    }
}

func postPen(_ type: CGEventType, at point: CGPoint, pressure: Double, tiltX: Double, tiltY: Double) {
    guard let e = CGEvent(mouseEventSource: source, mouseType: type,
                          mouseCursorPosition: point, mouseButton: .left) else { return }
    e.setIntegerValueField(.mouseEventSubtype,
                           value: Int64(CGEventMouseSubtype.tabletPoint.rawValue))
    if type != .mouseMoved { e.setIntegerValueField(.mouseEventClickState, value: 1) }
    e.setDoubleValueField(.mouseEventPressure, value: pressure)
    e.setDoubleValueField(.tabletEventPointPressure, value: pressure)
    e.setIntegerValueField(.tabletEventPointX, value: Int64(point.x))
    e.setIntegerValueField(.tabletEventPointY, value: Int64(point.y))
    e.setDoubleValueField(.tabletEventTiltX, value: tiltX)
    e.setDoubleValueField(.tabletEventTiltY, value: tiltY)
    e.setIntegerValueField(.tabletEventDeviceID, value: deviceID)
    e.post(tap: .cghidEventTap)
}

// MARK: Pen state machine

struct PenState {
    var x: Int32 = 0, y: Int32 = 0
    var pressure: Int32 = 0, tiltX: Int32 = 0, tiltY: Int32 = 0
    var pen = false, rubber = false, touch = false
    var inRange: Bool { pen || rubber }
}

let mapping = Mapping(display: CGDisplayBounds(CGMainDisplayID()))
var raw = PenState()      // updated per event
var posted = PenState()   // what macOS has been told
var lastMotion = 0.0      // when the last motion event was posted
var motionPending = false // a throttled motion still has to be posted

/// Called on every SYN_REPORT: diff raw against posted and emit CGEvents.
func flush() {
    let point = mapping.point(x: raw.x, y: raw.y)
    let pressure = min(1, Double(raw.pressure) / maxPressure)
    let (tiltX, tiltY) = mapping.tilt(x: raw.tiltX, y: raw.tiltY)

    // Tool changed (pen <-> eraser) or left range: close out the old state first.
    if posted.inRange && (!raw.inRange || raw.rubber != posted.rubber) {
        if posted.touch { postPen(.leftMouseUp, at: point, pressure: 0, tiltX: tiltX, tiltY: tiltY) }
        postProximity(enter: false, eraser: posted.rubber, at: point)
        posted = PenState()
    }
    if raw.inRange && !posted.inRange {
        postProximity(enter: true, eraser: raw.rubber, at: point)
    }
    if raw.inRange {
        let type: CGEventType
        switch (posted.touch, raw.touch) {
        case (false, true): type = .leftMouseDown
        case (true, false): type = .leftMouseUp
        case (true, true): type = .leftMouseDragged
        case (false, false): type = .mouseMoved
        }
        let now = Date().timeIntervalSince1970
        let isMotion = type == .leftMouseDragged || type == .mouseMoved
        if isMotion && rate > 0 && now - lastMotion < 1 / rate {
            motionPending = true
        } else {
            postPen(type, at: point, pressure: raw.touch ? pressure : 0, tiltX: tiltX, tiltY: tiltY)
            if isMotion { lastMotion = now }
            motionPending = false
        }
    }
    if debug {
        print(String(format: "x=%5d y=%5d p=%4d tilt=%+.2f,%+.2f %@%@%@ -> (%.0f, %.0f)",
                     raw.x, raw.y, raw.pressure, tiltX, tiltY,
                     raw.pen ? "pen " : "", raw.rubber ? "eraser " : "", raw.touch ? "touch" : "",
                     point.x, point.y))
    }
    posted = raw
}

/// Seconds until a pending throttled motion is due, or nil if none is pending.
func motionDue() -> Double? {
    motionPending ? max(0, lastMotion + 1 / rate - Date().timeIntervalSince1970) : nil
}

func handle(type: UInt16, code: UInt16, value: Int32) {
    switch (type, code) {
    case (evAbs, absX): raw.x = value
    case (evAbs, absY): raw.y = value
    case (evAbs, absPressure): raw.pressure = value
    case (evAbs, absTiltX): raw.tiltX = value
    case (evAbs, absTiltY): raw.tiltY = value
    case (evKey, btnToolPen): raw.pen = value != 0
    case (evKey, btnToolRubber): raw.rubber = value != 0
    case (evKey, btnTouch): raw.touch = value != 0
    default: break
    }
}

/// Parses one evtest line, e.g.
///   Event: time 1791211711.448900, type 3 (EV_ABS), code 0 (ABS_X), value 4837
///   Event: time 1791211711.448900, -------------- SYN_REPORT ------------
func parse(line: String) {
    guard line.hasPrefix("Event:") else {
        if debug { print("evtest: \(line)") }
        return
    }
    if line.contains("SYN_REPORT") {
        if stats { record(eventTime: line) }
        flush()
        return
    }
    func int(after key: String) -> Int32? {
        guard let r = line.range(of: key) else { return nil }
        return Int32(line[r.upperBound...].prefix { $0 == "-" || $0.isNumber })
    }
    if let t = int(after: "type "), let c = int(after: "code "), let v = int(after: "value ") {
        handle(type: UInt16(t), code: UInt16(c), value: v)
    }
}

// MARK: Stats

// Lag is Mac receive time minus the tablet's event timestamp. The clocks are not
// synced, so it is also shown relative to the lowest lag seen this run (about
// the fixed transport cost); growth there means a backlog.
var lags: [Double] = []
var minLag = Double.infinity
var windowStart = Date().timeIntervalSince1970

func record(eventTime line: String) {
    guard let r = line.range(of: "time "),
          let t = Double(line[r.upperBound...].prefix { $0 != "," }) else { return }
    let now = Date().timeIntervalSince1970
    let lag = (now - t) * 1000
    lags.append(lag)
    minLag = min(minLag, lag)
    if now - windowStart >= 1 {
        let sorted = lags.sorted()
        func pct(_ p: Double) -> Double { sorted[min(sorted.count - 1, Int(Double(sorted.count) * p))] - minLag }
        print(String(format: "%4d reports/s  lag above best: p50 %5.1f  p95 %5.1f  max %5.1f ms  (raw p50 %.1f ms)",
                     lags.count, pct(0.5), pct(0.95), sorted.last! - minLag, sorted[sorted.count / 2]))
        lags.removeAll(keepingCapacity: true)
        windowStart = now
    }
}

// MARK: SSH stream

// -tt: pty on the tablet so evtest line-buffers and gets SIGHUP (releasing the
// grab) when the connection drops. killall clears evtests orphaned by earlier
// runs, which would otherwise keep the grab and starve this one. The touch
// grab runs in the background of the same shell, so the hangup reaches it too.
let remote = grab
    ? "killall evtest 2>/dev/null; evtest --grab /dev/input/\(touchDevice) >/dev/null & "
      + "T=$!; evtest --grab /dev/input/\(device); kill $T"
    : "killall evtest 2>/dev/null; exec evtest /dev/input/\(device)"
// The shared control socket means the password is asked once per 10 minutes.
let sshArgs = ["ssh", "-tt", "-o", "ServerAliveInterval=2", "-o", "ConnectTimeout=5",
               "-o", "ControlMaster=auto", "-o", "ControlPath=~/.ssh/rm.sock",
               "-o", "ControlPersist=10m", "root@\(host)", remote]

// posix_spawn rather than Process: Process detaches the child from the
// terminal, so ssh cannot open /dev/tty to ask for the password.
// stdin is a pipe we never write to: with -tt, an immediate EOF on stdin (as
// from /dev/null) makes ssh close the session and drop all output.
var fds: [Int32] = [0, 0], stdinFDs: [Int32] = [0, 0]
pipe(&fds)
pipe(&stdinFDs)
var actions: posix_spawn_file_actions_t?
posix_spawn_file_actions_init(&actions)
posix_spawn_file_actions_adddup2(&actions, stdinFDs[0], 0)
posix_spawn_file_actions_adddup2(&actions, fds[1], 1)
for f in fds + stdinFDs { posix_spawn_file_actions_addclose(&actions, f) }
var argv = sshArgs.map { strdup($0) } + [nil]

var sshPID: pid_t = 0
// Stop SSH on Ctrl-C; the read loop then sees EOF and cleans up.
for sig in [SIGINT, SIGTERM] {
    signal(sig) { _ in if sshPID > 0 { kill(sshPID, SIGTERM) } }
}

let spawnError = posix_spawn(&sshPID, "/usr/bin/ssh", &actions, nil, &argv, environ)
guard spawnError == 0 else {
    print("Could not start ssh: \(String(cString: strerror(spawnError)))")
    exit(1)
}
close(fds[1])
close(stdinFDs[0])
print("Streaming \(device) from \(host), rotate \(rotation), mapped to \(mapping.rect). Ctrl-C to stop.")

let fd = fds[0]
var buffer = [UInt8](repeating: 0, count: 65536)
var pending = Data()
while true {
    // With --rate, a throttled motion must still go out if the pen stops moving.
    if let due = motionDue() {
        var p = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        if poll(&p, 1, Int32((due * 1000).rounded(.up))) == 0 { flush(); continue }
    }
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

// Leave macOS in a clean state: no stuck button, pen out of proximity.
raw.pen = false
raw.rubber = false
raw.touch = false
flush()
var status: Int32 = 0
waitpid(sshPID, &status, 0)
print("Disconnected (ssh exit \((status >> 8) & 0xff)).")
