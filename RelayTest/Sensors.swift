import Foundation

/// What the app knows about each board and each sensor, loaded from
/// Boards.json (the device definitions). The screens are built from it: a new
/// board is a new entry there, not new code. Code here only knows how to show
/// each *kind* of reading (an x/y/z, a battery, ...).
///
/// Sensor numbers match t1d-relay-firmware shared/link/sensors.hpp and
/// docs/ble-test-service.md. Numbers are never reused.
struct SensorDef: Identifiable {
    let id: UInt8
    let name: String
    let kind: String
    /// Intervals the picker offers, in ms. All are inside what the board can do.
    let intervals: [Int]
    let defaultInterval: Int
    /// The part on each board that has it (board id -> part).
    var parts: [String: String] = [:]

    func detail(on board: String) -> String {
        parts[Boards.find(board).id] ?? ""
    }

    /// Turns the raw values into one line of text.
    func format(_ v: [Int32]) -> String { Sensors.format(kind, v) }
    /// One number to draw in the little graph, so you can see it react.
    var graphValue: (([Int32]) -> Double)? { Sensors.graph(kind) }
}

struct BoardDef: Decodable {
    struct Updates: Decodable {
        /// nRF Cloud (Memfault) hardware version to fetch releases for, so a
        /// board is only ever offered its own images.
        let hardwareVersion: String
        /// True when a bad Bluetooth chip image rolls back by itself.
        let btRollback: Bool
        /// Shown under the firmware buttons.
        let note: String?
    }
    struct Part: Decodable { let id: UInt8; let part: String }
    let id: String
    let name: String
    let advertisedName: String
    let updates: Updates
    let sensors: [Part]
}

enum Boards {
    private struct File: Decodable {
        struct Sensor: Decodable {
            let id: UInt8
            let name: String
            let kind: String
            let intervals: [Int]
            let `default`: Int
        }
        let sensors: [Sensor]
        let boards: [BoardDef]
    }

    private static let file: File = {
        guard let url = Bundle.main.url(forResource: "Boards", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let f = try? JSONDecoder().decode(File.self, from: data),
              !f.boards.isEmpty else {
            fatalError("Boards.json is missing or broken")
        }
        return f
    }()

    static var all: [BoardDef] { file.boards }

    /// The board a relay says it is ("board" in its Info). Firmware before
    /// 0.5.0 doesn't say; those are all Thingy:91s (the first entry).
    static func find(_ id: String) -> BoardDef {
        all.first { $0.id == id } ?? all[0]
    }

    /// The board a relay is, from its advertised name, before connecting.
    static func fromAdvertisedName(_ name: String) -> BoardDef? {
        all.sorted { $0.advertisedName.count > $1.advertisedName.count }
            .first { name.hasPrefix($0.advertisedName) }
    }

    static let sensors: [SensorDef] = file.sensors.map { s in
        var def = SensorDef(id: s.id, name: s.name, kind: s.kind, intervals: s.intervals,
                            defaultInterval: s.default)
        for b in file.boards {
            if let p = b.sensors.first(where: { $0.id == s.id }) { def.parts[b.id] = p.part }
        }
        return def
    }
}

enum Sensors {
    static let g7States = ["idle", "looking", "one close", "too many", "selected", "lost"]

    static var all: [SensorDef] { Boards.sensors }

    /// The sensors a board has, in the order its definition lists them.
    static func forBoard(_ board: String) -> [SensorDef] {
        Boards.find(board).sensors.compactMap { p in all.first { $0.id == p.id } }
    }

    static func format(_ kind: String, _ v: [Int32]) -> String {
        switch kind {
        case "accel":
            return xyz(v)
        case "gyro":
            guard v.count >= 3 else { return "?" }
            return String(format: "x %+.0f  y %+.0f  z %+.0f °/s",
                          Double(v[0]) / 1000, Double(v[1]) / 1000, Double(v[2]) / 1000)
        case "compass":
            // Heading assumes the board lies flat; Earth's field is 25-65 µT,
            // so a much bigger number means a magnet nearby (or a bad reading).
            guard v.count >= 3 else { return "?" }
            let x = Double(v[0]) / 1000, y = Double(v[1]) / 1000, z = Double(v[2]) / 1000
            var heading = atan2(y, x) * 180 / .pi
            if heading < 0 { heading += 360 }
            let points = ["N", "NE", "E", "SE", "S", "SW", "W", "NW"]
            let point = points[Int((heading + 22.5) / 45) % 8]
            let field = (x * x + y * y + z * z).squareRoot()
            let strength = field > 100 ? " (strong: magnet nearby?)" : ""
            return String(format: "Heading %.0f° %@ · field %.0f µT%@\nx %+.0f  y %+.0f  z %+.0f µT",
                          heading, point, field, strength, x, y, z)
        case "environment":
            guard v.count >= 4 else { return "?" }
            return String(format: "%.1f °C · %.0f%% RH · %.1f hPa · %.1f kΩ",
                          Double(v[0]) / 1000, Double(v[1]) / 1000,
                          Double(v[2]) / 100, Double(v[3]) / 1000)
        case "rgbir":
            guard v.count >= 4 else { return "?" }
            return "R \(v[0])  G \(v[1])  B \(v[2])  IR \(v[3])"
        case "battery":
            guard v.count >= 2 else { return "?" }
            let base = String(format: "%d%% · %.2f V", v[0], Double(v[1]) / 1000)
            guard v.count >= 3 else { return base }
            var text = base + " · " + charger(v[2])
            if v.count >= 4 && v[3] >= 0 {
                text += String(format: " (0x%02X)", v[3])
            }
            return text
        case "fuelgauge":
            guard v.count >= 4 else { return "?" }
            var text = String(format: "%+.1f mA · %.1f °C",
                              Double(v[0]) / 1000, Double(v[1]) / 1000)
            if v[2] >= 0 { text += " · empty in " + duration(v[2]) }
            if v[3] >= 0 { text += " · full in " + duration(v[3]) }
            return text
        case "lte":
            return v.first.map { $0 == 0 ? "no signal" : "\($0) dBm" } ?? "?"
        case "g7":
            guard v.count >= 4 else { return "?" }
            let state = Int(v[0]) < g7States.count ? g7States[Int(v[0])] : "?"
            let rssi = v[1] == 0 ? "" : " · \(v[1]) dBm"
            return "\(state)\(rssi) · \(v[2]) close · \(v[3]) heard"
        case "btstats":
            guard v.count >= 4 else { return "?" }
            return "in \(v[0]) · bad \(v[1]) · dropped \(v[2]) · failed \(v[3])"
        default:
            // A kind this app version doesn't know yet: show the raw numbers.
            return v.map(String.init).joined(separator: " ")
        }
    }

    static func graph(_ kind: String) -> (([Int32]) -> Double)? {
        switch kind {
        case "accel", "gyro": return { v in magnitude(v) }
        case "compass":
            // Graph the heading, so turning the board shows as a line moving.
            return { v in
                guard v.count >= 2 else { return 0 }
                let h = atan2(Double(v[1]), Double(v[0])) * 180 / .pi
                return h < 0 ? h + 360 : h
            }
        case "environment": return { v in Double(v[0]) / 1000 }
        case "rgbir": return { v in Double(v[1]) }
        case "lte": return { v in Double(v[0]) }
        case "fuelgauge": return { v in Double(v[0]) / 1000 }
        default: return nil
        }
    }

    /// Charger state, in the firmware's numbering (ADP5360's, also used for the
    /// nPM1300 on the Thingy:91 X).
    static func charger(_ state: Int32) -> String {
        switch state {
        case 0: return "on battery"
        case 1, 2, 3: return "plugged in, charging"
        case 4: return "plugged in, charged"
        case 5: return "plugged in, not charging"
        case 6: return "plugged in, charging problem"
        case 7: return "plugged in, checking battery"
        default: return "charger ?"
        }
    }

    static func duration(_ s: Int32) -> String {
        s >= 3600 ? String(format: "%d h %02d min", s / 3600, (s % 3600) / 60) : "\(s / 60) min"
    }

    static func xyz(_ v: [Int32]) -> String {
        guard v.count >= 3 else { return "?" }
        return String(format: "x %+.2f  y %+.2f  z %+.2f g",
                      Double(v[0]) / 1000, Double(v[1]) / 1000, Double(v[2]) / 1000)
    }

    static func magnitude(_ v: [Int32]) -> Double {
        guard v.count >= 3 else { return 0 }
        let x = Double(v[0]), y = Double(v[1]), z = Double(v[2])
        return (x * x + y * y + z * z).squareRoot() / 1000
    }

    static func rateLabel(_ ms: Int) -> String {
        if ms >= 1000 {
            let s = Double(ms) / 1000
            return s == s.rounded() ? "every \(Int(s)) s" : String(format: "every %.1f s", s)
        }
        return "\(1000 / ms) per second"
    }
}

/// One notification from the data characteristic.
struct Reading {
    let sensor: UInt8
    let seq: UInt16
    let deviceMs: UInt32
    let failed: Bool
    let values: [Int32]

    /// id, count (0xFF = failed), seq (2), t_ms (4), then int32 values. Little-endian.
    init?(_ data: Data) {
        let b = [UInt8](data)
        guard b.count >= 8 else { return nil }
        sensor = b[0]
        failed = b[1] == 0xFF
        let count = failed ? 1 : Int(b[1])
        guard count <= 4, b.count >= 8 + 4 * count else { return nil }
        seq = UInt16(b[2]) | UInt16(b[3]) << 8
        deviceMs = UInt32(b[4]) | UInt32(b[5]) << 8 | UInt32(b[6]) << 16 | UInt32(b[7]) << 24
        var vals: [Int32] = []
        for i in 0..<count {
            let o = 8 + 4 * i
            let u = UInt32(b[o]) | UInt32(b[o + 1]) << 8 | UInt32(b[o + 2]) << 16 | UInt32(b[o + 3]) << 24
            vals.append(Int32(bitPattern: u))
        }
        values = vals
    }
}
