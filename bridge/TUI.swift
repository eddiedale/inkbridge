// Live terminal panel: pen state, pressure, link stats, and single-key settings.

import Foundation

var tui = false                 // panel is active (set in main)
var switchRequested = false     // w pressed: main switches USB <-> Wi-Fi
var statusMessage = ""          // shown in the panel, e.g. while switching
var savedTermios = termios()
var termiosSaved = false

func out(_ s: String) {
    fputs(s, stdout)
    fflush(stdout)
}

/// Raw keys (no echo, no line buffering, Ctrl-C as a key) and the alternate
/// screen, so the panel can redraw in place.
func enterTUI() {
    tcgetattr(0, &savedTermios)
    termiosSaved = true
    var t = savedTermios
    t.c_lflag &= ~tcflag_t(ICANON | ECHO | ISIG)
    tcsetattr(0, TCSANOW, &t)
    out("\u{1B}[?1049h\u{1B}[?25l")
    atexit { leaveTUI() }
}

func leaveTUI() {
    guard termiosSaved else { return }
    tcsetattr(0, TCSANOW, &savedTermios)
    termiosSaved = false
    out("\u{1B}[?25h\u{1B}[?1049l")
}

/// Adds `delta` and rounds to whole percent, so repeated steps stay clean.
func step(_ value: Double, _ delta: Double) -> Double {
    ((value + delta) * 100).rounded() / 100
}

enum Key { case char(UInt8), up, down, left, right, shiftUp, shiftDown }

/// Splits raw terminal input into keys. Arrows arrive as ESC [ A..D, and with
/// Shift as ESC [ 1 ; 2 A..D.
func keys(in bytes: [UInt8]) -> [Key] {
    var result: [Key] = []
    var i = 0
    while i < bytes.count {
        guard bytes[i] == 0x1B, i + 2 < bytes.count, bytes[i + 1] == UInt8(ascii: "[") else {
            result.append(.char(bytes[i]))
            i += 1
            continue
        }
        // Skip parameters up to the final letter.
        var j = i + 2
        while j < bytes.count, !(0x40...0x7E).contains(bytes[j]) { j += 1 }
        guard j < bytes.count else { break }
        let shift = bytes[(i + 2)..<j].elementsEqual(Array("1;2".utf8))
        switch bytes[j] {
        case UInt8(ascii: "A"): result.append(shift ? .shiftUp : .up)
        case UInt8(ascii: "B"): result.append(shift ? .shiftDown : .down)
        case UInt8(ascii: "C"): result.append(.right)
        case UInt8(ascii: "D"): result.append(.left)
        default: break
        }
        i = j + 1
    }
    return result
}

/// Applies key presses. Returns false when the user asked to quit.
func handleKeys(_ bytes: [UInt8]) -> Bool {
    var changed = false
    for key in keys(in: bytes) {
        switch key {
        case .char(UInt8(ascii: "q")), .char(3): return false   // 3 = Ctrl-C
        case .right: settings.curve = min(3, ((settings.curve + 0.1) * 10).rounded() / 10)
        case .left: settings.curve = max(0.3, ((settings.curve - 0.1) * 10).rounded() / 10)
        case .up: settings.minPressure = min(settings.maxPressure - 0.1, step(settings.minPressure, 0.01))
        case .down: settings.minPressure = max(0, step(settings.minPressure, -0.01))
        case .shiftUp: settings.maxPressure = min(1, step(settings.maxPressure, 0.05))
        case .shiftDown: settings.maxPressure = max(settings.minPressure + 0.1, step(settings.maxPressure, -0.05))
        case .char(UInt8(ascii: "s")): settings.smoothing.toggle()
        case .char(UInt8(ascii: "r")): settings.rotation = (settings.rotation + 90) % 360
        case .char(UInt8(ascii: "a")):
            settings.area = [.fill: .keep, .keep: .crop, .crop: .fill][settings.area]!
        case .char(UInt8(ascii: "w")):
            switchRequested = true
            continue
        default: continue
        }
        changed = true
    }
    if changed {
        mapping = Mapping()
        settings.save()
    }
    return true
}

func render() {
    let bold = "\u{1B}[1m", dim = "\u{1B}[2m", reset = "\u{1B}[0m", green = "\u{1B}[32m"

    func bar(_ v: Double, width: Int = 32) -> String {
        let n = Int((max(0, min(1, v)) * Double(width)).rounded())
        return String(repeating: "█", count: n) + dim + String(repeating: "░", count: width - n) + reset
    }

    let link = host == "10.11.99.1" ? "USB" : "Wi-Fi"
    let pen = !raw.inRange ? "\(dim)out of range\(reset)"
        : raw.rubber ? (postedContact ? "erasing" : "eraser hovering")
        : (postedContact ? "drawing" : "hovering")
    let rawPressure = min(1, Double(raw.pressure) / pressureRange)

    let ticks = Array("▁▂▃▄▅▆▇█")
    let curveGraph = String((1...16).map { ticks[Int((settings.shape(Double($0) / 16) * 7).rounded())] })
    let feel = settings.curve < 0.95 ? "soft" : settings.curve > 1.05 ? "firm" : "linear"
    let rotationText = [0: "portrait", 90: "landscape, top edge right",
                        180: "portrait, upside down", 270: "landscape, top edge left"][settings.rotation] ?? ""

    let areaText: String
    switch settings.area {
    case .fill: areaText = "fill screen  \(dim)whole tablet, shapes stretch a little\(reset)"
    case .keep: areaText = "keep proportions  \(dim)whole tablet, bars on screen\(reset)"
    case .crop:
        let r = mapping.region
        let used = r.width < 1 ? "middle \(Int((r.width * 100).rounded()))% of tablet width"
                               : "middle \(Int((r.height * 100).rounded()))% of tablet height"
        areaText = "crop to screen  \(dim)\(used)\(reset)"
    }
    let fresh = Date().timeIntervalSince1970 - linkStats.updated < 2
    let statsText = fresh
        ? String(format: "%d reports/s   lag p50 %.1f ms   p95 %.1f ms", linkStats.reports, linkStats.p50, linkStats.p95)
        : "waiting for pen data"

    let lines = [
        "\(bold)inkbridge\(reset)   \(green)●\(reset) connected   \(dim)\(link) \(host)\(reset)",
        "",
        "  pen          \(pen)",
        "  pressure     \(bar(pressureOut)) \(String(format: "%.2f", pressureOut))",
        "  \(dim)raw          \(reset)\(bar(rawPressure)) \(dim)\(String(format: "%.2f", rawPressure))\(reset)",
        "",
        "  \(bold)← →\(reset) pressure curve  \(String(format: "%.1f", settings.curve)) \(feel)   \(dim)\(curveGraph)\(reset)",
        "  \(bold)↓ ↑\(reset) min pressure    \(Int((settings.minPressure * 100).rounded()))%  \(dim)less does not draw\(reset)",
        "  \(bold)⇧↓↑\(reset) max pressure    \(Int((settings.maxPressure * 100).rounded()))%  \(dim)more is full pressure\(reset)",
        "  \(bold)s\(reset)   smoothing       \(settings.smoothing ? "on" : "off")",
        "  \(bold)r\(reset)   rotation        \(settings.rotation)°  \(dim)\(rotationText)\(reset)",
        "  \(bold)a\(reset)   area map        \(areaText)",
        "  \(bold)w\(reset)   connection      \(link)  \(dim)switch to \(link == "USB" ? "Wi-Fi" : "USB")\(reset)",
        "",
        statusMessage.isEmpty ? "" : "  \u{1B}[33m\(statusMessage)\(reset)",
        "  \(dim)\(statsText)\(reset)",
        "  \(dim)q quit   settings are saved automatically\(reset)",
    ]
    out("\u{1B}[H" + lines.joined(separator: "\u{1B}[K\r\n") + "\u{1B}[K\u{1B}[J")
}
