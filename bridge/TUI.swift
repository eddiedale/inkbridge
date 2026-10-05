// Live terminal panel: pen state, pressure, link stats, and single-key settings.

import Foundation

var tui = false                 // panel is active (set in main)
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

/// Applies key presses. Returns false when the user asked to quit.
func handleKeys(_ bytes: [UInt8]) -> Bool {
    var i = 0
    var changed = false
    while i < bytes.count {
        var key = bytes[i]
        // Arrow keys arrive as ESC [ A..D; map them to u/d/r/l.
        if key == 0x1B, i + 2 < bytes.count, bytes[i + 1] == UInt8(ascii: "[") {
            key = [UInt8(ascii: "A"): UInt8(ascii: "U"), UInt8(ascii: "B"): UInt8(ascii: "D"),
                   UInt8(ascii: "C"): UInt8(ascii: "R"), UInt8(ascii: "D"): UInt8(ascii: "L")][bytes[i + 2]] ?? 0
            i += 2
        }
        i += 1
        switch key {
        case UInt8(ascii: "q"), 3: return false   // 3 = Ctrl-C
        case UInt8(ascii: "R"): settings.curve = min(3, ((settings.curve + 0.1) * 10).rounded() / 10)
        case UInt8(ascii: "L"): settings.curve = max(0.3, ((settings.curve - 0.1) * 10).rounded() / 10)
        case UInt8(ascii: "U"): settings.minPressure = min(settings.maxPressure - 0.1, step(settings.minPressure, 0.01))
        case UInt8(ascii: "D"): settings.minPressure = max(0, step(settings.minPressure, -0.01))
        case UInt8(ascii: "]"): settings.maxPressure = min(1, step(settings.maxPressure, 0.05))
        case UInt8(ascii: "["): settings.maxPressure = max(settings.minPressure + 0.1, step(settings.maxPressure, -0.05))
        case UInt8(ascii: "s"): settings.smoothing.toggle()
        case UInt8(ascii: "r"): settings.rotation = (settings.rotation + 90) % 360
        case UInt8(ascii: "a"): settings.keepAspect.toggle()
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
        "  \(bold)[ ]\(reset) max pressure    \(Int((settings.maxPressure * 100).rounded()))%  \(dim)more is full pressure\(reset)",
        "  \(bold)s\(reset)   smoothing       \(settings.smoothing ? "on" : "off")",
        "  \(bold)r\(reset)   rotation        \(settings.rotation)°  \(dim)\(rotationText)\(reset)",
        "  \(bold)a\(reset)   area map        \(settings.keepAspect ? "keep proportions" : "fill screen")",
        "",
        "  \(dim)\(statsText)\(reset)",
        "  \(dim)q quit   settings are saved automatically\(reset)",
    ]
    out("\u{1B}[H" + lines.joined(separator: "\u{1B}[K\r\n") + "\u{1B}[K\u{1B}[J")
}
