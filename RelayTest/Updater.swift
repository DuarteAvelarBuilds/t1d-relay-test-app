import CoreBluetooth
import Foundation

/// Firmware updates from the phone (t1d-relay-firmware docs/ble-test-service.md).
///
/// - Release files come from nRF Cloud (Memfault): software type "bt" for the
///   Bluetooth chip, "app" for the LTE chip, hardware version "thingy91".
/// - Bluetooth chip: mcumgr (SMP) image upload over Bluetooth, then control
///   op 03 boots it on trial.
/// - LTE chip: no Bluetooth of its own, so the image goes to the Bluetooth
///   chip's LTE-update characteristic, which passes it over the wires, in
///   768-byte windows that the LTE chip acknowledges.
///
/// Both chips boot a new image on trial and roll back unless it confirms
/// itself, so a failed or interrupted update leaves the old firmware running.
final class Updater: ObservableObject {
    enum Chip: String { case bt = "Bluetooth chip", lte = "LTE chip" }

    struct Release: Equatable {
        let version: String
        let url: URL
        let size: Int
    }

    @Published var btVersion = "?"
    @Published var lteVersion = "?"
    @Published var serial = ""
    @Published var latestBt: Release?
    @Published var latestLte: Release?
    @Published var checked = false
    @Published var busy: Chip?
    @Published var progress = 0.0
    @Published var message = ""

    /// Set by Relay once the characteristics are found.
    weak var peripheral: CBPeripheral?
    var smp: CBCharacteristic?
    var update: CBCharacteristic?
    var control: CBCharacteristic?
    /// Turns the sensor stream off for the transfer.
    var stopStreams: () -> Void = {}

    private var image = Data()
    private var acked = 0
    /// Retries since the chip last answered; the update gives up after 3.
    private var tries = 0
    private var timer: Timer?
    private var smpSeq: UInt8 = 0
    /// Writes waiting for iOS to have room. Writes without response sent while
    /// canSendWriteWithoutResponse is false can be dropped silently.
    private var outbox: [(Data, CBCharacteristic)] = []
    private var started = Date()

    static let projectKey = (Bundle.main.object(forInfoDictionaryKey: "MemfaultProjectKey") as? String) ?? ""

    // MARK: Device info

    /// "relay-bt 0.4.2 link 3 lte 0.4.4 serial 352656101102872"
    func parseInfo(_ text: String) {
        let w = text.split(separator: " ").map(String.init)
        func after(_ key: String) -> String? {
            guard let i = w.firstIndex(of: key), i + 1 < w.count else { return nil }
            return w[i + 1]
        }
        btVersion = after("relay-bt") ?? "?"
        lteVersion = after("lte") ?? "?"
        serial = after("serial") ?? ""
    }

    // MARK: nRF Cloud

    func check() {
        guard !Self.projectKey.isEmpty else {
            message = "This build has no nRF Cloud project key (see the README)."
            return
        }
        guard !serial.isEmpty else {
            message = "Waiting for the LTE chip to send its serial… try again in a few seconds."
            return
        }
        message = "Checking nRF Cloud…"
        Task { @MainActor in
            do {
                latestBt = try await latest(type: "bt")
                latestLte = try await latest(type: "app")
                checked = true
                message = ""
            } catch {
                message = "Couldn't check: \(error.localizedDescription)"
            }
        }
    }

    private func latest(type: String) async throws -> Release? {
        var c = URLComponents(string: "https://device.memfault.com/api/v0/releases/latest")!
        c.queryItems = [
            URLQueryItem(name: "device_serial", value: serial),
            URLQueryItem(name: "hardware_version", value: "thingy91"),
            URLQueryItem(name: "software_type", value: type),
            // Ask as if from 0.0.0 so the newest release always comes back.
            URLQueryItem(name: "current_version", value: "0.0.0"),
        ]
        var req = URLRequest(url: c.url!)
        req.setValue(Self.projectKey, forHTTPHeaderField: "Memfault-Project-Key")
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if code == 204 || code == 404 { return nil }
        guard code == 200 else { throw UpdateError("nRF Cloud answered \(code)") }
        struct Artifact: Decodable { let url: String; let file_size: Int?; let component_version: String? }
        struct Body: Decodable { let version: String; let artifacts: [Artifact]; let component_version: String? }
        let body = try JSONDecoder().decode(Body.self, from: data)
        guard let a = body.artifacts.first, let url = URL(string: a.url) else { return nil }
        // The Bluetooth chip is a component of the LTE chip's release, so the
        // release version is the LTE one. The image's own MCUboot header says
        // which version it really is; read just its first 32 bytes.
        let version = try? await imageVersion(url)
        return Release(version: version ?? a.component_version ?? body.component_version ?? body.version,
                       url: url, size: a.file_size ?? 0)
    }

    /// Version from an MCUboot image header (magic 0x96f3b83d, version at byte 20).
    private func imageVersion(_ url: URL) async throws -> String? {
        var req = URLRequest(url: url)
        req.setValue("bytes=0-31", forHTTPHeaderField: "Range")
        let (data, _) = try await URLSession.shared.data(for: req)
        let b = [UInt8](data.prefix(32))
        guard b.count >= 24 else { return nil }
        let magic = UInt32(b[0]) | UInt32(b[1]) << 8 | UInt32(b[2]) << 16 | UInt32(b[3]) << 24
        guard magic == 0x96f3_b83d else { return nil }
        let rev = Int(b[22]) | Int(b[23]) << 8
        return "\(b[20]).\(b[21]).\(rev)"
    }

    // MARK: Start

    func start(_ chip: Chip) {
        guard busy == nil, let rel = chip == .bt ? latestBt : latestLte else { return }
        guard peripheral != nil, (chip == .bt ? smp : update) != nil else {
            message = chip == .bt
                ? "The Bluetooth chip has no update service (firmware before 0.4.2)."
                : "The Bluetooth chip can't pass updates on (firmware before 0.4.2)."
            return
        }
        busy = chip
        progress = 0
        message = "Downloading \(chip.rawValue) \(rel.version)…"
        stopStreams()
        Task { @MainActor in
            do {
                let (data, _) = try await URLSession.shared.data(from: rel.url)
                image = data
                acked = 0
                tries = 0
                started = Date()
                message = "Sending \(chip.rawValue) \(rel.version) (\(data.count / 1024) KB)…"
                if chip == .bt { smpSend() } else { lteBegin() }
            } catch {
                finish("Download failed: \(error.localizedDescription)")
            }
        }
    }

    func connectionLost() {
        if busy != nil {
            finish("The connection dropped. Nothing changed; connect and try again.")
        }
    }

    private func finish(_ text: String) {
        outbox.removeAll()
        timer?.invalidate()
        timer = nil
        busy = nil
        message = text
    }

    private func arm(_ seconds: TimeInterval, _ retry: @escaping () -> Void) {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self] _ in
            guard let self, self.busy != nil else { return }
            self.tries += 1
            if self.tries > 3 {
                self.finish("No answer from the Bluetooth chip, so the update stopped. Nothing was installed. Disconnect, connect again and retry.")
            } else {
                self.outbox.removeAll() // a retry sends it all again
                retry()
            }
        }
    }

    private func showProgress() {
        progress = image.isEmpty ? 0 : Double(acked) / Double(image.count)
        let secs = Date().timeIntervalSince(started)
        if secs > 2 && acked > 0 {
            let left = secs / Double(acked) * Double(image.count - acked)
            message = "Sending… \(Int(progress * 100))%, about \(Int(left)) s left"
        }
    }

    // MARK: Bluetooth chip: mcumgr image upload

    private func smpSend() {
        guard let p = peripheral, let c = smp else { return }
        let first = acked == 0
        let room = p.maximumWriteValueLength(for: .withoutResponse) - 8 - (first ? 50 : 24)
        let n = min(max(room, 20), image.count - acked)
        var body = CBOR.mapHeader(first ? 4 : 2)
        if first {
            body += CBOR.text("image") + CBOR.uint(0)
            body += CBOR.text("len") + CBOR.uint(UInt64(image.count))
        }
        body += CBOR.text("off") + CBOR.uint(UInt64(acked))
        body += CBOR.text("data") + CBOR.bytes(image.subdata(in: acked..<acked + n))
        smpSeq &+= 1
        // op 2 = write, group 1 = image, id 1 = upload
        var packet = Data([2, 0, UInt8(body.count >> 8), UInt8(body.count & 0xFF), 0, 1, smpSeq, 1])
        packet += body
        // Reassembly on the chip lets one request span several writes.
        let mtu = max(p.maximumWriteValueLength(for: .withoutResponse), 20)
        var i = packet.startIndex
        while i < packet.endIndex {
            let j = min(i + mtu, packet.endIndex)
            queueWrite(packet.subdata(in: i..<j), c)
            i = j
        }
        arm(5) { [weak self] in self?.smpSend() }
    }

    func smpResponse(_ data: Data) {
        guard busy == .bt, data.count > 8, data[data.startIndex + 5] == 1 else { return }
        let fields = CBOR.intMap(data.dropFirst(8))
        if let rc = fields["rc"], rc != 0 {
            finish("The Bluetooth chip refused the image (mcumgr error \(rc)).")
            return
        }
        guard let off = fields["off"] else { return }
        acked = Int(off)
        tries = 0
        showProgress()
        if acked >= image.count {
            timer?.invalidate()
            message = "Restarting the Bluetooth chip on the new firmware…"
            if let p = peripheral, let c = control {
                p.writeValue(Data([3]), for: c, type: .withResponse)
            }
            busy = nil
            message = "Bluetooth chip restarting on the new firmware. Connect again in about 30 s; it keeps the update once it's talked to the LTE chip for a minute."
        } else {
            smpSend()
        }
    }

    // MARK: LTE chip: through the Bluetooth chip

    private static let window = 768
    private static let piece = 192

    private func lteBegin() {
        write([0x10] + le32(UInt32(image.count)))
        arm(3) { [weak self] in self?.lteBegin() }
    }

    private func lteSendWindow() {
        let end = min(acked + Self.window, image.count)
        var off = acked
        while off < end {
            let n = min(Self.piece, end - off)
            write([0x11] + le32(UInt32(off)) + [UInt8](image.subdata(in: off..<off + n)))
            off += n
        }
        arm(3) { [weak self] in self?.lteSendWindow() }
    }

    func updateNotification(_ data: Data) {
        guard busy == .lte, data.count >= 5 else { return }
        let b = [UInt8](data)
        let v = UInt32(b[1]) | UInt32(b[2]) << 8 | UInt32(b[3]) << 16 | UInt32(b[4]) << 24
        if b[0] == 0x21 {
            finish("The LTE chip refused the image (error \(Int32(bitPattern: v))).")
            return
        }
        guard b[0] == 0x20 else { return }
        acked = Int(v)
        tries = 0
        showProgress()
        if acked >= image.count {
            timer?.invalidate()
            write([0x12])
            busy = nil
            message = "LTE chip restarting on the new firmware. It keeps it once it's on LTE for a minute; reconnect to see the new version."
        } else {
            lteSendWindow()
        }
    }

    private func write(_ bytes: [UInt8]) {
        guard let c = update else { return }
        queueWrite(Data(bytes), c)
    }

    private func queueWrite(_ data: Data, _ c: CBCharacteristic) {
        outbox.append((data, c))
        pump()
    }

    /// Sends queued writes while iOS has room; Relay calls this again from
    /// peripheralIsReady(toSendWriteWithoutResponse:).
    func pump() {
        guard let p = peripheral else { outbox.removeAll(); return }
        while let next = outbox.first, p.canSendWriteWithoutResponse {
            p.writeValue(next.0, for: next.1, type: .withoutResponse)
            outbox.removeFirst()
        }
    }

    private func le32(_ v: UInt32) -> [UInt8] {
        [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8(v >> 24)]
    }
}

struct UpdateError: LocalizedError {
    let text: String
    init(_ text: String) { self.text = text }
    var errorDescription: String? { text }
}

/// Just enough CBOR for mcumgr requests and responses.
enum CBOR {
    static func head(_ major: UInt8, _ v: UInt64) -> Data {
        let m = major << 5
        switch v {
        case 0..<24: return Data([m | UInt8(v)])
        case 24..<256: return Data([m | 24, UInt8(v)])
        case 256..<65536: return Data([m | 25, UInt8(v >> 8), UInt8(v & 0xFF)])
        default:
            return Data([m | 26, UInt8((v >> 24) & 0xFF), UInt8((v >> 16) & 0xFF),
                         UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)])
        }
    }
    static func uint(_ v: UInt64) -> Data { head(0, v) }
    static func bytes(_ d: Data) -> Data { head(2, UInt64(d.count)) + d }
    static func text(_ s: String) -> Data { let d = Data(s.utf8); return head(3, UInt64(d.count)) + d }
    static func mapHeader(_ n: Int) -> Data { head(5, UInt64(n)) }

    /// The integer values of a top-level map with text keys; other values are skipped.
    /// Zephyr's mcumgr (zcbor) sends indefinite-length maps (0xBF ... 0xFF).
    static func intMap(_ data: Data) -> [String: Int64] {
        var r = Reader(bytes: [UInt8](data))
        var out: [String: Int64] = [:]
        guard let (major, count) = r.head(), major == 5 else { return out }
        var i: UInt64 = 0
        while count == Reader.indefinite ? !r.atBreak() : i < count {
            i += 1
            guard let (km, klen) = r.head(), km == 3, let key = r.take(Int(klen)) else { return out }
            let name = String(decoding: key, as: UTF8.self)
            let save = r.pos
            if let (vm, v) = r.head(), vm == 0 || vm == 1 {
                out[name] = vm == 0 ? Int64(v) : -1 - Int64(v)
            } else {
                r.pos = save
                if !r.skip() { return out }
            }
        }
        return out
    }

    struct Reader {
        /// Length of an indefinite-length item; it ends with a 0xFF break.
        static let indefinite = UInt64.max
        let bytes: [UInt8]
        var pos = 0
        mutating func head() -> (UInt8, UInt64)? {
            guard pos < bytes.count else { return nil }
            let b = bytes[pos]; pos += 1
            let major = b >> 5, info = b & 31
            switch info {
            case 0..<24: return (major, UInt64(info))
            case 24, 25, 26, 27:
                let n = 1 << Int(info - 24)
                guard let raw = take(n) else { return nil }
                return (major, raw.reduce(0) { $0 << 8 | UInt64($1) })
            case 31 where major >= 2 && major <= 5: return (major, Self.indefinite)
            default: return nil
            }
        }
        /// At a 0xFF break: consume it and say so. Also true at the end of the data.
        mutating func atBreak() -> Bool {
            guard pos < bytes.count else { return true }
            if bytes[pos] == 0xFF { pos += 1; return true }
            return false
        }
        mutating func take(_ n: Int) -> [UInt8]? {
            guard n >= 0, pos + n <= bytes.count else { return nil }
            defer { pos += n }
            return Array(bytes[pos..<pos + n])
        }
        mutating func skip() -> Bool {
            guard let (major, v) = head() else { return false }
            switch major {
            case 0, 1, 7: return true
            case 2, 3 where v == Self.indefinite:
                while !atBreak() { if !skip() { return false } }
                return true
            case 2, 3: return take(Int(v)) != nil
            case 4, 5 where v == Self.indefinite:
                while !atBreak() {
                    if !skip() { return false }
                    if major == 5 && !skip() { return false }
                }
                return true
            case 4, 5:
                var i: UInt64 = 0
                while i < (major == 5 ? v * 2 : v) {
                    if !skip() { return false }
                    i += 1
                }
                return true
            case 6: return skip()
            default: return false
            }
        }
    }
}
