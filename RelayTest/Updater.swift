import CoreBluetooth
import Foundation

/// Firmware updates from the phone (t1d-relay-firmware docs/ble-test-service.md).
///
/// - Release files come from nRF Cloud (Memfault): software type "controller" for the
///   controller, "app" for the application (the Memfault project's primary
///   type, so it keeps its old name), hardware version = the board the
///   relay says it is ("thingy91" or "thingy91x"), so a board is only ever
///   offered its own images.
/// - controller: mcumgr (SMP) image upload over Bluetooth, then control
///   op 03 boots it on trial.
/// - application: no Bluetooth of its own, so the image goes to the Bluetooth
///   chip's LTE-update characteristic, which passes it over the wires, in
///   768-byte windows that the application acknowledges.
///
/// On the Thingy:91 both chips boot a new image on trial and roll back unless
/// it confirms itself, so a failed or interrupted update leaves the old
/// firmware running. The Thingy:91 X's controller (nRF5340) overwrites
/// its old image instead: no rollback, button recovery if a build is bad.
final class Updater: ObservableObject {
    enum Chip: String { case controller = "Controller", application = "Application" }

    struct Release: Equatable {
        let version: String
        let url: URL
        let size: Int
    }

    /// Where an application update over LTE stands (sensor 9 from the relay;
    /// firmware application 0.5.12 and later). The relay only does it when
    /// asked: it costs data on its SIM.
    struct LteStatus: Equatable {
        enum State: Int32 { case idle = 0, looking, newest, found, downloading, installing, failed }
        var state = State.idle
        /// Download progress in %, or the error number when it failed.
        var value = 0
        var size = 0
        var version = ""
    }
    @Published var lte = LteStatus()
    var lteBusy: Bool { [.looking, .downloading, .installing].contains(lte.state) }
    /// An application update over LTE is under way (not just a look-up).
    @Published var lteUpdate = false
    /// What the user asked of the LTE route (1 install, 2 reinstall), carried
    /// out as soon as the relay's look-up answers.
    private var lteIntent: UInt8?

    /// Which way the update now running (or last asked for) goes.
    enum Route { case bluetooth, lte }

    /// The relay's LTE status goes back to idle (a new connection, or an update ended).
    func resetLte() {
        lte = LteStatus()
        lteUpdate = false
        lteIntent = nil
    }

    /// 0 = look up the newest release and its size, 1 = download and install,
    /// 2 = install the same version again.
    func lteRequest(_ cmd: UInt8) {
        guard let p = peripheral, let c = control else { return }
        if cmd == 0 { lte = LteStatus(state: .looking) }
        else { lte = LteStatus(state: .downloading, value: 0, size: lte.size, version: lte.version) }
        p.writeValue(Data([4, cmd]), for: c, type: .withResponse)
        Log.update.notice("t=\(Log.ms()) LTE update request \(cmd)")
    }

    func lteSample(_ v: [Int32]) {
        guard v.count >= 4, let s = LteStatus.State(rawValue: v[0]) else { return }
        let code = Int(v[3])
        lte = LteStatus(state: s, value: Int(v[1]), size: Int(v[2]),
                        version: code == 0 ? "" : "\(code / 10000).\(code / 100 % 100).\(code % 100)")
        Log.update.notice("t=\(Log.ms()) LTE update state \(v[0]) value \(v[1]) size \(v[2]) version \(self.lte.version, privacy: .public)")
        // An update asked for from the sheet: the look-up has answered, go on.
        if let intent = lteIntent {
            switch s {
            case .found:
                lteIntent = nil
                lteRequest(1)
                return
            case .newest:
                lteIntent = nil
                if intent == 2 && lte.size > 0 {
                    lteRequest(2)
                    return
                }
                lteUpdate = false
                message = "The relay says the application is already the newest release."
            case .failed:
                lteIntent = nil
            default:
                return
            }
        }
        if s == .failed || s == .idle { lteUpdate = false }
        // The application is the last of "update all": nothing follows.
        if updatingAll, allQueue.isEmpty, lteIntent == nil, [.installing, .failed, .newest].contains(s) {
            stopAll()
        }
    }

    /// An update is under way, or waiting to go on: the Firmware screen shows its progress.
    var isUpdating: Bool { busy != nil || resumeChip != nil || updatingAll || lteUpdate }
    /// The controller has its image and is restarting; the application is next.
    var waitingForRestart: Bool { waitingForController != nil }
    /// The chip the update now shown is about.
    var activeChip: Chip? {
        if lteUpdate { return .application }
        return busy ?? resumeChip ?? (updatingAll ? allQueue.first : nil)
    }

    /// Application version 0.5.12 or later can update itself over LTE.
    var lteCapable: Bool {
        let core = applicationVersion.split(separator: "-").first.map(String.init) ?? ""
        let n = core.split(separator: ".").compactMap { Int($0) }
        guard n.count == 3 else { return false }
        return (n[0], n[1], n[2]) >= (0, 5, 12)
    }

    /// Update (or reinstall) the application over the relay's own LTE
    /// connection: look up the newest release, then download and install it.
    func startApplicationOverLTE(reinstall: Bool) {
        guard busy == nil, !lteBusy, peripheral != nil, control != nil else { return }
        route = .lte
        lteUpdate = true
        lteIntent = reinstall ? 2 : 1
        message = ""
        lteRequest(0)
    }

    /// What an Update button does once the way is known. The controller, and
    /// test copies, only go over Bluetooth; the application can go either way.
    func run(_ target: UpdatePlan.Target, route: Route) {
        switch target {
        case .part(let chip, let copy):
            if chip == .application && copy == .a && route == .lte {
                startApplicationOverLTE(reinstall: Self.sameVersion(applicationVersion, latestApplication?.version ?? ""))
            } else {
                start(chip, copy)
            }
        case .all(let copy):
            updateAll(copy, route: route)
        }
    }

    /// Whether the user has a choice to make: only the application's own
    /// newest release can come over LTE.
    func needsRouteChoice(_ target: UpdatePlan.Target) -> Bool {
        guard lteCapable else { return false }
        switch target {
        case .part(let chip, let copy): return chip == .application && copy == .a
        case .all(let copy): return copy == .a
        }
    }

    @Published var controllerVersion = "?"
    @Published var applicationVersion = "?"
    @Published var serial = ""
    /// "thingy91" or "thingy91x" (from Bluetooth firmware 0.5.0; "" before,
    /// which is always a Thingy:91).
    @Published var board = ""
    /// This relay's device definition (Boards.json).
    var boardDef: BoardDef { Boards.find(board) }
    var hardwareVersion: String { boardDef.updates.hardwareVersion }
    /// Seconds since the controller last heard the application (Bluetooth
    /// firmware 0.4.6 and later; nil before).
    @Published var heard: Int?
    @Published var latestController: Release?
    @Published var latestApplication: Release?
    /// The B copy for update testing: the same code as the newest release,
    /// only its version differs ("0.5.10-b"). Published by the firmware
    /// workflow's "ab" run under the hardware version "<board>-b".
    @Published var latestControllerB: Release?
    @Published var latestApplicationB: Release?
    enum Copy { case a, b }
    /// Which copy the update now running (or about to) installs.
    private(set) var wanted: Copy = .a
    @Published var checked = false
    @Published var lastChecked: Date?
    @Published var route = Route.bluetooth
    /// True once the image is downloaded and being sent to the board.
    @Published var sending = false
    /// The counters the controller reports: bad lines / dropped, transfer
    /// dropped / late, answers in / sent / error. Slash-joined as sent.
    @Published var badCounts = "?"
    @Published var transferCounts = "?"
    @Published var answerCounts = "?"
    @Published var chipLink = "?"
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
    /// Called when an update ends (done or stopped), to bring the streams back.
    var resumeStreams: () -> Void = {}

    private var image = Data()
    private var acked = 0
    /// Application: where the window now in flight starts. An answer that
    /// doesn't go past it is a duplicate or stale (the chip answers a
    /// repeated "get ready" or window again), and acting on it would send
    /// the same window twice, then four times… which jammed a reinstall.
    private var windowSentFrom: Int?
    /// When the window now in flight was first sent, and the usual time from
    /// a window's first send to its answer. The retry wait follows it: a
    /// fixed 1 s wait was shorter than a busy link's round trip, so the app
    /// resent windows whose answer was still on its way, the extra copies
    /// slowed the link more, and every window ended up taking ~3 s.
    private var windowFirstSent = Date()
    private var roundTrip: TimeInterval = 0.8
    /// Retries since the chip last answered; the update gives up after 3.
    private var tries = 0
    private var timer: Timer?
    private var smpSeq: UInt8 = 0
    /// Writes waiting for iOS to have room. Writes without response sent while
    /// canSendWriteWithoutResponse is false can be dropped silently.
    private var outbox: [(Data, CBCharacteristic)] = []
    private var started = Date()

    /// "Update all": chips still to do, the controller first, then the
    /// application (over Bluetooth or LTE, as asked).
    @Published var updatingAll = false
    private var allQueue: [Chip] = []
    private var allCopy: Copy = .a
    private var allRoute = Route.bluetooth
    /// After the controller's update: the version to see before the
    /// application goes next (its restart drops the Bluetooth link).
    private var waitingForController: String?
    private var controllerSentAt = Date.distantPast
    private var waitTimer: Timer?
    /// After a stall: the chip to update again once the chips can talk again
    /// (the stuck chip restarts itself, the app reconnects).
    private var resumeChip: Chip?
    private var resumeTimer: Timer?
    private var autoRetries = 0

    static let projectKey = (Bundle.main.object(forInfoDictionaryKey: "MemfaultProjectKey") as? String) ?? ""

    // MARK: Device info

    /// "controller 0.5.3 link 3 application 0.5.4 serial 352656101102872 heard 1 upd 0/0 board thingy91x"
    func parseInfo(_ text: String) {
        let w = text.split(separator: " ").map(String.init)
        func after(_ key: String) -> String? {
            guard let i = w.firstIndex(of: key), i + 1 < w.count else { return nil }
            return w[i + 1]
        }
        controllerVersion = after("controller") ?? "?"
        applicationVersion = after("application") ?? "?"
        let newSerial = after("serial") ?? ""
        let newBoard = after("board") ?? ""
        if (!newSerial.isEmpty && !serial.isEmpty && newSerial != serial) || newBoard != board {
            // A different relay: what was found for the last one doesn't apply.
            latestController = nil
            latestApplication = nil
            latestControllerB = nil
            latestApplicationB = nil
            checked = false
            lastChecked = nil
        }
        board = newBoard
        serial = newSerial
        heard = after("heard").flatMap { Int($0) }
        chipLink = after("link") ?? "?"
        badCounts = after("bad") ?? "?"
        transferCounts = after("upd") ?? "?"
        answerCounts = after("ans") ?? "?"
        if let want = waitingForController, Self.sameVersion(controllerVersion, want),
           Date().timeIntervalSince(controllerSentAt) > 15, busy == nil, linkOK,
           peripheral != nil, update != nil {
            waitingForController = nil
            waitTimer?.invalidate()
            startNextOfAll()
        }
        if let c = resumeChip, busy == nil, linkOK, peripheral != nil,
           (c == .controller ? smp : update) != nil {
            resumeChip = nil
            resumeTimer?.invalidate()
            begin(c)
        }
    }

    /// The application's lines are reaching the controller. Unknown counts as
    /// fine (older Bluetooth firmware doesn't say).
    var linkOK: Bool { (heard ?? 0) <= 20 }

    /// One line on the link between the chips, for the Firmware section.
    var linkText: String? {
        guard let h = heard else { return nil }
        return h <= 20
            ? "Chip link OK (controller heard the application \(h) s ago)"
            : "The controller hasn't heard the application for \(h) s. It restarts itself after 45 s, or the application resets it."
    }

    /// Exact version match. A running image that hasn't confirmed yet reports
    /// "-trial" after its version. Not a prefix match: "0.5.10" is a prefix of
    /// the B copy "0.5.10-b" and the two must not look alike.
    static func sameVersion(_ running: String, _ release: String) -> Bool {
        running == release || running == release + "-trial"
    }

    /// Chips whose newest release differs from what they run.
    var outdated: [Chip] {
        var chips: [Chip] = []
        if let l = latestApplication, !Self.sameVersion(applicationVersion, l.version) { chips.append(.application) }
        if let b = latestController, !Self.sameVersion(controllerVersion, b.version) { chips.append(.controller) }
        return chips
    }

    func release(_ chip: Chip, _ copy: Copy) -> Release? {
        switch (chip, copy) {
        case (.controller, .a): return latestController
        case (.controller, .b): return latestControllerB
        case (.application, .a): return latestApplication
        case (.application, .b): return latestApplicationB
        }
    }

    /// The copy a chip is not running: B when it runs A (or anything else),
    /// A when it runs B. nil until that copy has been found.
    func other(_ chip: Chip) -> (copy: Copy, release: Release)? {
        let running = chip == .controller ? controllerVersion : applicationVersion
        let runningB = release(chip, .b).map { Self.sameVersion(running, $0.version) } ?? false
        let copy: Copy = runningB ? .a : .b
        return release(chip, copy).map { (copy, $0) }
    }

    // MARK: Update all

    func updateAll(_ copy: Copy = .a, route: Route = .bluetooth) {
        guard busy == nil, !updatingAll, !lteBusy else { return }
        guard release(.application, copy) != nil, release(.controller, copy) != nil else {
            message = "That copy isn't published for this board."
            return
        }
        allCopy = copy
        allRoute = route
        // Both chips every time, controller first: an update where either is
        // behind, a reinstall of both when they're current.
        guard checked else {
            message = "Check for updates first."
            return
        }
        allQueue = [.controller, .application]
        updatingAll = true
        startNextOfAll()
    }

    private func startNextOfAll() {
        guard updatingAll else { return }
        guard !allQueue.isEmpty else {
            updatingAll = false
            return
        }
        let next = allQueue.removeFirst()
        if next == .application && allRoute == .lte && allCopy == .a {
            startApplicationOverLTE(reinstall: Self.sameVersion(applicationVersion, release(.application, .a)?.version ?? ""))
            if !lteUpdate { stopAll() } // couldn't begin
            return
        }
        start(next, allCopy)
        if busy == nil && resumeChip == nil {
            stopAll() // start() couldn't begin and said why in `message`
        }
    }

    private func stopAll() {
        updatingAll = false
        allQueue = []
        waitingForController = nil
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
            message = "Waiting for the application to send its serial… try again in a few seconds."
            return
        }
        message = "Checking nRF Cloud…"
        Task { @MainActor in
            do {
                latestController = try await latest(type: "controller")
                // The application's Memfault software type is "app" (the
                // project's primary type), not "application".
                latestApplication = try await latest(type: "app")
                // The B copy is optional: nil when the "ab" run hasn't published it.
                latestControllerB = try? await latest(type: "controller", hardware: hardwareVersion + "-b")
                latestApplicationB = try? await latest(type: "app", hardware: hardwareVersion + "-b")
                checked = true
                lastChecked = Date()
                message = ""
            } catch {
                message = "Couldn't check: \(error.localizedDescription)"
            }
        }
    }

    private func latest(type: String, hardware: String? = nil) async throws -> Release? {
        var c = URLComponents(string: "https://device.memfault.com/api/v0/releases/latest")!
        c.queryItems = [
            URLQueryItem(name: "device_serial", value: serial),
            URLQueryItem(name: "hardware_version", value: hardware ?? hardwareVersion),
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
        // The controller is a component of the application's release, so the
        // release version is the LTE one. The image's own MCUboot header says
        // which version it really is; read just its first 32 bytes.
        let version = try? await imageVersion(url)
        // The B copy's header says the same 0.5.10; the board reports "0.5.10-b".
        let suffix = hardware == nil ? "" : "-b"
        return Release(version: (version ?? a.component_version ?? body.component_version ?? body.version) + suffix,
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

    /// The Update buttons. The application's update goes through the Bluetooth
    /// chip, so it waits for the link between them to be working.
    func start(_ chip: Chip, _ copy: Copy = .a) {
        guard busy == nil else { return }
        wanted = copy
        route = .bluetooth
        autoRetries = 0
        resumeChip = nil
        if chip == .application && !linkOK {
            waitForLink(.application, "The controller isn't hearing the application right now.")
            return
        }
        begin(chip)
    }

    private func begin(_ chip: Chip) {
        guard busy == nil, let rel = release(chip, wanted) else { return }
        guard peripheral != nil, (chip == .controller ? smp : update) != nil else {
            message = chip == .controller
                ? "The controller has no update service (firmware before 0.4.2)."
                : "The controller can't pass updates on (firmware before 0.4.2)."
            return
        }
        busy = chip
        progress = 0
        sending = false
        message = "Downloading \(chip.rawValue) \(rel.version)…"
        stopStreams()
        Task { @MainActor in
            do {
                let (data, _) = try await URLSession.shared.data(from: rel.url)
                image = data
                acked = 0
                windowSentFrom = nil
                roundTrip = 0.8
                tries = 0
                started = Date()
                sending = true
                message = "Sending \(chip.rawValue) \(rel.version) (\(data.count / 1024) KB)…"
                Log.update.notice("t=\(Log.ms()) start \(chip.rawValue, privacy: .public) \(rel.version, privacy: .public) size \(data.count) max write \(self.peripheral?.maximumWriteValueLength(for: .withoutResponse) ?? -1) B")
                if chip == .controller { smpSend() } else { lteBegin() }
            } catch {
                finish("Download failed: \(error.localizedDescription)")
            }
        }
    }

    /// From Relay when the Bluetooth connection ends.
    func connectionLost(userAsked: Bool) {
        if lte.state != .installing && !lteUpdate { resetLte() }
        if userAsked {
            if busy != nil || resumeChip != nil || updatingAll {
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
        Log.update.notice("t=\(Log.ms()) stall \(chip.rawValue, privacy: .public) at \(self.acked): \(why, privacy: .public) (auto retry \(self.autoRetries))")
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
            self.finish("The chips still can't talk to each other after 3 minutes, so the update stopped. Nothing was installed. Check the board (`controller status`).")
        }
    }

    private func finish(_ text: String) {
        Log.update.notice("t=\(Log.ms()) finish: \(text, privacy: .public)")
        stopAll()
        resumeChip = nil
        resumeTimer?.invalidate()
        outbox.removeAll()
        timer?.invalidate()
        timer = nil
        busy = nil
        sending = false
        lteUpdate = false
        lteIntent = nil
        message = text
        resumeStreams()
    }

    private func arm(_ seconds: TimeInterval, tries limit: Int = 3, _ retry: @escaping () -> Void) {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self] _ in
            guard let self, self.busy != nil else { return }
            self.tries += 1
            Log.update.notice("t=\(Log.ms()) timer fired after \(seconds, format: .fixed(precision: 1)) s: try \(self.tries) of \(limit), acked \(self.acked), window from \(self.windowSentFrom ?? -1), outbox \(self.outbox.count)")
            if self.tries > limit {
                let who = self.busy == .application ? "the application (through the controller)" : "the controller"
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
        guard busy == .controller, data.count > 8, data[data.startIndex + 5] == 1 else { return }
        let fields = CBOR.intMap(data.dropFirst(8))
        if let rc = fields["rc"], rc != 0 {
            finish("The controller refused the image (mcumgr error \(rc)).")
            return
        }
        guard let off = fields["off"] else { return }
        acked = Int(off)
        tries = 0
        Log.update.notice("t=\(Log.ms()) smp ack \(off)")
        showProgress()
        if acked >= image.count {
            timer?.invalidate()
            message = "Restarting the controller on the new firmware…"
            if let p = peripheral, let c = control {
                p.writeValue(Data([3]), for: c, type: .withResponse)
            }
            busy = nil
            sending = false
            if updatingAll, !allQueue.isEmpty, let want = release(.controller, allCopy)?.version {
                // The application goes next, once the controller is back.
                waitingForController = want
                controllerSentAt = Date()
                message = "Controller restarting on \(want). The application goes next, once the app has reconnected (about 30 s)…"
                waitTimer?.invalidate()
                waitTimer = Timer.scheduledTimer(withTimeInterval: 180, repeats: false) { [weak self] _ in
                    guard let self, self.waitingForController != nil else { return }
                    self.stopAll()
                    self.message = "The controller didn't come back on \(want) within 3 minutes, so the application wasn't updated. Check the board and try again."
                }
            } else {
                message = "Controller restarting on the new firmware. The app reconnects by itself in about 30 s; it keeps the update once it's talked to the application for a minute."
                stopAll()
            }
        } else {
            smpSend()
        }
    }

    // MARK: application: through the controller

    private static let window = 768
    private static let piece = 192

    private func lteBegin() {
        if tries == 0 {
            message = "Asking the application to get ready (it makes room for the update)…"
        }
        Log.update.notice("t=\(Log.ms()) send begin 0x10 size \(self.image.count) try \(self.tries)")
        write([0x10] + le32(UInt32(image.count)))
        arm(3) { [weak self] in self?.lteBegin() }
    }

    private var windowWait: TimeInterval { min(max(3 * roundTrip, 2), 6) }

    private func lteSendWindow() {
        let end = min(acked + Self.window, image.count)
        windowSentFrom = acked
        Log.update.notice("t=\(Log.ms()) send window \(self.acked)..<\(end) try \(self.tries)")
        var off = acked
        while off < end {
            let n = min(Self.piece, end - off)
            write([0x11] + le32(UInt32(off)) + [UInt8](image.subdata(in: off..<off + n)))
            off += n
        }
        if tries == 0 { windowFirstSent = Date() }
        // Wait three usual round trips (2-6 s): long enough that a late answer
        // isn't mistaken for a lost one, short enough that a real loss costs
        // a few seconds.
        arm(windowWait, tries: 8) { [weak self] in self?.lteSendWindow() }
    }

    func updateNotification(_ data: Data) {
        let raw = Log.hex(data)
        guard busy == .application, data.count >= 5 else {
            Log.update.notice("t=\(Log.ms()) notify \(raw, privacy: .public) IGNORED (\(self.busy == .application ? "too short" : "no application update running", privacy: .public))")
            return
        }
        let b = [UInt8](data)
        let v = UInt32(b[1]) | UInt32(b[2]) << 8 | UInt32(b[3]) << 16 | UInt32(b[4]) << 24
        if b[0] == 0x21 {
            Log.update.notice("t=\(Log.ms()) notify \(raw, privacy: .public) ERROR \(Int32(bitPattern: v))")
            finish("The application refused the image (error \(Int32(bitPattern: v))).")
            return
        }
        guard b[0] == 0x20 else {
            Log.update.notice("t=\(Log.ms()) notify \(raw, privacy: .public) IGNORED (unknown type)")
            return
        }
        if let from = windowSentFrom, Int(v) <= from {
            Log.update.notice("t=\(Log.ms()) notify ack \(v) IGNORED (stale, window from \(from))")
            return // duplicate or stale: the retry timer covers a real loss
        }
        if tries == 0 {
            // Only answers to a first send measure the round trip.
            roundTrip = 0.8 * roundTrip + 0.2 * Date().timeIntervalSince(windowFirstSent)
        }
        Log.update.notice("t=\(Log.ms()) notify ack \(v) ACCEPTED (window from \(self.windowSentFrom ?? -1), tries \(self.tries), round trip \(self.roundTrip, format: .fixed(precision: 2)) s)")
        acked = Int(v)
        tries = 0
        showProgress()
        if acked >= image.count {
            timer?.invalidate()
            write([0x12])
            busy = nil
            sending = false
            autoRetries = 0
            message = "Application restarting on the new firmware. It keeps it once it's on LTE for a minute; reconnect to see the new version."
            stopAll() // the application is the last of "update all"
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
        if !outbox.isEmpty {
            Log.update.notice("t=\(Log.ms()) outbox waiting for iOS room: \(self.outbox.count) queued")
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
