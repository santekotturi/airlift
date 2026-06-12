import SwiftUI
import HealthKit

// MARK: - Stage strip

extension LaneStage {
    /// The shared Daybreak stage color, used by both Google and Apple lanes.
    var daybreakColor: Color {
        switch self {
        case .awake: Daybreak.stageAwake
        case .rem: Daybreak.stageREM
        case .core: Daybreak.stageCore
        case .deep: Daybreak.stageDeep
        case .asleep: Daybreak.stageCore
        case .inBed: Daybreak.stageInBed
        }
    }
}

/// Horizontal proportional colored strip — one night of stages at a glance.
/// One continuous band clipped once to radius 5; time the source didn't cover
/// shows the hairline track underneath, so misaligned lanes stay honest
/// without reading as missing data.
struct StageStrip: View {
    let segments: [(color: Color, fraction: Double)]
    let height: CGFloat

    init(segments: [(color: Color, fraction: Double)], height: CGFloat = 12) {
        self.segments = segments
        self.height = height
    }

    var body: some View {
        GeometryReader { geo in
            HStack(spacing: 0) {
                ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                    segment.color
                        .frame(width: max(0, geo.size.width * segment.fraction))
                }
            }
        }
        .frame(height: height)
        .background(Daybreak.track)
        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
    }
}

extension StageStrip {
    /// Union of both sources' coverage — pass the same domain to both lanes so
    /// offsets between Google and Apple are visible.
    static func sharedDomain(
        google: [SleepStageSegment],
        apple: [AppleSleepSegment]
    ) -> ClosedRange<Date>? {
        let starts = google.map(\.start) + apple.map(\.start)
        let ends = google.map(\.end) + apple.map(\.end)
        guard let min = starts.min(), let max = ends.max(), max > min else { return nil }
        return min...max
    }

    /// Google lane over `domain`, normalized to the shared stage colors.
    /// Unscored gaps inside `span` (the session's labeled bounds; defaults to
    /// the segments' extent) render as the in-bed gray, never as voids.
    init(
        google segments: [SleepStageSegment],
        domain: ClosedRange<Date>,
        span: ClosedRange<Date>? = nil,
        height: CGFloat = 12
    ) {
        let spans = segments.map { (LaneStage(google: $0.stage).daybreakColor, $0.start, $0.end) }
        self.init(segments: Self.fractions(spans: spans, domain: domain, coverage: span), height: height)
    }

    /// Apple lane over `domain`, normalized to the shared stage colors.
    init(
        apple segments: [AppleSleepSegment],
        domain: ClosedRange<Date>,
        span: ClosedRange<Date>? = nil,
        height: CGFloat = 12
    ) {
        let spans = segments.compactMap { segment -> (Color, Date, Date)? in
            guard let stage = LaneStage(apple: segment.value) else { return nil }
            return (stage.daybreakColor, segment.start, segment.end)
        }
        self.init(segments: Self.fractions(spans: spans, domain: domain, coverage: span), height: height)
    }

    /// Converts absolute spans into ordered (color, fraction) runs summing to
    /// exactly 1.0. Uncovered time inside `coverage` (default: the spans'
    /// extent) is in-bed gray; time outside it is clear, showing the track.
    private static func fractions(
        spans: [(color: Color, start: Date, end: Date)],
        domain: ClosedRange<Date>,
        coverage: ClosedRange<Date>?
    ) -> [(color: Color, fraction: Double)] {
        let total = domain.upperBound.timeIntervalSince(domain.lowerBound)
        guard total > 0 else { return [] }
        let sorted = spans.sorted { $0.start < $1.start }
        let coverage = coverage ?? sorted.first.map { _ in
            sorted.map(\.start).min()!...sorted.map(\.end).max()!
        }
        var result: [(color: Color, fraction: Double)] = []
        func filler(from: Date, to: Date) {
            guard to > from else { return }
            let inStart = coverage.map { max(from, $0.lowerBound) } ?? to
            let inEnd = coverage.map { min(to, $0.upperBound) } ?? to
            guard inEnd > inStart else {
                result.append((.clear, to.timeIntervalSince(from) / total))
                return
            }
            if inStart > from {
                result.append((.clear, inStart.timeIntervalSince(from) / total))
            }
            result.append((Daybreak.stageInBed, inEnd.timeIntervalSince(inStart) / total))
            if to > inEnd {
                result.append((.clear, to.timeIntervalSince(inEnd) / total))
            }
        }
        var cursor = domain.lowerBound
        for span in sorted {
            let start = max(span.start, domain.lowerBound)
            let end = min(span.end, domain.upperBound)
            guard end > start else { continue }
            filler(from: cursor, to: start)
            let visibleStart = max(start, cursor)
            if end > visibleStart {
                result.append((span.color, end.timeIntervalSince(visibleStart) / total))
            }
            cursor = max(cursor, end)
        }
        filler(from: cursor, to: domain.upperBound)
        return result
    }
}

// MARK: - Bridge

/// The signature element: Google and Apple Health endpoints joined by a dotted
/// arc, with a tiny care package — the app icon's heart-in-a-box under a
/// parachute — drifting across on delivery.
struct BridgeView: View {
    var deviceName: String = DeviceLabel.fallback

    private static let loopDuration: Double = 3.4

    var body: some View {
        HStack(alignment: .top, spacing: 4) {
            endpoint(caption: deviceName) { googleBadge }
            arc
                .frame(height: 54)
                .frame(maxWidth: .infinity)
                .padding(.top, 4)
            endpoint(caption: "Apple Health") { appleBadge }
        }
    }

    private func endpoint(caption: String, @ViewBuilder badge: () -> some View) -> some View {
        VStack(spacing: 6) {
            badge()
            Text(caption)
                .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                .foregroundStyle(Daybreak.mid)
        }
    }

    private var googleBadge: some View {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(Daybreak.card)
            .frame(width: 46, height: 46)
            .shadow(color: Daybreak.plum.opacity(0.18), radius: 8, y: 4)
            .overlay {
                Text("G")
                    .font(.system(size: 24, weight: .bold, design: .serif))
                    .foregroundStyle(Color(daybreakHex: 0x4285F4))
            }
    }

    private var appleBadge: some View {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(LinearGradient(
                colors: [Color(daybreakHex: 0xFF6482), Color(daybreakHex: 0xF4364C)],
                startPoint: .topLeading, endPoint: .bottomTrailing
            ))
            .frame(width: 46, height: 46)
            .shadow(color: Color(daybreakHex: 0xF4364C).opacity(0.3), radius: 8, y: 4)
            .overlay {
                Image(systemName: "heart.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(.white)
            }
    }

    private var arc: some View {
        TimelineView(.animation) { timeline in
            let phase = timeline.date.timeIntervalSinceReferenceDate
                .truncatingRemainder(dividingBy: Self.loopDuration) / Self.loopDuration
            GeometryReader { geo in
                let size = geo.size
                let p0 = CGPoint(x: 4, y: size.height * 0.8)
                let p1 = CGPoint(x: size.width - 4, y: size.height * 0.8)
                let control = CGPoint(x: size.width / 2, y: -size.height * 0.5)
                // Clamped parameter range keeps the package clear of the
                // endpoint badges flanking the canvas.
                let t = 0.10 + 0.80 * phase
                let position = Self.quadPoint(t: t, p0: p0, control: control, p1: p1)

                Canvas { context, _ in
                    var path = Path()
                    path.move(to: p0)
                    path.addQuadCurve(to: p1, control: control)
                    context.stroke(
                        path,
                        with: .color(Daybreak.faint.opacity(0.8)),
                        style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: [0.5, 7])
                    )
                }
                CarePackage()
                    // Gentle pendulum sway as it drifts.
                    .rotationEffect(.degrees(sin(phase * 2 * .pi * 2) * 5))
                    // Fade through the ends so loop restarts read as a new drop.
                    .opacity(min(1, min(phase, 1 - phase) * 12))
                    .position(x: position.x, y: position.y - 8)
            }
        }
    }

    /// Point on the quadratic Bézier: (1−t)²·p0 + 2(1−t)t·c + t²·p1.
    static func quadPoint(t: Double, p0: CGPoint, control: CGPoint, p1: CGPoint) -> CGPoint {
        let u = 1 - t
        return CGPoint(
            x: u * u * p0.x + 2 * u * t * control.x + t * t * p1.x,
            y: u * u * p0.y + 2 * u * t * control.y + t * t * p1.y
        )
    }
}

/// The app icon in miniature: a heart-in-a-box under a parachute. Rides the
/// bridge arc as the "your data is on its way" payload.
struct CarePackage: View {
    var body: some View {
        VStack(spacing: 0) {
            ParachuteCanopy()
                .fill(LinearGradient(
                    colors: [Daybreak.sun, Daybreak.sunDeep],
                    startPoint: .top, endPoint: .bottom
                ))
                .frame(width: 22, height: 9)
            HStack(spacing: 7) {
                shroudLine(angle: 18)
                shroudLine(angle: -18)
            }
            .frame(height: 5)
            RoundedRectangle(cornerRadius: 4.5, style: .continuous)
                .fill(Daybreak.card)
                .frame(width: 16, height: 14)
                .shadow(color: Daybreak.cardShadow, radius: 3, y: 2)
                .overlay {
                    Image(systemName: "heart.fill")
                        .font(.system(size: 8))
                        .foregroundStyle(Color(daybreakHex: 0xFB4D67))
                }
        }
    }

    private func shroudLine(angle: Double) -> some View {
        Rectangle()
            .fill(Daybreak.faint)
            .frame(width: 1, height: 6)
            .rotationEffect(.degrees(angle))
    }
}

/// Semicircular canopy with a three-scallop hem.
struct ParachuteCanopy: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let hem = rect.maxY
        path.move(to: CGPoint(x: rect.minX, y: hem))
        // Dome over the top.
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX, y: hem),
            control: CGPoint(x: rect.midX, y: rect.minY - rect.height * 0.6)
        )
        // Three downward-bulging scallops back along the hem.
        let scallop = rect.width / 3
        for i in 0..<3 {
            let from = rect.maxX - CGFloat(i) * scallop
            path.addQuadCurve(
                to: CGPoint(x: from - scallop, y: hem),
                control: CGPoint(x: from - scallop / 2, y: hem + rect.height * 0.45)
            )
        }
        path.closeSubpath()
        return path
    }
}

// MARK: - Agreement meter

/// Capsule meter showing how strongly the two trackers agree, 0–100.
struct AgreementMeter: View {
    let percent: Double

    init(percent: Double) {
        self.percent = percent
    }

    private var caption: String {
        let rounded = Int(percent.rounded())
        switch percent {
        case 80...: return "\(rounded)% — the two trackers tell the same story"
        case 60..<80: return "\(rounded)% — the two trackers mostly agree"
        default: return "\(rounded)% — the trackers disagree, worth a look"
        }
    }

    /// Below ~70% the meter goes amber so the tint matches the caption's
    /// "worth a look" tone; green is reserved for genuine agreement.
    private var agrees: Bool { percent >= 70 }

    private var fill: LinearGradient {
        LinearGradient(
            colors: agrees
                ? [Color(daybreakHex: 0x5FCB94), Daybreak.ok]
                : [Color(daybreakHex: 0xF0B45C), Daybreak.warn],
            startPoint: .leading, endPoint: .trailing
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Daybreak.track)
                    Capsule()
                        .fill(fill)
                        .frame(width: geo.size.width * min(max(percent / 100, 0), 1))
                }
            }
            .frame(height: 10)
            Text(caption)
                .font(.system(size: 12.5, weight: .bold, design: .rounded))
                .foregroundStyle(agrees ? Daybreak.ok : Daybreak.warn)
        }
    }
}

// MARK: - Check card

/// Friendly row for one sanity-check outcome.
struct CheckCard: View {
    let result: CheckResult

    init(result: CheckResult) {
        self.result = result
    }

    private var icon: (symbol: String, tint: Color, background: Color) {
        switch result.severity {
        case .pass: ("checkmark", Daybreak.ok, Daybreak.okChipBackground)
        case .info: ("info", Daybreak.plum, Daybreak.newChipBackground)
        case .warn: ("exclamationmark", Daybreak.warn, Daybreak.warnChipBackground)
        case .fail: ("xmark", Daybreak.fail, Daybreak.failChipBackground)
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Circle()
                .fill(icon.background)
                .frame(width: 30, height: 30)
                .overlay {
                    Image(systemName: icon.symbol)
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(icon.tint)
                }
            VStack(alignment: .leading, spacing: 2) {
                Text(result.name)
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .foregroundStyle(Daybreak.ink)
                Text(result.detail)
                    .font(.system(size: 12.5, design: .rounded))
                    .foregroundStyle(Daybreak.mid)
            }
            Spacer(minLength: 0)
        }
    }
}

// MARK: - Mini stat

/// Small white stat card for 2×2 grids: emoji (or SF symbol), big value, caption.
struct MiniStat: View {
    let symbol: String
    let value: String
    let caption: String

    init(_ symbol: String, value: String, caption: String) {
        self.symbol = symbol
        self.value = value
        self.caption = caption
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(symbol)
                .font(.system(size: 16))
            Text(value)
                .font(Daybreak.numberFont(size: 24))
                .foregroundStyle(Daybreak.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(caption)
                .font(.system(size: 11.5, weight: .medium, design: .rounded))
                .foregroundStyle(Daybreak.mid)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .daybreakCard(padding: 14)
    }
}

// MARK: - Heads up

/// Warm pre-GA note: glowing sun + plain-language caveat about the pre-release
/// Google Health API.
struct HeadsUpCard: View {
    let lead: String
    let message: String

    /// Review-everything copy (the default).
    static let reviewMessage = "Google's Health API is still pre-release. Until it's final (Sept 2026), fields can change — that's exactly why Airlift shows you every night before it lands in Apple Health."
    /// Automatic-mode variant of the same note.
    static let automaticMessage = "Google's Health API is still pre-release. Until it's final (Sept 2026), fields can change — anything unusual is held for your review."
    /// History-screen variant.
    static let historyMessage = "If Google changes the API, affected nights show up here as held for review — never written quietly."

    init(lead: String = "Heads up:", message: String = HeadsUpCard.reviewMessage) {
        self.lead = lead
        self.message = message
    }

    /// The variant matching the user's sync mode.
    static func forMode(_ mode: SyncMode) -> HeadsUpCard {
        HeadsUpCard(message: mode == .automatic ? automaticMessage : reviewMessage)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Circle()
                .fill(RadialGradient(
                    colors: [Color(daybreakHex: 0xFFD29A), Daybreak.sunDeep],
                    center: .center, startRadius: 2, endRadius: 18
                ))
                .frame(width: 30, height: 30)
                .shadow(color: Daybreak.sunDeep.opacity(0.45), radius: 8)
            (Text("\(lead) ").bold().foregroundStyle(Color(daybreakLight: 0xB3622A, dark: 0xF0A468))
                + Text(message).foregroundStyle(Color(daybreakLight: 0x7C5A33, dark: 0xC9A77E)))
                .font(.system(size: 12.5, design: .rounded))
            Spacer(minLength: 0)
        }
        .padding(16)
        .background(
            LinearGradient(
                colors: [
                    Color(daybreakLight: 0xFFF8EC, dark: 0x342819),
                    Color(daybreakLight: 0xFDEEDE, dark: 0x2A1F14),
                ],
                startPoint: .top, endPoint: .bottom
            ),
            in: RoundedRectangle(cornerRadius: 20, style: .continuous)
        )
    }
}

// MARK: - Day badge

/// 46×46 lavender square with the day number and a tiny weekday — anchors
/// review-queue rows.
struct DayBadge: View {
    let date: Date

    init(date: Date) {
        self.date = date
    }

    var body: some View {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(LinearGradient(
                colors: [
                    Color(daybreakLight: 0xEDE9FF, dark: 0x332C5E),
                    Color(daybreakLight: 0xDCD4F8, dark: 0x2A2450),
                ],
                startPoint: .top, endPoint: .bottom
            ))
            .frame(width: 46, height: 46)
            .overlay {
                VStack(spacing: 0) {
                    Text(date, format: .dateTime.day())
                        .font(.system(size: 18, weight: .heavy, design: .rounded))
                        .foregroundStyle(Daybreak.plum)
                    Text(date, format: .dateTime.weekday(.abbreviated))
                        .font(.system(size: 9, weight: .bold, design: .rounded))
                        .textCase(.uppercase)
                        .foregroundStyle(Daybreak.plum.opacity(0.65))
                }
            }
    }
}

// MARK: - Trust list

/// Pre-OAuth trust affordance: the three promises that matter before a user
/// hands over a Google sign-in — no servers, public code, read-only access.
/// Sits inside the connect card, above the Connect button.
struct TrustList: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            TrustRow(
                symbol: "lock.fill",
                tint: Daybreak.ok,
                background: Daybreak.okChipBackground,
                title: "Zero servers",
                detail: "Everything happens on this iPhone. Your data and Google sign-in never leave it."
            )
            TrustRow(
                symbol: "chevron.left.forwardslash.chevron.right",
                tint: Daybreak.plum,
                background: Daybreak.newChipBackground,
                title: "Open source",
                detail: "Every line of code is public on GitHub and community-reviewed."
            )
            TrustRow(
                symbol: "key.fill",
                tint: Daybreak.warn,
                background: Daybreak.warnChipBackground,
                title: "Read-only at Google",
                detail: "Airlift can only read your Fitbit data — it can never change or delete anything there."
            )
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Color(daybreakHex: 0xF7F5FC),
            in: RoundedRectangle(cornerRadius: 18, style: .continuous)
        )
    }
}

private struct TrustRow: View {
    let symbol: String
    let tint: Color
    let background: Color
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Circle()
                .fill(background)
                .frame(width: 30, height: 30)
                .overlay {
                    Image(systemName: symbol)
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(tint)
                }
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13.5, weight: .bold, design: .rounded))
                    .foregroundStyle(Daybreak.ink)
                Text(detail)
                    .font(.system(size: 12, design: .rounded))
                    .foregroundStyle(Daybreak.mid)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }
}
