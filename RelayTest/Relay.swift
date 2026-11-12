import CoreBluetooth
import Foundation

/// What the screen shows for one sensor. Rebuilt a few times a second, so
/// fast sensors don't make the screen redraw 100 times a second.
struct SensorRow: Identifiable {
    let id: UInt8
    var enabled = true
    var interval: Int
    var text = "waiting…"
    var perSecond = 0.0
    var received = 0
    var missed = 0
    var failedText: String?
    var lastUpdate: Date?
    var graph: [Double] = []
}

/// Talks to the relay's Bluetooth test service.
final class Relay: NSObject, ObservableObject {
    static let serviceUUID = CBUUID(string: "42800001-C846-48AD-9A69-38EF49048320")
    static let dataUUID = CBUUID(string: "42800002-C846-48AD-9A69-38EF49048320")
    static let controlUUID = CBUUID(string: "42800003-C846-48AD-9A69-38EF49048320")
    static let infoUUID = CBUUID(string: "42800004-C846-48AD-9A69-38EF49048320")
    static let updateUUID = CBUUID(string: "42800005-C846-48AD-9A69-38EF49048320")
    /// mcumgr (SMP) over Bluetooth, for updating the controller itself.
    static let smpServiceUUID = CBUUID(string: "8D53DC1D-1DB7-4CD3-868B-8A527460AA84")
    static let smpUUID = CBUUID(string: "DA2E7828-FBCE-4E01-AE9E-261174997C48")

    enum Status: Equatable {
        case bluetoothOff, scanning, connecting, reconnecting, connected, disconnected(String)
    }

    struct Found: Identifiable {
        let id: UUID
        let peripheral: CBPeripheral
        var name: String
        var rssi: Int
    }

    @Published var status: Status = .bluetoothOff
    @Published var found: [Found] = []
    @Published var rows: [SensorRow] = Sensors.forBoard("").map { SensorRow(id: $0.id, interval: $0.defaultInterval) }
    @Published var info = ""
    @Published var linkRssi: Int?
    let updater = Updater()

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var control: CBCharacteristic?
    private var infoChar: CBCharacteristic?
    private var refresh: Timer?
    /// The user tapped Disconnect, so don't reconnect by ourselves.
    private var userDisconnected = false
    private var ticks = 0

    /// Raw per-sensor state, updated on every notification (not published).
    private struct Live {
        var lastSeq: UInt16?
        var received = 0
        var missed = 0
        var values: [Int32] = []
        var failedText: String?
        var lastUpdate: Date?
        var arrivals: [Date] = []
        var graph: [Double] = []
    }
    private var live: [UInt8: Live] = [:]

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: .main)
        updater.stopStreams = { [weak self] in self?.allOff() }
    }

    /// Every sensor off (during a firmware update).
    func allOff() {
        for i in rows.indices { rows[i].enabled = false }
        if let p = peripheral, let c = control {
            p.writeValue(Data([2]), for: c, type: .withResponse)
        }
    }

    // MARK: Actions

    func startScan() {
        guard central.state == .poweredOn else { return }
        found = []
        status = .scanning
        // No service filter: iOS may not match a UUID that is only in the scan
        // response, so look at everything and pick the relay out below.
        central.scanForPeripherals(withServices: nil,
                                   options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
    }

    func connect(_ f: Found) {
        central.stopScan()
        peripheral = f.peripheral
        f.peripheral.delegate = self
        status = .connecting
        userDisconnected = false
        central.connect(f.peripheral)
    }

    func disconnect() {
        userDisconnected = true
        if let p = peripheral {
            central.cancelPeripheralConnection(p)
        }
    }

    func setEnabled(_ id: UInt8, _ on: Bool) {
        guard let i = rows.firstIndex(where: { $0.id == id }) else { return }
        rows[i].enabled = on
        sendRate(id, on ? rows[i].interval : 0)
    }

    func setInterval(_ id: UInt8, _ ms: Int) {
        guard let i = rows.firstIndex(where: { $0.id == id }) else { return }
        rows[i].interval = ms
        rows[i].enabled = true
        live[id] = Live() // fresh counts for the new rate
        sendRate(id, ms)
    }

    // MARK: Private

    private func sendRate(_ id: UInt8, _ ms: Int) {
        guard let p = peripheral, let c = control else { return }
        let v = UInt16(clamping: ms)
        p.writeValue(Data([1, id, UInt8(v & 0xFF), UInt8(v >> 8)]), for: c, type: .withResponse)
    }

    /// Show (and stream) only the sensors this board has.
    private func setBoard(_ board: String) {
        let defs = Sensors.forBoard(board)
        let old = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })
        rows = defs.map { old[$0.id] ?? SensorRow(id: $0.id, interval: $0.defaultInterval) }
        if status == .connected {
            for row in rows where row.enabled && old[row.id] == nil {
                sendRate(row.id, row.interval)
            }
        }
    }

    private func startAll() {
        live = [:]
        for row in rows where row.enabled {
            sendRate(row.id, row.interval)
        }
        refresh?.invalidate()
        refresh = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            self?.publish()
        }
    }

    private func handle(_ r: Reading) {
        var l = live[r.sensor] ?? Live()
        let now = Date()
        if let last = l.lastSeq {
            let gap = Int(r.seq &- last) - 1
            // A big jump means the stream restarted, not that thousands were lost.
            if gap > 0 && gap < 1000 { l.missed += gap }
        }
        l.lastSeq = r.seq
        l.received += 1
        l.lastUpdate = now
        l.arrivals.append(now)
        if r.failed {
            l.failedText = "read failed (error \(r.values.first ?? 0))"
        } else {
            l.failedText = nil
            l.values = r.values
            if let def = Sensors.all.first(where: { $0.id == r.sensor }), let g = def.graphValue {
                l.graph.append(g(r.values))
                if l.graph.count > 60 { l.graph.removeFirst(l.graph.count - 60) }
            }
        }
        live[r.sensor] = l
    }

    private func publish() {
        let now = Date()
        for i in rows.indices {
            let id = rows[i].id
            guard var l = live[id] else { continue }
            // Updates per second over the last 2 seconds.
            l.arrivals.removeAll { now.timeIntervalSince($0) > 2 }
            live[id] = l
            rows[i].perSecond = Double(l.arrivals.count) / 2
            rows[i].received = l.received
            rows[i].missed = l.missed
            rows[i].failedText = l.failedText
            rows[i].lastUpdate = l.lastUpdate
            rows[i].graph = l.graph
            if let def = Sensors.all.first(where: { $0.id == id }), !l.values.isEmpty {
                rows[i].text = def.format(l.values)
            }
        }
        peripheral?.readRSSI()
        // The application chip's version and serial reach the Info text a little
        // after connecting, so read it again now and then.
        ticks += 1
        if ticks % 20 == 0, let p = peripheral, let c = infoChar {
            p.readValue(for: c)
        }
    }

    private func reset(_ why: String) {
        refresh?.invalidate()
        refresh = nil
        peripheral = nil
        control = nil
        infoChar = nil
        linkRssi = nil
        updater.connectionLost(userAsked: userDisconnected)
        updater.peripheral = nil
        updater.smp = nil
        updater.update = nil
        updater.control = nil
        status = .disconnected(why)
    }
}

extension Relay: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        if central.state == .poweredOn {
            startScan()
        } else {
            status = .bluetoothOff
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let name = (advertisementData[CBAdvertisementDataLocalNameKey] as? String)
            ?? peripheral.name ?? ""
        let services = advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? []
        guard services.contains(Self.serviceUUID) || name.localizedCaseInsensitiveContains("T1D") else {
            return
        }
        let shown = name.isEmpty ? "T1D relay" : name
        if let i = found.firstIndex(where: { $0.id == peripheral.identifier }) {
            found[i].rssi = RSSI.intValue
            found[i].name = shown
        } else {
            found.append(Found(id: peripheral.identifier, peripheral: peripheral, name: shown,
                               rssi: RSSI.intValue))
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        Log.ble.notice("t=\(Log.ms()) connected, max write \(peripheral.maximumWriteValueLength(for: .withoutResponse)) B")
        peripheral.discoverServices([Self.serviceUUID, Self.smpServiceUUID])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral,
                        error: Error?) {
        Log.ble.notice("t=\(Log.ms()) connect failed: \(error?.localizedDescription ?? "unknown", privacy: .public)")
        reset("Couldn't connect: \(error?.localizedDescription ?? "unknown")")
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral,
                        error: Error?) {
        Log.ble.notice("t=\(Log.ms()) disconnected: \(error?.localizedDescription ?? "by request", privacy: .public)")
        reset(error.map { "Connection lost: \($0.localizedDescription)" } ?? "Disconnected")
        // The relay restarts after a firmware update, or wanders out of range:
        // ask iOS to reconnect as soon as it's back (a pending connect never times out).
        if !userDisconnected {
            self.peripheral = peripheral
            peripheral.delegate = self
            status = .reconnecting
            central.connect(peripheral)
        }
    }
}

extension Relay: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let s = peripheral.services?.first(where: { $0.uuid == Self.serviceUUID }) else {
            disconnect()
            return
        }
        peripheral.discoverCharacteristics([Self.dataUUID, Self.controlUUID, Self.infoUUID,
                                            Self.updateUUID], for: s)
        if let smp = peripheral.services?.first(where: { $0.uuid == Self.smpServiceUUID }) {
            peripheral.discoverCharacteristics([Self.smpUUID], for: smp)
        }
        updater.peripheral = peripheral
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService,
                    error: Error?) {
        for c in service.characteristics ?? [] {
            switch c.uuid {
            case Self.dataUUID: peripheral.setNotifyValue(true, for: c)
            case Self.controlUUID:
                control = c
                updater.control = c
            case Self.infoUUID:
                infoChar = c
                peripheral.readValue(for: c)
            case Self.updateUUID:
                updater.update = c
                peripheral.setNotifyValue(true, for: c)
            case Self.smpUUID:
                updater.smp = c
                peripheral.setNotifyValue(true, for: c)
            default: break
            }
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic,
                    error: Error?) {
        Log.ble.notice("t=\(Log.ms()) notify \(characteristic.uuid.uuidString, privacy: .public) on=\(characteristic.isNotifying) error=\(error?.localizedDescription ?? "none", privacy: .public)")
        if characteristic.uuid == Self.dataUUID && characteristic.isNotifying {
            status = .connected
            startAll()
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic,
                    error: Error?) {
        if let error {
            Log.ble.notice("t=\(Log.ms()) value error on \(characteristic.uuid.uuidString, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
        guard let data = characteristic.value else { return }
        switch characteristic.uuid {
        case Self.dataUUID:
            if let r = Reading(data) { handle(r) }
        case Self.infoUUID:
            info = String(decoding: data, as: UTF8.self)
            let oldBoard = updater.board
            updater.parseInfo(info)
            if updater.board != oldBoard || rows.map(\.id) != Sensors.forBoard(updater.board).map(\.id) {
                setBoard(updater.board)
            }
        case Self.updateUUID:
            updater.updateNotification(data)
        case Self.smpUUID:
            updater.smpResponse(data)
        default:
            break
        }
    }

    func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        updater.pump()
    }

    func peripheral(_ peripheral: CBPeripheral, didReadRSSI RSSI: NSNumber, error: Error?) {
        if error == nil { linkRssi = RSSI.intValue }
    }
}
