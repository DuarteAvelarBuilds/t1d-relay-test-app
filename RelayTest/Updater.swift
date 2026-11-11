import CoreBluetooth
import Foundation

/// Firmware updates from the phone (t1d-relay-firmware docs/ble-test-service.md).
///
/// - Release files come from nRF Cloud (Memfault): software type "bt" for the
///   controller, "app" for the application chip, hardware version = the board the
///   relay says it is ("thingy91" or "thingy91x"), so a board is only ever
///   offered its own images.
/// - controller: mcumgr (SMP) image upload over Bluetooth, then control
///   op 03 boots it on trial.
/// - application chip: no Bluetooth of its own, so the image goes to the Bluetooth
///   chip's LTE-update characteristic, which passes it over the wires, in
///   768-byte windows that the application chip acknowledges.
///
/// On the Thingy:91 both chips boot a new image on trial and roll back unless
/// it confirms itself, so a failed or interrupted update leaves the old
/// firmware running. The Thingy:91 X's controller (nRF5340) overwrites
/// its old image instead: no rollback, button recovery if a build is bad.
final class Updater: ObservableObject {
    enum Chip: String { case bt = "Controller", lte = "Application chip" }

    struct Release: Equatable {
        let version: String
        let url: URL
        let size: Int
    }

    @Published var btVersion = "?"
    @Published var lteVersion = "?"
    @Published var serial = ""
    /// "thingy91" or "thingy91x" (from Bluetooth firmware 0.5.0; "" before,
    /// which is always a Thingy:91).
    @Published var board = ""
    /// This relay's device definition (Boards.json).
    var boardDef: BoardDef { Boards.find(board) }
    var hardwareVersion: String { boardDef.updates.hardwareVersion }
    /// Seconds since the controller last heard the application chip (Bluetooth
    /// firmware 0.4.6 and later; nil before).
    @Published var heard: Int?
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
    /// Application chip: where the window now in flight starts. An answer that
    /// doesn't go past it is a duplicate or stale (the chip answers a
    /// repeated "get ready" or window again), and acting on it would send
    /// the same window twice, then four times… which jammed a reinstall.
    private var windowSentFrom: Int?
    /// Retries since the chip last answered; the update gives up after 3.
    private var tries = 0
    private var timer: Timer?
    private var smpSeq: UInt8 = 0
    /// Writes waiting for iOS to have room. Writes without response sent while
    /// canSendWriteWithoutResponse is false can be dropped silently.
    private var outbox: [(Data, CBCharacteristic)] = []
    private var started = Date()

    /// "Update all": chips still to do, LTE first (the phone stays connected
    /// while it restarts), the controller last (its restart drops the link).
    @Published var updatingAll = false
    private var allQueue: [Chip] = []
    /// After the application chip's update: the version to see before going on.
    private var waitingForLte: String?
    /// When the application chip got its image. A reinstall keeps the same version,
    /// so the version alone can't show it has restarted: wait at least 15 s
    /// and for the controller to hear it again.
    private var lteSentAt = Date.distantPast
    private var waitTimer: Timer?
    /// After a stall: the chip to update again once the chips can talk again
    /// (the stuck chip restarts itself, the app reconnects).
    private var resumeChip: Chip?
    private var resumeTimer: Timer?
    private var autoRetries = 0

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
        let newSerial = after("serial") ?? ""
        let newBoard = after("board") ?? ""
        if (!newSerial.isEmpty && !serial.isEmpty && newSerial != serial) || newBoard != board {
            // A different relay: what was found for the last one doesn't apply.
            latestBt = nil
            latestLte = nil
            checked = false
        }
        board = newBoard
        serial = newSerial
        heard = after("heard").flatMap { Int($0) }
        if let c = resumeChip, busy == nil, linkOK, peripheral != nil,
           (c == .bt ? smp : update) != nil {
            resumeChip = nil
            resumeTimer?.invalidate()
            begin(c)
        }
        if let want = waitingForLte, lteVersion.hasPrefix(want),
           Date().timeIntervalSince(lteSentAt) > 15, (heard ?? 0) <= 10 {
            waitingForLte = nil
            waitTimer?.invalidate()
            startNextOfAll()
        }
    }

    /// The application chip's lines are reaching the controller. Unknown counts as
    /// fine (older Bluetooth firmware doesn't say).
    var linkOK: Bool { (heard ?? 0) <= 20 }

    /// One line on the link between the chips, for the Firmware section.
    var linkText: String? {
        guard let h = heard else { return nil }
        return h <= 20
            ? "Chip link OK (controller heard the application chip \(h) s ago)"
            : "The controller hasn't heard the application chip for \(h) s. It restarts itself after 45 s, or the application chip resets it."
    }

    /// Chips whose newest release differs from what they run.
    var outdated: [Chip] {
        var chips: [Chip] = []
        if let l = latestLte, !lteVersion.hasPrefix(l.version) { chips.append(.lte) }
        if let b = latestBt, !btVersion.hasPrefix(b.version) { chips.append(.bt) }
        return chips
    }

    // MARK: Update all

    func updateAll() {
        guard busy == nil, !updatingAll else { return }
        // Both chips every time, LTE first: an update where either is
        // behind, a reinstall of both when they're current.
        guard latestLte != nil, latestBt != nil else {
            message = "Check for updates first."
            return
        }
        allQueue = [.lte, .bt]
        updatingAll = true
        startNextOfAll()
    }

    private func startNextOfAll() {
        guard updatingAll else { return }
        guard !allQueue.isEmpty else {
            updatingAll = false
            return
        }
        start(allQueue.removeFirst())
        if busy == nil && resumeChip == nil {
            stopAll() // start() couldn't begin and said why in `message`
        }
    }

    private func stopAll() {
        updatingAll = false
        allQueue = []
        waitingForLte = nil
        waitTimer?.invalidate()
        waitTimer = nil
    }

    // MARK: nRF Cloud

    func check() {
        guard !Self.projectKey.isEmpty else {
            message = "This build has no nRF Cloud project key (see the README)."
            return
        }
        guard !serial.isEmpty else {
            message = "Waiting for the application chip to send its serial… try again in a few seconds."
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
            URLQueryItem(name: "hardware_version", value: hardwareVersion),
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
        // The controller is a component of the application chip's release, so the
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

    /// The Update buttons. The application chip's update goes through the Bluetooth
    /// chip, so it waits for the link between them to be working.
    func start(_ chip: Chip) {
        guard busy == nil else { return }
        autoRetries = 0
        resumeChip = nil
        if chip == .lte && !linkOK {
            waitForLink(.lte, "The controller isn't hearing the application chip right now.")
            return
        }
        begin(chip)
    }

    private func begin(_ chip: Chip) {
        guard busy == nil, let rel = chip == .bt ? latestBt : latestLte else { return }
        guard peripheral != nil, (chip == .bt ? smp : update) != nil else {
            message = chip == .bt
                ? "The controller has no update service (firmware before 0.4.2)."
                : "The controller can't pass updates on (firmware before 0.4.2)."
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
                windowSentFrom = nil
                tries = 0
                started = Date()
                message = "Sending \(chip.rawValue) \(rel.version) (\(data.count / 1024) KB)…"
                if chip == .bt { smpSend() } else { lteBegin() }
            } catch {
                finish("Download failed: \(error.localizedDescription)")
            }
        }
    }

    /// From Relay when the Bluetooth connection ends.
    func connectionLost(userAsked: Bool) {
        if userAsked {
            if busy != nil || resumeChip != nil {
                finish("Stopped: you disconnected. Nothing was installed.")
            }
            return
        }
        if let chip = busy {
            retryLater(chip, "The connection dropped.")
        }
    }

    /// A transfer stalled: drop it and start it again from the beginning
    /// once the chips can talk again (at most twice per tap).
    private func retryLater(_ chip: Chip, _ why: String) {
        timer?.invalidate()
        timer = nil
        outbox.removeAll()
        busy = nil
        guard autoRetries < 2 else {
            finish(why + " It still failed after trying again by itself, so it stopped. Nothing was installed; check the board.")
            return
        }
        autoRetries += 1
        waitForLink(chip, why)
    }

    private func waitForLink(_ chip: Chip, _ why: String) {
        resumeChip = chip
        message = why + " Waiting for the chips to talk again (up to about a minute), then it starts by itself…"
        resumeTimer?.invalidate()
        resumeTimer = Timer.scheduledTimer(withTimeInterval: 180, repeats: false) { [weak self] _ in
            guard let self, self.resumeChip != nil else { return }
            self.finish("The chips still can't talk to each other after 3 minutes, so the update stopped. Nothing was installed. Check the board (`bt status`).")
        }
    }

    private func finish(_ text: String) {
        stopAll()
        resumeChip = nil
        resumeTimer?.invalidate()
        outbox.removeAll()
        timer?.invalidate()
        timer = nil
        busy = nil
        message = text
    }

    private func arm(_ seconds: TimeInterval, tries limit: Int = 3, _ retry: @escaping () -> Void) {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self] _ in
            guard let self, self.busy != nil else { return }
            self.tries += 1
            if self.tries > limit {
                let who = self.busy == .lte ? "the application chip (through the controller)" : "the controller"
                self.retryLater(self.busy!, "No answer from \(who).")
            } else {
                self.outbox.removeAll() // a retry sends it all again
                self.message = "No answer yet, asking again (\(self.tries) of \(limit))…"
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

    // MARK: controller: mcumgr image upload

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
            finish("The controller refused the image (mcumgr error \(rc)).")
            return
        }
        guard let off = fields["off"] else { return }
        acked = Int(off)
        tries = 0
        showProgress()
        if acked >= image.count {
            timer?.invalidate()
            message = "Restarting the controller on the new firmware…"
            if let p = peripheral, let c = control {
                p.writeValue(Data([3]), for: c, type: .withResponse)
            }
            busy = nil
            message = updatingAll
                ? "Both chips updated. The controller is restarting now; the app reconnects by itself in about 30 s, and each chip keeps its update after a minute of working."
                : "Controller restarting on the new firmware. The app reconnects by itself in about 30 s; it keeps the update once it's talked to the application chip for a minute."
            stopAll()
        } else {
            smpSend()
        }
    }

    // MARK: application chip: through the controller

    private static let window = 768
    private static let piece = 192

    private func lteBegin() {
        if tries == 0 {
            message = "Asking the application chip to get ready (it makes room for the update)…"
        }
        write([0x10] + le32(UInt32(image.count)))
        arm(3) { [weak self] in self?.lteBegin() }
    }

    private func lteSendWindow() {
        let end = min(acked + Self.window, image.count)
        windowSentFrom = acked
        var off = acked
        while off < end {
            let n = min(Self.piece, end - off)
            write([0x11] + le32(UInt32(off)) + [UInt8](image.subdata(in: off..<off + n)))
            off += n
        }
        // A window's answer normally comes back in well under half a second
        // (the 3 s wait in lteBegin is for the chip making room). Waiting 3 s
        // here turned every lost answer into a long pause.
        arm(1, tries: 8) { [weak self] in self?.lteSendWindow() }
    }

    func updateNotification(_ data: Data) {
        guard busy == .lte, data.count >= 5 else { return }
        let b = [UInt8](data)
        let v = UInt32(b[1]) | UInt32(b[2]) << 8 | UInt32(b[3]) << 16 | UInt32(b[4]) << 24
        if b[0] == 0x21 {
            finish("The application chip refused the image (error \(Int32(bitPattern: v))).")
            return
        }
        guard b[0] == 0x20 else { return }
        if let from = windowSentFrom, Int(v) <= from {
            return // duplicate or stale: the retry timer covers a real loss
        }
        acked = Int(v)
        tries = 0
        showProgress()
        if acked >= image.count {
            timer?.invalidate()
            write([0x12])
            busy = nil
            autoRetries = 0
            message = "Application chip restarting on the new firmware. It keeps it once it's on LTE for a minute; reconnect to see the new version."
            if updatingAll, !allQueue.isEmpty, let want = latestLte?.version {
                // The controller goes next, once the application chip is back and
                // reports the new version (the app re-reads it every few seconds).
                waitingForLte = want
                lteSentAt = Date()
                message = "Application chip restarting on \(want). The controller goes next, once the application chip is back (about 30 s)…"
                waitTimer?.invalidate()
                waitTimer = Timer.scheduledTimer(withTimeInterval: 180, repeats: false) { [weak self] _ in
                    guard let self, self.waitingForLte != nil else { return }
                    self.stopAll()
                    self.message = "The application chip didn't come back on \(want) within 3 minutes, so the controller wasn't updated. If it went back to the old version, its update didn't keep; check again and retry."
                }
            } else {
                stopAll()
            }
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
            case 2 where v == Self.indefinite, 3 where v == Self.indefinite:
                while !atBreak() { if !skip() { return false } }
                return true
            case 2, 3: return take(Int(v)) != nil
            case 4 where v == Self.indefinite, 5 where v == Self.indefinite:
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
