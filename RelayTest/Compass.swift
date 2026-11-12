import Foundation

/// Compass calibration for the board's magnetometer (BMM350, sensor 21).
///
/// The raw reading is Earth's field (25-65 µT, mostly pointing down) plus the
/// board's own steady magnetic offset (battery, speaker magnets, steel), which
/// can be bigger than the part of Earth's field that points sideways. So a
/// heading from raw x/y is wrong until that offset is found. Turning the board
/// through a full circle, flat, traces a circle in x/y whose centre is the
/// offset ("hard iron"); the circle's radius is Earth's sideways field. Slightly
/// different radii on x and y give a per-axis scale ("soft iron", simple form).
///
/// Direction is measured, not assumed: the user turns the board clockwise seen
/// from above, and whether the field's angle rose or fell tells which way the
/// chip's axes run. The front edge is then set by pointing it north once.
///
/// Heading assumes the board lies flat. No tilt compensation yet.
struct CompassCal: Codable, Equatable {
    /// Offset to subtract, µT (x, y, z).
    var offset: [Double]
    /// Per-axis scale for x and y (1 = none).
    var scale: [Double]
    /// +1 if the field angle atan2(y, x) rises when the board turns clockwise
    /// seen from above, -1 if it falls.
    var sense: Double
    /// Degrees added so the front edge pointing north reads 0.
    var north: Double
    /// Radius of the circle in µT (Earth's sideways field), for the user.
    var radius: Double
    /// Whether the user has pointed the front at north yet.
    var northSet: Bool
}

/// Used on the main thread only (Bluetooth callbacks run on the main queue).
final class CompassModel: ObservableObject {
    enum Phase: Equatable {
        case idle
        case turning(covered: Int)   // of `sectors`
        case failed(String)
    }
    static let sectors = 12

    @Published private(set) var cal: CompassCal?
    @Published private(set) var phase: Phase = .idle
    /// Latest raw reading, µT.
    private(set) var raw: [Double] = []

    private var key = ""
    private var samples: [[Double]] = []

    /// The board whose calibration applies. Called on connect.
    func use(device: String) {
        key = device
        cal = Self.load(device)
        phase = .idle
        samples = []
    }

    func feed(_ v: [Int32]) {
        guard v.count >= 3 else { return }
        let m = v.map { Double($0) / 1000 }
        raw = m
        if case .turning = phase {
            samples.append(m)
            if samples.count > 3000 { samples.removeFirst(500) }
            // Cheap coverage check every few samples.
            if samples.count % 5 == 0 { phase = .turning(covered: coverage().count) }
        }
    }

    func start() {
        samples = []
        phase = .turning(covered: 0)
    }

    func cancel() {
        samples = []
        phase = .idle
    }

    /// Ends the turn and works out the calibration.
    func finish() {
        guard case .turning = phase else { return }
        let s = samples
        samples = []
        guard s.count >= 30 else { phase = .failed("Too few readings. Is the compass stream on?"); return }
        var lo = [Double](repeating: .infinity, count: 3)
        var hi = [Double](repeating: -.infinity, count: 3)
        for p in s { for i in 0..<3 { lo[i] = min(lo[i], p[i]); hi[i] = max(hi[i], p[i]) } }
        let off = (0..<3).map { (lo[$0] + hi[$0]) / 2 }
        let half = (0..<3).map { (hi[$0] - lo[$0]) / 2 }
        guard half[0] > 3, half[1] > 3 else {
            phase = .failed("The field barely changed while turning. Turn the board a full circle, flat.")
            return
        }
        guard coverage(of: s, center: off).count >= Self.sectors - 3 else {
            phase = .failed("Not a full circle. Turn all the way round, slowly, then tap Done.")
            return
        }
        let r = (half[0] + half[1]) / 2
        let scale = [r / half[0], r / half[1]]
        // Which way did the angle go? Sum the wrapped steps of the centred angle.
        var turned = 0.0
        var prev: Double?
        for p in s {
            let a = atan2((p[1] - off[1]) * scale[1], (p[0] - off[0]) * scale[0])
            if let q = prev {
                var d = a - q
                if d > .pi { d -= 2 * .pi }
                if d < -.pi { d += 2 * .pi }
                turned += d
            }
            prev = a
        }
        guard abs(turned) > .pi else {
            phase = .failed("Not a full circle. Turn all the way round, slowly, then tap Done.")
            return
        }
        // Keep an earlier north setting only if the direction didn't flip.
        let sense: Double = turned > 0 ? 1 : -1
        let keep = cal.flatMap { $0.sense == sense ? $0 : nil }
        let c = CompassCal(offset: off, scale: scale, sense: sense,
                           north: keep?.north ?? 0, radius: r, northSet: keep?.northSet ?? false)
        setCal(c)
        phase = .idle
    }

    func clear() {
        cal = nil
        phase = .idle
        if !key.isEmpty { UserDefaults.standard.removeObject(forKey: Self.defaultsKey(key)) }
    }

    /// The front edge points north now: remember that as 0°.
    func setNorth() {
        guard var c = cal, let a = angle(raw, c) else { return }
        c.north = -a
        c.northSet = true
        setCal(c)
    }

    /// Heading in degrees 0..<360 (clockwise from the front pointing at the
    /// reference), or nil until calibrated.
    func heading(_ v: [Int32]) -> Double? {
        guard let c = cal, v.count >= 3, let a = angle(v.map { Double($0) / 1000 }, c) else { return nil }
        var h = (a + c.north).truncatingRemainder(dividingBy: 360)
        if h < 0 { h += 360 }
        return h
    }

    func text(_ v: [Int32]) -> String {
        guard v.count >= 3 else { return "?" }
        let x = Double(v[0]) / 1000, y = Double(v[1]) / 1000, z = Double(v[2]) / 1000
        let field = (x * x + y * y + z * z).squareRoot()
        let rawLine = String(format: "raw x %+.0f  y %+.0f  z %+.0f µT · field %.0f µT", x, y, z, field)
        guard let h = heading(v), let c = cal else {
            return "Not calibrated: tap Calibrate and turn the board a full circle.\n" + rawLine
        }
        let points = ["N", "NE", "E", "SE", "S", "SW", "W", "NW"]
        let point = points[Int((h + 22.5) / 45) % 8]
        let ref = c.northSet ? "" : " (from the +x edge: tap Set north to fix it)"
        return String(format: "Heading %.0f° %@%@\n", h, point, ref) + rawLine
    }

    // MARK: Private

    /// Corrected field angle in degrees, in the clockwise-positive sense.
    private func angle(_ v: [Double], _ c: CompassCal) -> Double? {
        guard v.count >= 3 else { return nil }
        let x = (v[0] - c.offset[0]) * c.scale[0]
        let y = (v[1] - c.offset[1]) * c.scale[1]
        guard x != 0 || y != 0 else { return nil }
        return c.sense * atan2(y, x) * 180 / .pi
    }

    private func coverage() -> Set<Int> {
        guard !samples.isEmpty else { return [] }
        var lo = [Double](repeating: .infinity, count: 2)
        var hi = [Double](repeating: -.infinity, count: 2)
        for p in samples { for i in 0..<2 { lo[i] = min(lo[i], p[i]); hi[i] = max(hi[i], p[i]) } }
        // Need a real spread before sectors mean anything.
        guard hi[0] - lo[0] > 6, hi[1] - lo[1] > 6 else { return [] }
        return coverage(of: samples, center: [(lo[0] + hi[0]) / 2, (lo[1] + hi[1]) / 2])
    }

    private func coverage(of s: [[Double]], center: [Double]) -> Set<Int> {
        var seen = Set<Int>()
        for p in s {
            let a = atan2(p[1] - center[1], p[0] - center[0])
            let k = Int(((a + .pi) / (2 * .pi) * Double(Self.sectors)).rounded(.down))
            seen.insert(min(max(k, 0), Self.sectors - 1))
        }
        return seen
    }

    private func setCal(_ c: CompassCal) {
        cal = c
        if !key.isEmpty, let d = try? JSONEncoder().encode(c) {
            UserDefaults.standard.set(d, forKey: Self.defaultsKey(key))
        }
    }

    private static func defaultsKey(_ k: String) -> String { "compassCal." + k }

    private static func load(_ k: String) -> CompassCal? {
        UserDefaults.standard.data(forKey: defaultsKey(k))
            .flatMap { try? JSONDecoder().decode(CompassCal.self, from: $0) }
    }
}
