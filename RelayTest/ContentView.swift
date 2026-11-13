import SwiftUI

struct ContentView: View {
    @StateObject private var relay = Relay()
    /// Pushed screens. Kept here, not in the sensor list, so an update that
    /// restarts the board (and drops the connection for a moment) leaves you
    /// on the Firmware screen when it comes back.
    @State private var path: [Screen] = []

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if relay.status == .connected {
                    SensorList(relay: relay)
                        .relayBar(relay.updater.boardDef.name, relay: relay) {
                            Button("Disconnect", role: .destructive) { relay.disconnect() }
                        }
                } else {
                    DeviceList(relay: relay)
                        .navigationTitle("Relay Test")
                }
            }
            .navigationDestination(for: Screen.self) { screen in
                switch screen {
                case .firmware: FirmwareScreen(relay: relay)
                case .details: BoardDetailsScreen(relay: relay)
                }
            }
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
    @ObservedObject var updater: Updater

    init(relay: Relay) {
        self.relay = relay
        _updater = ObservedObject(wrappedValue: relay.updater)
    }

    var body: some View {
        List {
            Section {
                NavigationLink(value: Screen.firmware) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Firmware").font(.headline)
                        if updater.isUpdating {
                            Text("Updating…").font(.footnote).foregroundStyle(.blue)
                        } else if updater.outdated.count > 0 {
                            Text(updater.outdated.count == 1 ? "1 update available" : "\(updater.outdated.count) updates available")
                                .font(.footnote).foregroundStyle(.orange)
                        } else if updater.checked {
                            Text("Up to date").font(.footnote).foregroundStyle(.secondary)
                        } else {
                            Text(updater.applicationVersion == "?" ? "" : "application \(updater.applicationVersion), controller \(updater.controllerVersion)")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            Section {
                // The LTE signal is the connection indicator, shown in the top
                // bar; its polling rate is in Board details.
                ForEach(relay.rows.filter { $0.id != Relay.signalSensor }) { row in
                    if let def = Sensors.all.first(where: { $0.id == row.id }) {
                        SensorCell(def: def, row: row, relay: relay)
                    }
                }
            } header: {
                Text("Sensors")
            } footer: {
                Text("LTE signal is always on. Change how often it polls in Board details.")
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
                    .disabled(row.id == Relay.signalSensor) // the connection indicator: always on
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
