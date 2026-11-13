import SwiftUI

enum Screen: Hashable { case firmware, details }

/// What an Update button is about to do, while its sheet asks which way.
struct UpdatePlan: Identifiable {
    enum Target {
        case part(Updater.Chip, Updater.Copy)
        case all(Updater.Copy)
    }
    let id = UUID()
    let target: Target
}

private func megabytes(_ bytes: Int) -> String { String(format: "%.2f MB", Double(bytes) / 1_000_000) }

extension Updater {
    /// An Update button: asks which way when there is a choice, else just goes.
    func ask(_ target: UpdatePlan.Target, _ plan: Binding<UpdatePlan?>) {
        if needsRouteChoice(target) {
            plan.wrappedValue = UpdatePlan(target: target)
        } else {
            run(target, route: .bluetooth)
        }
    }
}

extension View {
    func routeSheet(_ plan: Binding<UpdatePlan?>, relay: Relay) -> some View {
        sheet(item: plan) { p in
            RouteSheet(relay: relay, plan: p)
                .presentationDetents([.medium, .large])
        }
    }
}

// MARK: Firmware screen

/// Versions of the two parts, what is newest, and how to update them.
struct FirmwareScreen: View {
    @ObservedObject var relay: Relay
    @ObservedObject var updater: Updater
    @State private var plan: UpdatePlan?
    /// "Hide, keep updating in the background": the overview with a small bar on top.
    @State private var hidden = false

    init(relay: Relay) {
        self.relay = relay
        _updater = ObservedObject(wrappedValue: relay.updater)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                if updater.isUpdating && !hidden {
                    UpdatingView(relay: relay, updater: updater, onHide: { hidden = true })
                } else {
                    if updater.isUpdating { updatingBar }
                    overview
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .background(Color(.systemGroupedBackground))
        .refreshable { updater.check() } // pull down: ask over Bluetooth
        .relayBar("Firmware", relay: relay)
        .routeSheet($plan, relay: relay)
        .onAppear(perform: autoCheck)
        .onChange(of: updater.serial) { _, _ in autoCheck() }
        .onChange(of: updater.isUpdating) { _, now in if !now { hidden = false } }
    }

    /// Look once on opening, as soon as the board has said who it is.
    private func autoCheck() {
        if !updater.checked && !updater.serial.isEmpty && !updater.isUpdating { updater.check() }
    }

    private var updatingBar: some View {
        Button { hidden = false } label: {
            HStack {
                ProgressView()
                Text(updater.updatingAll ? "Updating everything…" : "Updating \((updater.activeChip?.rawValue ?? "firmware").lowercased())…")
                Spacer()
                Text("Show").foregroundStyle(.blue)
            }
            .padding(14)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
    }

    private var overview: some View {
        VStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Versions").font(.title2.bold())
                    Spacer()
                    Menu {
                        Button("Check over Bluetooth") { updater.check() }
                        Button("Check over LTE") { updater.lteRequest(0) }
                            .disabled(!updater.lteCapable || updater.lteBusy)
                    } label: {
                        Text(updater.checked ? "Check again" : "Check for updates")
                    }
                }
                checkedLine
                if !updater.message.isEmpty {
                    Text(updater.message).font(.footnote).foregroundStyle(.secondary)
                }
                lteLine
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if updater.checked && updater.latestApplication != nil && updater.latestController != nil {
                let n = updater.outdated.count
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(n == 0 ? "Everything is up to date" : (n == 1 ? "1 update available" : "2 updates available"))
                            .font(.subheadline.weight(.semibold))
                        Text("Controller first, then application").font(.footnote).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if n == 0 {
                        Button("Reinstall all") { updater.ask(.all(.a), $plan) }
                            .buttonStyle(.bordered)
                    } else {
                        Button("Update all") { updater.ask(.all(.a), $plan) }
                            .buttonStyle(.borderedProminent)
                    }
                }
                .disabled(updater.isUpdating)
                .padding(14)
                .background(n == 0 ? Color(.secondarySystemGroupedBackground) : Color.blue.opacity(0.18),
                            in: RoundedRectangle(cornerRadius: 14))
            }

            PartCard(chip: .application, updater: updater) { updater.ask($0, $plan) }
            PartCard(chip: .controller, updater: updater) { updater.ask($0, $plan) }

            if let note = updater.boardDef.updates.note {
                Text("\(updater.boardDef.name): \(note)")
                    .font(.footnote).foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if !updater.linkOK, let link = updater.linkText {
                Text(link).font(.footnote).foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            NavigationLink(value: Screen.details) {
                HStack {
                    Text("Board details").font(.body)
                    Spacer()
                    Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 16).padding(.vertical, 14)
                .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
            }
            .buttonStyle(.plain)
        }
    }

    @ViewBuilder private var checkedLine: some View {
        if let d = updater.lastChecked {
            (Text("Checked ") + Text(d, style: .relative) + Text(" ago"))
                .font(.footnote).foregroundStyle(.secondary)
        } else {
            Text("Not checked yet").font(.footnote).foregroundStyle(.secondary)
        }
    }

    /// What the relay found when asked over LTE.
    @ViewBuilder private var lteLine: some View {
        let s = updater.lte
        switch s.state {
        case .looking:
            Text("Asking the cloud, over the relay's LTE…").font(.footnote).foregroundStyle(.secondary)
        case .newest where !updater.lteUpdate:
            Text("Over LTE: the application is already the newest release (\(s.version)).")
                .font(.footnote).foregroundStyle(.secondary)
        case .found where !updater.lteUpdate:
            Text("Over LTE: the newest application is \(s.version), \(megabytes(s.size)) to download.")
                .font(.footnote).foregroundStyle(.secondary)
        case .failed:
            Text("The LTE update didn't work (error \(s.value)). Nothing was installed.")
                .font(.footnote).foregroundStyle(.orange)
        default:
            EmptyView()
        }
    }
}

/// One part (application or controller): what runs, what's newest, one Update button.
struct PartCard: View {
    let chip: Updater.Chip
    @ObservedObject var updater: Updater
    let onUpdate: (UpdatePlan.Target) -> Void

    private var running: String { chip == .controller ? updater.controllerVersion : updater.applicationVersion }
    private var latest: Updater.Release? { chip == .controller ? updater.latestController : updater.latestApplication }
    private var current: Bool { latest.map { Updater.sameVersion(running, $0.version) } ?? false }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(chip.rawValue).font(.title3.weight(.semibold))
                Spacer()
                pill
            }
            HStack(alignment: .top, spacing: 28) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Running").font(.caption).foregroundStyle(.secondary)
                    Text(running).font(.body)
                }
                if let latest {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Newest").font(.caption).foregroundStyle(.secondary)
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(latest.version).font(.body)
                            if latest.size > 0 {
                                Text(megabytes(latest.size)).font(.footnote).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            HStack(spacing: 10) {
                if let latest {
                    if current {
                        Button { onUpdate(.part(chip, .a)) } label: {
                            Text("Reinstall \(latest.version)").frame(maxWidth: .infinity, minHeight: 34)
                        }
                        .buttonStyle(.bordered)
                    } else {
                        Button { onUpdate(.part(chip, .a)) } label: {
                            Text("Update to \(latest.version)").frame(maxWidth: .infinity, minHeight: 34)
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    if let o = updater.other(chip), o.copy == .b {
                        Menu {
                            Button("Install test copy \(o.release.version)") { onUpdate(.part(chip, o.copy)) }
                        } label: {
                            Image(systemName: "ellipsis")
                                .frame(width: 34, height: 34)
                        }
                        .buttonStyle(.bordered)
                        .accessibilityLabel("More options for \(chip.rawValue)")
                    }
                } else {
                    Button { updater.check() } label: {
                        Text("Check for updates").frame(maxWidth: .infinity, minHeight: 34)
                    }
                    .buttonStyle(.bordered)
                }
            }
            .controlSize(.large)
            .disabled(updater.isUpdating)
            Text(route).font(.footnote).foregroundStyle(.secondary)
        }
        .padding(18)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18))
    }

    private var route: String {
        if chip == .controller { return "Bluetooth only" }
        return updater.lteCapable ? "Bluetooth or LTE" : "Bluetooth only (LTE needs application 0.5.12)"
    }

    private var pill: some View {
        let (text, color): (String, Color) = {
            guard latest != nil else { return ("Not checked", .secondary) }
            return current ? ("Up to date", .green) : ("Update available", .orange)
        }()
        return Text(text)
            .font(.caption.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 10).padding(.vertical, 4)
            .background(color.opacity(0.18), in: Capsule())
    }
}

// MARK: Choose how

/// The sheet every application Update opens: Bluetooth or LTE.
struct RouteSheet: View {
    @ObservedObject var relay: Relay
    @ObservedObject var updater: Updater
    let plan: UpdatePlan
    @Environment(\.dismiss) private var dismiss
    @State private var route = Updater.Route.bluetooth

    init(relay: Relay, plan: UpdatePlan) {
        self.relay = relay
        self.plan = plan
        _updater = ObservedObject(wrappedValue: relay.updater)
    }

    private var all: Bool {
        if case .all = plan.target { return true }
        return false
    }

    private var reinstall: Bool {
        Updater.sameVersion(updater.applicationVersion, updater.latestApplication?.version ?? "")
    }

    private var title: String {
        all ? "Update everything" : (reinstall ? "Reinstall application" : "Update application")
    }

    private var subtitle: String {
        if all { return "Controller first, over Bluetooth. Then the application, the way you pick here." }
        let size = (updater.latestApplication?.size ?? 0) > 0 ? " · \(megabytes(updater.latestApplication?.size ?? 0))" : ""
        let version = updater.latestApplication?.version ?? "?"
        return reinstall ? "\(version) again\(size)" : "\(updater.applicationVersion) to \(version)\(size)"
    }

    private var lteNote: String {
        let size = updater.latestApplication.map { "about \(megabytes($0.size)) of the relay's data plan" } ?? "the relay's data plan"
        let signal = relay.lteRsrp.map { " · signal \(Signal.word(Signal.lteBars($0)))" } ?? " · no LTE signal reading yet"
        return "Uses \(size)\(signal)"
    }

    private var testCopy: (copy: Updater.Copy, release: Updater.Release)? {
        guard !all, let o = updater.other(.application), o.copy == .b else { return nil }
        return o
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.title2.bold())
                    Text(subtitle).foregroundStyle(.secondary)
                }
                option(.bluetooth, "Over Bluetooth",
                       "The phone sends it to the relay. Keep the phone close and this app open.",
                       "Uses no data on the relay's SIM", badge: "Recommended")
                option(.lte, "Over LTE",
                       "The relay downloads it itself. The phone can leave once it starts.",
                       lteNote, badge: nil)
                VStack(spacing: 8) {
                    Button {
                        updater.run(plan.target, route: route)
                        dismiss()
                    } label: {
                        Text("\(reinstall && !all ? "Reinstall" : "Update") over \(route == .lte ? "LTE" : "Bluetooth")")
                            .frame(maxWidth: .infinity, minHeight: 36)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    Button("Cancel") { dismiss() }.controlSize(.large)
                }
                if let o = testCopy {
                    Divider()
                    VStack(alignment: .leading, spacing: 10) {
                        Text("OTHER OPTIONS").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        Button {
                            dismiss()
                            updater.run(.part(.application, o.copy), route: .bluetooth)
                        } label: {
                            HStack {
                                Text("Install test copy \(o.release.version)")
                                Spacer()
                                Text("for A/B tests, Bluetooth").font(.footnote).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .padding(20)
        }
    }

    private func option(_ r: Updater.Route, _ title: String, _ detail: String, _ note: String,
                        badge: String?) -> some View {
        Button { route = r } label: {
            HStack(alignment: .top, spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.headline)
                    Text(detail).font(.subheadline).foregroundStyle(.secondary)
                    Text(note).font(.footnote).foregroundStyle(.secondary).padding(.top, 2)
                }
                Spacer(minLength: 0)
                if let badge {
                    Text(badge).font(.caption.weight(.semibold)).foregroundStyle(.blue)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(route == r ? Color.blue : Color.clear, lineWidth: 2))
        }
        .buttonStyle(.plain)
    }
}

// MARK: Updating

/// Progress of the update now running, in plain steps.
struct UpdatingView: View {
    @ObservedObject var relay: Relay
    @ObservedObject var updater: Updater
    let onHide: () -> Void

    private enum Step { case done, active, todo }

    private var lte: Bool { updater.lteUpdate }
    private var chipName: String { (updater.activeChip ?? .application).rawValue.lowercased() }

    private var version: String {
        if lte { return updater.lte.version.isEmpty ? (updater.latestApplication?.version ?? "") : updater.lte.version }
        return updater.activeChip.flatMap { updater.release($0, updater.wanted)?.version } ?? ""
    }

    private var running: String {
        updater.activeChip == .controller ? updater.controllerVersion : updater.applicationVersion
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(updater.boardDef.name) · \(updater.updatingAll ? "Controller, then application" : chipName.capitalized)")
                    .font(.footnote).foregroundStyle(.secondary)
                Text(updater.updatingAll ? "Updating everything" : "Updating to \(version)")
                    .font(.title.bold())
            }
            progressCard
            stepsCard
            notice
            if !lte && !updater.message.isEmpty {
                Text(updater.message).font(.footnote).foregroundStyle(.secondary)
            }
            Button("Hide, keep updating in the background", action: onHide)
                .frame(maxWidth: .infinity)
        }
    }

    // The big card: percent and bar.
    @ViewBuilder private var progressCard: some View {
        let s = updater.lte
        VStack(alignment: .leading, spacing: 12) {
            if lte {
                let downloading = s.state == .downloading
                let pct = s.state == .installing ? 100 : (downloading ? s.value : 0)
                HStack(alignment: .firstTextBaseline) {
                    Text(s.state == .installing ? "Installing" : (downloading ? "Downloading over LTE" : "Asking over LTE"))
                        .font(.headline)
                    Spacer()
                    Text("\(pct)%").font(.title.bold()).monospacedDigit()
                }
                ProgressView(value: Double(pct) / 100)
                if s.size > 0 {
                    Text("\(megabytes(s.size * pct / 100)) of \(megabytes(s.size))")
                        .font(.footnote).foregroundStyle(.secondary).monospacedDigit()
                }
            } else {
                let pct = Int(updater.progress * 100)
                HStack(alignment: .firstTextBaseline) {
                    Text(updater.busy == nil ? "Waiting" : (updater.sending ? "Sending over Bluetooth" : "Downloading from the cloud"))
                        .font(.headline)
                    Spacer()
                    if updater.sending { Text("\(pct)%").font(.title.bold()).monospacedDigit() }
                }
                if updater.sending {
                    ProgressView(value: updater.progress)
                } else {
                    ProgressView(value: nil as Double?)
                }
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18))
    }

    private var steps: [(String, Step)] {
        if lte {
            let st = updater.lte.state
            let asked: Step = st == .looking || st == .idle ? .active : .done
            let down: Step = st == .downloading ? .active : (st == .installing ? .done : .todo)
            let inst: Step = st == .installing ? .active : .todo
            return [("Asked for the newest release", asked),
                    ("Downloading \(version)", down),
                    ("Installing and restarting", inst),
                    ("Checking it works (about 1 minute)", .todo)]
        }
        let down: Step = updater.busy != nil && !updater.sending ? .active : (updater.sending || updater.waitingForRestart ? .done : .todo)
        let send: Step = updater.sending ? .active : (updater.waitingForRestart ? .done : .todo)
        let restart: Step = updater.waitingForRestart ? .active : .todo
        return [("Downloading \(version) from the cloud", down),
                ("Sending it to the \(chipName)", send),
                ("Restarting and checking it works", restart)]
    }

    private var stepsCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            ForEach(Array(steps.enumerated()), id: \.offset) { _, step in
                HStack(spacing: 14) {
                    switch step.1 {
                    case .done:
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    case .active:
                        Image(systemName: "circle.inset.filled").foregroundStyle(.blue)
                    case .todo:
                        Image(systemName: "circle").foregroundStyle(.secondary)
                    }
                    Text(step.0).foregroundStyle(step.1 == .todo ? Color.secondary : Color.primary)
                }
                .font(.body)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18))
    }

    private var notice: some View {
        VStack(alignment: .leading, spacing: 4) {
            if lte {
                Text("The relay is doing this on its own").font(.subheadline.weight(.semibold)).foregroundStyle(.yellow)
                Text("You can put the phone away. If it fails nothing is installed and the relay keeps running \(running).")
                    .font(.subheadline).foregroundStyle(.secondary)
            } else {
                Text("Keep the phone close and this app open").font(.subheadline.weight(.semibold)).foregroundStyle(.yellow)
                Text("iOS can suspend the app in the background, and then the transfer waits until you come back to it. If it fails nothing is installed and the board keeps running \(running).")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.yellow.opacity(0.12), in: RoundedRectangle(cornerRadius: 14))
    }
}

// MARK: Board details

/// Everything else about the board: identity, links, counters, reinstall and test copies, the raw line.
struct BoardDetailsScreen: View {
    @ObservedObject var relay: Relay
    @ObservedObject var updater: Updater
    @State private var plan: UpdatePlan?

    init(relay: Relay) {
        self.relay = relay
        _updater = ObservedObject(wrappedValue: relay.updater)
    }

    private var lteRate: Int? { relay.rows.first(where: { $0.id == Relay.signalSensor })?.interval }

    var body: some View {
        List {
            Section("Board") {
                value("Board", updater.boardDef.name)
                LabeledContent("Serial") { Text(updater.serial.isEmpty ? "?" : updater.serial).font(.system(.subheadline, design: .monospaced)) }
                value("Controller", "\(updater.controllerVersion) · link \(updater.chipLink)")
                value("Application", updater.applicationVersion)
            }
            Section("Connection") {
                value("LTE signal", relay.lteRsrp.map { "\(Signal.word(Signal.lteBars($0))) · \($0) dBm" } ?? "no signal yet")
                LabeledContent("LTE polling") {
                    Menu {
                        ForEach(Sensors.all.first(where: { $0.id == Relay.signalSensor })?.intervals ?? [], id: \.self) { ms in
                            Button(Sensors.rateLabel(ms)) { relay.setInterval(Relay.signalSensor, ms) }
                        }
                    } label: {
                        Text(lteRate.map(Sensors.rateLabel) ?? "?")
                    }
                }
                value("Bluetooth", relay.linkRssi.map { "\(Signal.word(Signal.bluetoothBars($0))) · \($0) dBm" } ?? "not measured yet")
            }
            Section("Chip link (controller and application)") {
                LabeledContent("Status") {
                    Text(updater.heard.map { updater.linkOK ? "OK · heard \($0) s ago" : "not heard for \($0) s" } ?? "unknown")
                        .foregroundStyle(updater.linkOK ? Color.green : Color.orange)
                }
                mono("Bad lines / dropped", updater.badCounts)
                mono("Last transfer: dropped / late", updater.transferCounts)
                mono("Answers in / sent / error", updater.answerCounts)
            }
            Section("Reinstall and test copies") {
                if !updater.checked {
                    Text("Check for updates on the Firmware screen first.").foregroundStyle(.secondary)
                }
                reinstallRow(.application)
                reinstallRow(.controller)
                copyRow(.application)
                copyRow(.controller)
                if let a = updater.other(.application), let c = updater.other(.controller), a.copy == c.copy {
                    action("Switch both to \(a.copy == .b ? "test copies" : "newest")",
                           detail: "\(a.release.version) / \(c.release.version)") {
                        updater.ask(.all(a.copy), $plan)
                    }
                }
            }
            Section("Raw info line from the relay") {
                Text(relay.info.isEmpty ? "nothing yet" : relay.info)
                    .font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
            }
        }
        .relayBar("Board details", relay: relay)
        .routeSheet($plan, relay: relay)
    }

    private func value(_ title: String, _ text: String) -> some View {
        LabeledContent(title) { Text(text) }
    }

    private func mono(_ title: String, _ text: String) -> some View {
        LabeledContent(title) { Text(text).font(.system(.subheadline, design: .monospaced)) }
    }

    private func action(_ title: String, detail: String, _ run: @escaping () -> Void) -> some View {
        Button(action: run) {
            HStack {
                Text(title)
                Spacer()
                Text(detail).font(.footnote).foregroundStyle(.secondary)
            }
        }
        .disabled(updater.isUpdating)
    }

    /// Only when the part already runs the newest release: then Update says Reinstall.
    @ViewBuilder private func reinstallRow(_ chip: Updater.Chip) -> some View {
        let running = chip == .controller ? updater.controllerVersion : updater.applicationVersion
        let latest = chip == .controller ? updater.latestController : updater.latestApplication
        if let latest, Updater.sameVersion(running, latest.version) {
            action("Reinstall \(chip.rawValue.lowercased()) \(latest.version)",
                   detail: chip == .controller || !updater.lteCapable ? "Bluetooth" : "Bluetooth or LTE") {
                updater.ask(.part(chip, .a), $plan)
            }
        }
    }

    @ViewBuilder private func copyRow(_ chip: Updater.Chip) -> some View {
        if let o = updater.other(chip), o.copy == .b {
            action("Install test copy \(o.release.version)", detail: chip.rawValue.lowercased()) {
                updater.ask(.part(chip, o.copy), $plan)
            }
        }
    }
}
