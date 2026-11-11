import Foundation

/// The relay's sensors, as numbered in the firmware
/// (t1d-relay-firmware: shared/link/sensors.hpp and docs/ble-test-service.md).
/// Add a sensor in both places. Numbers 20 and up are the Thingy:91 X's own.
struct SensorDef: Identifiable {
    let id: UInt8
    let name: String
    let detail: String
    /// Intervals the picker offers, in ms. All are inside what the board can do.
    let intervals: [Int]
    let defaultInterval: Int
    /// Turns the raw values into one line of text.
    let format: ([Int32]) -> String
    /// One number to draw in the little graph, so you can see it react.
    let graphValue: (([Int32]) -> Double)?
    /// Boards that have it ("thingy91", "thingy91x"); nil = every board.
    var boards: Set<String>? = nil
    /// The part's name on the Thingy:91 X, where it differs.
    var detailX: String? = nil

    func detail(on board: String) -> String {
        board == Sensors.thingy91x ? (detailX ?? detail) : detail
    }
}

enum Sensors {
    static let thingy91 = "thingy91"
    static let thingy91x = "thingy91x"

    /// The sensors a board has. Firmware before 0.5.0 doesn't say its board;
    /// those are all Thingy:91s.
    static func forBoard(_ board: String) -> [SensorDef] {
        let b = board.isEmpty ? thingy91 : board
        return all.filter { $0.boards?.contains(b) ?? true }
    }

    static let g7States = ["idle", "looking", "one close", "too many", "selected", "lost"]

    static let all: [SensorDef] = [
        SensorDef(id: 1, name: "Motion", detail: "ADXL362 accelerometer, ±8 g",
                  intervals: [1000, 200, 100, 50, 20, 10], defaultInterval: 100,
                  format: { v in Sensors.xyz(v) },
                  graphValue: { v in Sensors.magnitude(v) },
                  detailX: "ADXL367 accelerometer"),
        SensorDef(id: 2, name: "Impact", detail: "ADXL372, ±200 g, biggest hit since last reading",
                  intervals: [1000, 200, 100, 50, 20, 10], defaultInterval: 100,
                  format: { v in Sensors.xyz(v) },
                  graphValue: { v in Sensors.magnitude(v) },
                  boards: [Sensors.thingy91]),
        SensorDef(id: 3, name: "Environment", detail: "BME680",
                  intervals: [5000, 2000, 1000, 500, 200], defaultInterval: 1000,
                  format: { v in
                      guard v.count >= 4 else { return "?" }
                      return String(format: "%.1f °C · %.0f%% RH · %.1f hPa · %.1f kΩ",
                                    Double(v[0]) / 1000, Double(v[1]) / 1000,
                                    Double(v[2]) / 100, Double(v[3]) / 1000)
                  },
                  graphValue: { v in Double(v[0]) / 1000 },
                  detailX: "BME688"),
        SensorDef(id: 4, name: "Light", detail: "BH1749 colour sensor",
                  intervals: [2000, 1000, 500, 250, 125], defaultInterval: 500,
                  format: { v in
                      guard v.count >= 4 else { return "?" }
                      return "R \(v[0])  G \(v[1])  B \(v[2])  IR \(v[3])"
                  },
                  graphValue: { v in Double(v[1]) },
                  boards: [Sensors.thingy91]),
        SensorDef(id: 5, name: "Battery", detail: "ADP5360 fuel gauge and charger",
                  intervals: [10000, 5000, 1000], defaultInterval: 5000,
                  format: { v in
                      guard v.count >= 2 else { return "?" }
                      let base = String(format: "%d%% · %.2f V", v[0], Double(v[1]) / 1000)
                      guard v.count >= 3 else { return base }
                      var text = base + " · " + Sensors.charger(v[2])
                      if v.count >= 4 && v[3] >= 0 {
                          text += String(format: " (0x%02X)", v[3])
                      }
                      return text
                  },
                  graphValue: nil,
                  detailX: "nPM1300 charger + nRF Fuel Gauge"),
        SensorDef(id: 6, name: "LTE signal", detail: "Modem RSRP",
                  intervals: [10000, 5000, 2000, 1000], defaultInterval: 2000,
                  format: { v in v.first.map { $0 == 0 ? "no signal" : "\($0) dBm" } ?? "?" },
                  graphValue: { v in Double(v[0]) }),
        SensorDef(id: 7, name: "G7", detail: "Pairing status on the Bluetooth chip",
                  intervals: [5000, 2000, 1000], defaultInterval: 1000,
                  format: { v in
                      guard v.count >= 4 else { return "?" }
                      let state = Int(v[0]) < Sensors.g7States.count ? Sensors.g7States[Int(v[0])] : "?"
                      let rssi = v[1] == 0 ? "" : " · \(v[1]) dBm"
                      return "\(state)\(rssi) · \(v[2]) close · \(v[3]) heard"
                  },
                  graphValue: nil),
        SensorDef(id: 8, name: "Bluetooth chip", detail: "Link lines in / bad / dropped, failed sends",
                  intervals: [5000, 1000], defaultInterval: 1000,
                  format: { v in
                      guard v.count >= 4 else { return "?" }
                      return "in \(v[0]) · bad \(v[1]) · dropped \(v[2]) · failed \(v[3])"
                  },
                  graphValue: nil),
        // Thingy:91 X only.
        SensorDef(id: 20, name: "Gyro", detail: "BMI270 gyroscope, ±2000 °/s",
                  intervals: [1000, 200, 100, 50, 20], defaultInterval: 100,
                  format: { v in
                      guard v.count >= 3 else { return "?" }
                      return String(format: "x %+.0f  y %+.0f  z %+.0f °/s",
                                    Double(v[0]) / 1000, Double(v[1]) / 1000, Double(v[2]) / 1000)
                  },
                  graphValue: { v in Sensors.magnitude(v) },
                  boards: [Sensors.thingy91x]),
        SensorDef(id: 23, name: "IMU accelerometer", detail: "BMI270 accelerometer, ±8 g",
                  intervals: [1000, 200, 100, 50, 20], defaultInterval: 100,
                  format: { v in Sensors.xyz(v) },
                  graphValue: { v in Sensors.magnitude(v) },
                  boards: [Sensors.thingy91x]),
        SensorDef(id: 21, name: "Compass", detail: "BMM350 magnetometer",
                  intervals: [1000, 500, 200, 100], defaultInterval: 200,
                  format: { v in
                      guard v.count >= 3 else { return "?" }
                      let x = Double(v[0]) / 1000, y = Double(v[1]) / 1000
                      var heading = atan2(y, x) * 180 / .pi
                      if heading < 0 { heading += 360 }
                      return String(format: "x %+.1f  y %+.1f  z %+.1f µT · %.0f°",
                                    x, y, Double(v[2]) / 1000, heading)
                  },
                  graphValue: { v in Sensors.magnitude(v) },
                  boards: [Sensors.thingy91x]),
        SensorDef(id: 22, name: "Fuel gauge", detail: "nPM1300 + nRF Fuel Gauge details",
                  intervals: [10000, 5000], defaultInterval: 5000,
                  format: { v in
                      guard v.count >= 4 else { return "?" }
                      var text = String(format: "%+.1f mA · %.1f °C", Double(v[0]) / 1000,
                                        Double(v[1]) / 1000)
                      if v[2] >= 0 { text += " · empty in " + Sensors.duration(v[2]) }
                      if v[3] >= 0 { text += " · full in " + Sensors.duration(v[3]) }
                      return text
                  },
                  graphValue: { v in Double(v[0]) / 1000 },
                  boards: [Sensors.thingy91x]),
    ]

    static func duration(_ s: Int32) -> String {
        s >= 3600 ? String(format: "%d h %02d min", s / 3600, (s % 3600) / 60) : "\(s / 60) min"
    }

    /// ADP5360 charger status (firmware 0.4.2 and later).
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
