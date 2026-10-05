// Phase 0: does an app honour synthetic tablet pressure posted via CGEvent?
//
// Usage:
//   swift tools/pressure-test.swift [--variant full|subtype-only] [--delay 5]
//
// Hover the mouse over a Photoshop canvas (brush size bound to Pen Pressure),
// run the script, and keep your hands off the mouse during the countdown.
// Draws two horizontal strokes starting at the current cursor position:
//   1. pressure ramping from 0.05 to 1.0 (should taper thin to thick)
//   2. constant pressure 0.5 (reference)
//
// Requires Accessibility permission for the terminal running this script.

import CoreGraphics
import Foundation

enum Variant: String { case full, subtypeOnly = "subtype-only" }

var variant = Variant.full
var delay = 5
var args = CommandLine.arguments.dropFirst().makeIterator()
while let arg = args.next() {
    switch arg {
    case "--variant":
        if let v = args.next(), let parsed = Variant(rawValue: v) { variant = parsed }
    case "--delay":
        if let d = args.next(), let parsed = Int(d) { delay = parsed }
    default:
        print("unknown argument: \(arg)")
        exit(1)
    }
}

guard let source = CGEventSource(stateID: .hidSystemState) else {
    print("Could not create event source")
    exit(1)
}

// Arbitrary but consistent identifiers for our fake tablet and pen.
let deviceID: Int64 = 0x5A
let vendorID: Int64 = 0x056A        // Wacom's USB vendor id; some apps key off it
let tabletID: Int64 = 0x0001
let pointerID: Int64 = 0x0001
let penPointerType: Int64 = 1       // NX_TABLET_POINTER_PEN
// Capabilities: abs X/Y, buttons, pressure, tilt X/Y (NX_TABLET_CAPABILITY_*).
let capabilityMask: Int64 = 0x0001 | 0x0002 | 0x0004 | 0x0400 | 0x0080 | 0x0100

func post(_ event: CGEvent) {
    event.post(tap: .cghidEventTap)
}

func proximity(enter: Bool, at point: CGPoint) {
    // Standalone proximity event.
    if let e = CGEvent(source: source) {
        e.type = .tabletProximity
        e.location = point
        fillProximityFields(e, enter: enter)
        post(e)
    }
    // Many drivers also send a mouse-moved carrying the proximity subtype.
    if variant == .full,
       let m = CGEvent(mouseEventSource: source, mouseType: .mouseMoved,
                       mouseCursorPosition: point, mouseButton: .left) {
        m.setIntegerValueField(.mouseEventSubtype,
                               value: Int64(CGEventMouseSubtype.tabletProximity.rawValue))
        fillProximityFields(m, enter: enter)
        post(m)
    }
}

func fillProximityFields(_ e: CGEvent, enter: Bool) {
    e.setIntegerValueField(.tabletProximityEventVendorID, value: vendorID)
    e.setIntegerValueField(.tabletProximityEventTabletID, value: tabletID)
    e.setIntegerValueField(.tabletProximityEventPointerID, value: pointerID)
    e.setIntegerValueField(.tabletProximityEventDeviceID, value: deviceID)
    e.setIntegerValueField(.tabletProximityEventSystemTabletID, value: deviceID)
    e.setIntegerValueField(.tabletProximityEventVendorPointerType, value: 0x0802)
    e.setIntegerValueField(.tabletProximityEventPointerType, value: penPointerType)
    e.setIntegerValueField(.tabletProximityEventCapabilityMask, value: capabilityMask)
    e.setIntegerValueField(.tabletProximityEventEnterProximity, value: enter ? 1 : 0)
}

func pen(_ type: CGEventType, at point: CGPoint, pressure: Double) {
    guard let e = CGEvent(mouseEventSource: source, mouseType: type,
                          mouseCursorPosition: point, mouseButton: .left) else { return }
    e.setIntegerValueField(.mouseEventSubtype,
                           value: Int64(CGEventMouseSubtype.tabletPoint.rawValue))
    e.setDoubleValueField(.mouseEventPressure, value: pressure)
    if variant == .full {
        e.setDoubleValueField(.tabletEventPointPressure, value: pressure)
        e.setIntegerValueField(.tabletEventPointX, value: Int64(point.x))
        e.setIntegerValueField(.tabletEventPointY, value: Int64(point.y))
        e.setDoubleValueField(.tabletEventTiltX, value: 0)
        e.setDoubleValueField(.tabletEventTiltY, value: 0)
        e.setIntegerValueField(.tabletEventDeviceID, value: deviceID)
    }
    post(e)
}

func stroke(from start: CGPoint, length: CGFloat, steps: Int,
            pressure: (Double) -> Double) {
    let stepTime: useconds_t = 4_000  // ~250 Hz, similar to a real tablet
    pen(.mouseMoved, at: start, pressure: 0)
    usleep(stepTime)
    pen(.leftMouseDown, at: start, pressure: pressure(0))
    for i in 1...steps {
        let t = Double(i) / Double(steps)
        let p = CGPoint(x: start.x + length * CGFloat(t), y: start.y)
        pen(.leftMouseDragged, at: p, pressure: pressure(t))
        usleep(stepTime)
    }
    let end = CGPoint(x: start.x + length, y: start.y)
    pen(.leftMouseUp, at: end, pressure: 0)
    usleep(stepTime)
}

print("Variant: \(variant.rawValue). Hover over the canvas and let go of the mouse.")
for i in stride(from: delay, to: 0, by: -1) {
    print("Drawing in \(i)...")
    sleep(1)
}

guard let origin = CGEvent(source: nil)?.location else {
    print("Could not read cursor position")
    exit(1)
}

proximity(enter: true, at: origin)
usleep(20_000)

stroke(from: origin, length: 400, steps: 200) { t in 0.05 + 0.95 * t }
usleep(100_000)
stroke(from: CGPoint(x: origin.x, y: origin.y + 60), length: 400, steps: 200) { _ in 0.5 }

usleep(20_000)
proximity(enter: false, at: CGPoint(x: origin.x + 400, y: origin.y + 60))

print("""
Done. Expected: top stroke tapers thin to thick, bottom stroke is constant.
If both look the same, retry with the other --variant, then try Krita.
""")
