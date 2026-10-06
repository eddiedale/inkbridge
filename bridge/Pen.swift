// Pen input: evtest parsing, mapping to the display, and macOS tablet events.

import CoreGraphics
import Foundation

// MARK: Pen geometry (from docs/recon-pure.md)

let maxX = 9620.0, maxY = 13000.0
let pressureRange = 4096.0
let maxTilt = 9000.0                  // hundredths of a degree

let evKey: UInt16 = 1, evAbs: UInt16 = 3
let absX: UInt16 = 0, absY: UInt16 = 1, absPressure: UInt16 = 24
let absTiltX: UInt16 = 26, absTiltY: UInt16 = 27
let btnToolPen: UInt16 = 320, btnToolRubber: UInt16 = 321, btnTouch: UInt16 = 330

/// Maps raw pen coordinates to global display points on the main display.
///   fill: the whole tablet onto the whole display (shapes stretch a little)
///   keep: the whole tablet, letterboxed on the display in its own proportions
///   crop: a centred part of the tablet in the display's proportions, onto the
///         whole display; pen positions outside it stick to the screen edge
struct Mapping {
    let rect: CGRect        // display area the tablet region maps to
    let region: CGRect      // used part of the (rotated) tablet, in 0...1
    let rotation: Int

    init(display: CGRect = CGDisplayBounds(CGMainDisplayID())) {
        rotation = settings.rotation
        // The raw pen range has the screen's shape (1404 x 1872), so its
        // ratio is the physical aspect.
        let tabletAspect = rotation % 180 == 0 ? maxX / maxY : maxY / maxX
        let displayAspect = display.width / display.height
        switch settings.area {
        case .keep:
            let scale = min(display.width / tabletAspect, display.height)
            let size = CGSize(width: tabletAspect * scale, height: scale)
            rect = CGRect(x: display.midX - size.width / 2, y: display.midY - size.height / 2,
                          width: size.width, height: size.height)
            region = CGRect(x: 0, y: 0, width: 1, height: 1)
        case .crop:
            rect = display
            if displayAspect > tabletAspect {
                let h = tabletAspect / displayAspect
                region = CGRect(x: 0, y: (1 - h) / 2, width: 1, height: h)
            } else {
                let w = displayAspect / tabletAspect
                region = CGRect(x: (1 - w) / 2, y: 0, width: w, height: 1)
            }
        case .fill:
            rect = display
            region = CGRect(x: 0, y: 0, width: 1, height: 1)
        }
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
        let cu = min(1, max(0, (u - region.minX) / region.width))
        let cv = min(1, max(0, (v - region.minY) / region.height))
        return CGPoint(x: rect.minX + cu * rect.width, y: rect.minY + cv * rect.height)
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

let eventSource = CGEventSource(stateID: .hidSystemState)

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
    if let e = CGEvent(source: eventSource) {
        e.type = .tabletProximity
        e.location = point
        fill(e)
        e.post(tap: .cghidEventTap)
    }
    if let m = CGEvent(mouseEventSource: eventSource, mouseType: .mouseMoved,
                       mouseCursorPosition: point, mouseButton: .left) {
        m.setIntegerValueField(.mouseEventSubtype,
                               value: Int64(CGEventMouseSubtype.tabletProximity.rawValue))
        fill(m)
        m.post(tap: .cghidEventTap)
    }
}

func postPen(_ type: CGEventType, at point: CGPoint, pressure: Double, tiltX: Double, tiltY: Double) {
    guard let e = CGEvent(mouseEventSource: eventSource, mouseType: type,
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

var mapping = Mapping()
var raw = PenState()           // updated per event
// What macOS has been told.
var postedInRange = false, postedEraser = false, postedContact = false
var pressureOut = 0.0          // shaped and smoothed pressure last sent
var lastFlush = 0.0
var lastMotion = 0.0           // when the last motion event was posted
var motionPending = false      // a throttled motion still has to be posted

/// Called on every SYN_REPORT: diff raw against what was posted and emit CGEvents.
func flush() {
    let now = Date().timeIntervalSince1970
    let point = mapping.point(x: raw.x, y: raw.y)
    let (tiltX, tiltY) = mapping.tilt(x: raw.tiltX, y: raw.tiltY)

    // A stroke starts only above min pressure.
    let rawPressure = min(1, Double(raw.pressure) / pressureRange)
    let contact = raw.inRange && raw.touch && rawPressure > settings.minPressure
    let target = settings.shape(rawPressure)
    if contact && postedContact && settings.smoothing {
        pressureOut += (target - pressureOut) * (1 - exp(-(now - lastFlush) / pressureSmoothing))
    } else {
        pressureOut = contact ? target : 0
    }
    lastFlush = now

    // Tool changed (pen <-> eraser) or left range: close out the old state first.
    if postedInRange && (!raw.inRange || raw.rubber != postedEraser) {
        if postedContact { postPen(.leftMouseUp, at: point, pressure: 0, tiltX: tiltX, tiltY: tiltY) }
        postProximity(enter: false, eraser: postedEraser, at: point)
        postedInRange = false
        postedContact = false
    }
    if raw.inRange && !postedInRange {
        postProximity(enter: true, eraser: raw.rubber, at: point)
        postedInRange = true
        postedEraser = raw.rubber
    }
    if raw.inRange {
        let type: CGEventType
        switch (postedContact, contact) {
        case (false, true): type = .leftMouseDown
        case (true, false): type = .leftMouseUp
        case (true, true): type = .leftMouseDragged
        case (false, false): type = .mouseMoved
        }
        let isMotion = type == .leftMouseDragged || type == .mouseMoved
        if isMotion && rate > 0 && now - lastMotion < 1 / rate {
            motionPending = true
        } else {
            postPen(type, at: point, pressure: pressureOut, tiltX: tiltX, tiltY: tiltY)
            if isMotion { lastMotion = now }
            motionPending = false
        }
        postedContact = contact
    }
    if debug {
        print(String(format: "x=%5d y=%5d p=%4d->%.3f tilt=%+.2f,%+.2f %@%@%@ -> (%.0f, %.0f)",
                     raw.x, raw.y, raw.pressure, pressureOut, tiltX, tiltY,
                     raw.pen ? "pen " : "", raw.rubber ? "eraser " : "", contact ? "contact" : "",
                     point.x, point.y))
    }
}

/// Lifts the pen and leaves proximity, so macOS is not left with a held button.
func releasePen() {
    raw.pen = false
    raw.rubber = false
    raw.touch = false
    flush()
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
        record(eventTime: line)
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

// MARK: Link stats

// Lag is Mac receive time minus the tablet's event timestamp. The clocks are not
// synced, so it is shown relative to the lowest lag seen this run (about the
// fixed transport cost); growth there means a backlog or a stall.
struct LinkStats {
    var reports = 0                    // reports in the last second
    var p50 = 0.0, p95 = 0.0, max = 0.0, rawP50 = 0.0
    var updated = 0.0                  // when this window closed
}

var linkStats = LinkStats()
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
    guard now - windowStart >= 1 else { return }
    let sorted = lags.sorted()
    func pct(_ p: Double) -> Double { sorted[min(sorted.count - 1, Int(Double(sorted.count) * p))] - minLag }
    linkStats = LinkStats(reports: lags.count, p50: pct(0.5), p95: pct(0.95),
                          max: sorted.last! - minLag, rawP50: sorted[sorted.count / 2], updated: now)
    if stats && !tui {
        print(String(format: "%4d reports/s  lag above best: p50 %5.1f  p95 %5.1f  max %5.1f ms  (raw p50 %.1f ms)",
                     linkStats.reports, linkStats.p50, linkStats.p95, linkStats.max, linkStats.rawP50))
    }
    lags.removeAll(keepingCapacity: true)
    windowStart = now
}
