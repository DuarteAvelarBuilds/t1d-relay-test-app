import Foundation
import os

/// Unified-log loggers, so a Mac with the phone on a cable can follow the app
/// live (`pymobiledevice3 syslog live -m RelayTest`, or Console.app).
/// Notice level so the lines show up without turning on debug logging.
/// Only Bluetooth and update events go here: never glucose or dose values.
enum Log {
    static let ble = Logger(subsystem: "org.duarteavelarbuilds.relaytest", category: "ble")
    static let update = Logger(subsystem: "org.duarteavelarbuilds.relaytest", category: "update")

    /// Milliseconds since the app started, for lining up with the board console.
    static func ms() -> Int { Int(Date().timeIntervalSince(launched) * 1000) }
    private static let launched = Date()

    static func hex(_ d: Data) -> String { d.map { String(format: "%02x", $0) }.joined() }
}
