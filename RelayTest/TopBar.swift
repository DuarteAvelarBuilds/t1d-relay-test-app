import SwiftUI

/// Signal strength as the app shows it, for Bluetooth and LTE alike.
enum Signal {
    /// 0 none ... 1 poor, 2 fair, 3 good, 4 excellent.
    static func word(_ bars: Int) -> String {
        ["no signal", "poor", "fair", "good", "excellent"][bars]
    }

    /// LTE: RSRP, the usual cellular measure. Excellent above -90 dBm, poor below -115.
    static func lteBars(_ rsrp: Int?) -> Int {
        guard let rsrp else { return 0 }
        switch rsrp {
        case (-90)...: return 4
        case (-105)...: return 3
        case (-115)...: return 2
        default: return 1
        }
    }

    /// Bluetooth: RSSI of the phone's link to the relay.
    static func bluetoothBars(_ rssi: Int?) -> Int {
        guard let rssi else { return 0 }
        switch rssi {
        case (-55)...: return 4
        case (-70)...: return 3
        case (-85)...: return 2
        default: return 1
        }
    }
}

/// Four rising bars, `filled` of them lit.
struct SignalBars: View {
    let filled: Int
    let lit: Color

    var body: some View {
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(1...4, id: \.self) { i in
                RoundedRectangle(cornerRadius: 1)
                    .fill(i <= filled ? lit : Color.secondary.opacity(0.35))
                    .frame(width: 4, height: CGFloat(3 + i * 3))
            }
        }
        .frame(height: 15, alignment: .bottom)
        .accessibilityHidden(true)
    }
}

/// The Bluetooth rune, drawn here because SF Symbols has none.
struct BluetoothMark: Shape {
    func path(in r: CGRect) -> Path {
        func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: r.minX + x / 10 * r.width, y: r.minY + y / 16 * r.height)
        }
        var p = Path()
        p.move(to: pt(1, 4))
        p.addLine(to: pt(9, 12))
        p.addLine(to: pt(5, 15))
        p.addLine(to: pt(5, 1))
        p.addLine(to: pt(9, 4))
        p.addLine(to: pt(1, 12))
        return p
    }
}

/// Right end of the bar on every screen: Bluetooth bars (blue), LTE bars,
/// tap for the numbers.
struct SignalButton: View {
    @ObservedObject var relay: Relay
    @State private var showing = false

    var body: some View {
        let bt = Signal.bluetoothBars(relay.linkRssi)
        let lte = Signal.lteBars(relay.lteRsrp)
        Button { showing = true } label: {
            HStack(spacing: 10) {
                HStack(spacing: 4) {
                    BluetoothMark()
                        .stroke(Color.blue, style: StrokeStyle(lineWidth: 1.6, lineJoin: .round))
                        .frame(width: 9, height: 15)
                    SignalBars(filled: bt, lit: .blue)
                }
                SignalBars(filled: lte, lit: .primary)
            }
        }
        .accessibilityLabel("Bluetooth \(Signal.word(bt)), LTE \(Signal.word(lte)). Tap for details.")
        .sheet(isPresented: $showing) {
            SignalDetails(relay: relay)
                .presentationDetents([.height(260)])
        }
    }
}

struct SignalDetails: View {
    @ObservedObject var relay: Relay
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let bt = Signal.bluetoothBars(relay.linkRssi)
        let lte = Signal.lteBars(relay.lteRsrp)
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("Signal").font(.title2.bold())
                Spacer()
                Button("Done") { dismiss() }
            }
            row(title: "Bluetooth, phone to relay",
                bars: bt, lit: .blue,
                value: relay.linkRssi.map { "\(Signal.word(bt)) · \($0) dBm" } ?? "not measured yet")
            row(title: "LTE, relay to the network",
                bars: lte, lit: .primary,
                value: relay.lteRsrp.map { "\(Signal.word(lte)) · \($0) dBm" } ?? "no signal yet (LTE signal sensor)")
            Spacer(minLength: 0)
        }
        .padding(20)
    }

    private func row(title: String, bars: Int, lit: Color, value: String) -> some View {
        HStack(spacing: 14) {
            SignalBars(filled: bars, lit: lit)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline).foregroundStyle(.secondary)
                Text(value).font(.body).monospacedDigit()
            }
        }
    }
}

extension View {
    /// The one top bar: the title in the middle, Bluetooth and LTE bars on
    /// the right. A pushed screen gets its back button from the stack.
    func relayBar(_ title: String, relay: Relay) -> some View {
        self
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { SignalButton(relay: relay) }
            }
    }

    /// The same, for the first screen, which has its own button on the left.
    func relayBar<Leading: View>(_ title: String, relay: Relay,
                                 @ViewBuilder leading: () -> Leading) -> some View {
        relayBar(title, relay: relay)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { leading() }
            }
    }
}
