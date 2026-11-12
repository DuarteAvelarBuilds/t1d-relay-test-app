import SwiftUI

struct ContentView: View {
    @StateObject private var relay = Relay()

    var body: some View {
        NavigationStack {
            Group {
                if relay.status == .connected {
                    SensorList(relay: relay)
                } else {
                    DeviceList(relay: relay)
                }
            }
            .navigationTitle("Relay Test")
        }
        .onChange(of: relay.status) { _, s in
            // Keep the screen on while connected, so the test isn't cut short.
            UIApplication.shared.isIdleTimerDisabled = s == .connected
        }
    }
}

struct DeviceList: View {
    @ObservedObject var relay: Relay

    var body: some View {
        List {
            Section {
                switch relay.status {
                case .bluetoothOff:
                    Text("Turn Bluetooth on, and allow this app to use it in Settings.")
                case .scanning:
                    Label("Looking for the relay…", systemImage: "antenna.radiowaves.left.and.right")
                case .connecting:
                    Label("Connecting…", systemImage: "link")
                case .reconnecting:
                    Label("Reconnecting… (the relay may be restarting)", systemImage: "arrow.triangle.2.circlepath")
                    Button("Stop") { relay.disconnect() }
                case .disconnected(let why):
                    Text(why).foregroundStyle(.orange)
                    Button("Look again") { relay.startScan() }
                case .connected:
                    EmptyView()
                }
            }
            Section("Relays nearby") {
                if relay.found.isEmpty {
                    Text("None yet. The relay needs Bluetooth firmware 0.4.0 or later.")
                        .foregroundStyle(.secondary)
                }
                ForEach(relay.found) { f in
                    Button {
                        relay.connect(f)
                    } label: {
                        HStack {
                            VStack(alignment: .leading) {
                                Text(f.name)
                                if let b = Boards.fromAdvertisedName(f.name) {
                                    Text(b.name).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            Text("\(f.rssi) dBm").foregroundStyle(.secondary).monospacedDigit()
                        }
                    }
                }
            }
        }
    }
}

struct SensorList: View {
    @ObservedObject var relay: Relay

    var body: some View {
        List {
            Section {
                Text(relay.updater.boardDef.name).font(.headline)
                HStack {
                    Text(relay.info.isEmpty ? "Connected" : relay.info)
                    Spacer()
                    if let r = relay.linkRssi {
                        Text("Bluetooth \(r) dBm").foregroundStyle(.secondary).monospacedDigit()
                    }
                }
                .font(.footnote)
                Button("Disconnect", role: .destructive) { relay.disconnect() }
            }
            FirmwareSection(updater: relay.updater)
            Section("Sensors") {
                ForEach(relay.rows) { row in
                    if let def = Sensors.all.first(where: { $0.id == row.id }) {
                        SensorCell(def: def, row: row, relay: relay)
                    }
                }
            }
        }
    }
}

/// Firmware versions on the board, what nRF Cloud has, and the Update buttons.
struct FirmwareSection: View {
    @ObservedObject var updater: Updater

    var body: some View {
        Section("Firmware") {
            row(.controller, updater.controllerVersion, updater.latestController)
            row(.application, updater.applicationVersion, updater.latestApplication)
            if updater.busy != nil || updater.updatingAll {
                ProgressView(value: updater.progress)
            }
            if let link = updater.linkText {
                Text(link).font(.footnote).foregroundStyle(updater.linkOK ? Color.secondary : Color.orange)
            }
            if !updater.message.isEmpty {
                Text(updater.message).font(.footnote).foregroundStyle(.secondary)
            }
            if let note = updater.boardDef.updates.note {
                Text("\(updater.boardDef.name): \(note)")
                    .font(.footnote).foregroundStyle(.orange)
            }
            if updater.checked && updater.latestApplication != nil && updater.latestController != nil {
                Button(updater.outdated.isEmpty ? "Reinstall all" : "Update all") { updater.updateAll(.a) }
                    .disabled(updater.busy != nil || updater.updatingAll)
            }
            if updater.checked, let a = updater.other(.application), let c = updater.other(.controller),
               a.copy == c.copy {
                Button("Switch both to \(a.release.version) / \(c.release.version)") { updater.updateAll(a.copy) }
                    .disabled(updater.busy != nil || updater.updatingAll)
            }
            Button(updater.checked ? "Check again" : "Check for updates") { updater.check() }
                .disabled(updater.busy != nil || updater.updatingAll)
        }
    }

    @ViewBuilder
    private func row(_ chip: Updater.Chip, _ running: String, _ latest: Updater.Release?) -> some View {
        HStack {
            VStack(alignment: .leading) {
                Text(chip.rawValue)
                Text(latest.map { "running \(running) · newest \($0.version)" } ?? "running \(running)")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Spacer()
            if let latest {
                VStack(alignment: .trailing) {
                    Button(Updater.sameVersion(running, latest.version) ? "Reinstall" : "Update") { updater.start(chip) }
                        .buttonStyle(.bordered)
                        .disabled(updater.busy != nil || updater.updatingAll)
                    if let o = updater.other(chip) {
                        Button("Install \(o.release.version)") { updater.start(chip, o.copy) }
                            .buttonStyle(.bordered)
                            .disabled(updater.busy != nil || updater.updatingAll)
                    }
                }
            }
        }
    }
}

struct SensorCell: View {
    let def: SensorDef
    let row: SensorRow
    let relay: Relay

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Circle().fill(dotColor).frame(width: 10, height: 10)
                Text(def.name).font(.headline)
                Spacer()
                Toggle("", isOn: Binding(get: { row.enabled },
                                         set: { relay.setEnabled(row.id, $0) }))
                    .labelsHidden()
            }
            if row.enabled {
                Text(row.failedText ?? row.text)
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(row.failedText == nil ? .primary : Color.red)
                if def.kind == "compass" {
                    CompassControls(relay: relay, model: relay.compass)
                }
                if row.graph.count > 1 {
                    Sparkline(values: row.graph).frame(height: 30)
                }
                HStack {
                    Menu {
                        ForEach(def.intervals, id: \.self) { ms in
                            Button(Sensors.rateLabel(ms)) { relay.setInterval(row.id, ms) }
                        }
                    } label: {
                        Text("Asked: \(Sensors.rateLabel(row.interval))")
                    }
                    Spacer()
                    Text(String(format: "Got %.1f/s", row.perSecond))
                    if row.missed > 0 {
                        Text("· \(row.missed) missed").foregroundStyle(.orange)
                    }
                }
                .font(.caption)
                .monospacedDigit()
            }
            Text(def.detail(on: relay.updater.board)).font(.caption2).foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }

    /// Green while updates arrive on time, orange if late, grey if off.
    private var dotColor: Color {
        guard row.enabled else { return .gray }
        guard let last = row.lastUpdate else { return .orange }
        let late = max(3.0, 3 * Double(row.interval) / 1000)
        return Date().timeIntervalSince(last) > late ? .orange : .green
    }
}

/// Calibrate / set north buttons under the compass reading.
struct CompassControls: View {
    let relay: Relay
    @ObservedObject var model: CompassModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            switch model.phase {
            case .turning(let covered):
                Text("Lay the board flat, face up. Turn it slowly clockwise (seen from above) through one full circle, then tap Done. Directions covered: \(covered) of \(CompassModel.sectors).")
                    .font(.footnote)
                HStack {
                    Button("Done") { model.finish() }.buttonStyle(.borderedProminent)
                    Button("Cancel") { model.cancel() }.buttonStyle(.bordered)
                }
            case .failed(let why):
                Text(why).font(.footnote).foregroundStyle(.orange)
                Button("Try again") { start() }.buttonStyle(.bordered)
            case .idle:
                HStack {
                    Button(model.cal == nil ? "Calibrate" : "Calibrate again") { start() }
                        .buttonStyle(.bordered)
                    if model.cal != nil {
                        Button("Set north") { model.setNorth() }.buttonStyle(.bordered)
                        Button("Clear", role: .destructive) { model.clear() }.buttonStyle(.bordered)
                    }
                }
                if let c = model.cal {
                    Text(String(format: "Calibrated: sideways field %.0f µT, offset x %+.0f y %+.0f µT. %@",
                                c.radius, c.offset[0], c.offset[1],
                                c.northSet ? "North set." : "To finish: point the edge you call the front at north (iPhone Compass), tap Set north."))
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func start() {
        // 10 readings a second is plenty for a slow turn.
        relay.setInterval(21, 100)
        model.start()
    }
}

struct Sparkline: View {
    let values: [Double]

    var body: some View {
        GeometryReader { geo in
            let lo = values.min() ?? 0
            let hi = values.max() ?? 1
            let span = max(hi - lo, 0.0001)
            Path { p in
                for (i, v) in values.enumerated() {
                    let x = geo.size.width * CGFloat(i) / CGFloat(max(values.count - 1, 1))
                    let y = geo.size.height * (1 - CGFloat((v - lo) / span))
                    if i == 0 { p.move(to: CGPoint(x: x, y: y)) } else { p.addLine(to: CGPoint(x: x, y: y)) }
                }
            }
            .stroke(Color.accentColor, lineWidth: 1.5)
        }
    }
}
