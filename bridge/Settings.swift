// Settings that can be tuned live in the TUI, saved between runs.

import Foundation

let configDir = FileManager.default.homeDirectoryForCurrentUser.path + "/.config/inkbridge"

enum Area: String { case fill, keep, crop }

struct Settings {
    var rotation = 90         // how far the tablet is turned clockwise from portrait
    var area = Area.fill      // how the tablet maps onto the display (see Mapping)
    var curve = 1.5           // pressure exponent: below 1 is soft, above 1 is firm
    var minPressure = 0.03    // raw pressure needed to start a stroke (0...1)
    var maxPressure = 0.8     // raw pressure that gives full output (0...1)
    var smoothing = true      // smooth the ~38 Hz pressure updates between reports
    var useWifi = false       // connect over Wi-Fi at start (falls back to USB)
    var wifiHost = ""         // tablet's Wi-Fi address, found when switching from USB

    static let path = configDir + "/settings.json"

    static func load() -> Settings {
        var s = Settings()
        guard let data = FileManager.default.contents(atPath: path),
              let d = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return s }
        if let v = d["rotation"] as? Int, [0, 90, 180, 270].contains(v) { s.rotation = v }
        if let v = d["area"] as? String, let a = Area(rawValue: v) { s.area = a }
        else if d["keepAspect"] as? Bool == true { s.area = .keep }   // older settings files
        if let v = d["curve"] as? Double { s.curve = v }
        if let v = d["minPressure"] as? Double { s.minPressure = v }
        if let v = d["maxPressure"] as? Double { s.maxPressure = v }
        if let v = d["smoothing"] as? Bool { s.smoothing = v }
        if let v = d["useWifi"] as? Bool { s.useWifi = v }
        if let v = d["wifiHost"] as? String { s.wifiHost = v }
        return s
    }

    func save() {
        // Decimal keeps the file tidy (0.04, not 0.040000000000000001).
        func round2(_ v: Double) -> NSDecimalNumber { NSDecimalNumber(string: String(format: "%.2f", v)) }
        let d: [String: Any] = ["rotation": rotation, "area": area.rawValue, "curve": round2(curve),
                                "minPressure": round2(minPressure), "maxPressure": round2(maxPressure),
                                "smoothing": smoothing, "useWifi": useWifi, "wifiHost": wifiHost]
        try? FileManager.default.createDirectory(atPath: configDir, withIntermediateDirectories: true)
        if let data = try? JSONSerialization.data(withJSONObject: d, options: [.prettyPrinted, .sortedKeys]) {
            FileManager.default.createFile(atPath: Settings.path, contents: data)
        }
    }

    /// Raw pressure (0...1) to output pressure: zero below min pressure, full
    /// from max pressure, rescaled to 0...1 in between and bent by the curve.
    func shape(_ p: Double) -> Double {
        guard p > minPressure else { return 0 }
        return pow(min(1, (p - minPressure) / (maxPressure - minPressure)), curve)
    }
}

var settings = Settings.load()

/// Time constant of the pressure smoothing, in seconds.
let pressureSmoothing = 0.012
