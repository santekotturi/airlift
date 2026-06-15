import SwiftUI
import Charts
import HealthKit

/// Normalized display stage so Google and Apple segments share one color scale.
enum LaneStage: String, CaseIterable {
    case awake = "Awake"
    case rem = "REM"
    case core = "Light/Core"
    case deep = "Deep"
    case asleep = "Asleep"
    case inBed = "In Bed"

    init(google stage: SleepStage) {
        switch stage {
        case .wake, .restless: self = .awake
        case .light: self = .core
        case .deep: self = .deep
        case .rem: self = .rem
        case .asleep, .unknown: self = .asleep
        }
    }

    init?(apple value: HKCategoryValueSleepAnalysis) {
        switch value {
        case .awake: self = .awake
        case .asleepCore: self = .core
        case .asleepDeep: self = .deep
        case .asleepREM: self = .rem
        case .asleepUnspecified: self = .asleep
        case .inBed: self = .inBed
        @unknown default: return nil
        }
    }
}

private extension LaneStage {
    /// Short legend wording ("Light", not "Light/Core").
    var legendName: String {
        switch self {
        case .awake: "Awake"
        case .rem: "REM"
        case .core: "Light"
        case .deep: "Deep"
        case .asleep: "Asleep"
        case .inBed: "In bed"
        }
    }
}

private extension LaneStage {
    /// Hypnogram depth band: Awake at the top of the y-axis, Deep at the bottom.
    var depth: Double {
        switch self {
        case .awake, .inBed: 3
        case .rem: 2
        case .core, .asleep: 1
        case .deep: 0
        }
    }
}

/// One Fitbit stage band in the depth hypnogram.
private struct DepthBand: Identifiable {
    let id = UUID()
    let stage: LaneStage
    let start: Date
    let end: Date
}

/// One vertex of the Apple Health step line in the depth hypnogram.
private struct DepthPoint: Identifiable {
    let id = UUID()
    let date: Date
    let depth: Double
}

/// Side-by-side validation of one Google sleep session against whatever
/// Apple Health already holds for the night: labeled stage strips with an
/// agreement meter, the minute-by-minute hypnogram and overnight heart rate,
/// the night in numbers, sanity checks, and the import-or-skip decision.
struct SessionCompareView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    let staged: StagedSession
    var mode: CompareMode = .review
    /// Pager hook: called after import/skip instead of popping, so the
    /// review-all flow can advance to the next held item.
    var onDecision: (() -> Void)?

    private var deviceName: String { model.syncEngine.sourceDeviceName }

    @State private var isImporting = false
    @State private var importFailed = false
    @State private var confirmingRemoval = false

    private var session: SleepSession { staged.session }
    private var hasApple: Bool { !staged.appleSleep.isEmpty }

    /// What the comparison lane actually is: whatever Apple Health already
    /// holds for the night — Apple Watch, AutoSleep, iPhone, a manual entry.
    /// Named when one source wrote it all; mixed or empty falls back to the
    /// umbrella "Apple Health" rather than guessing.
    private var appleSourceLabel: String {
        let names = Set(staged.appleSleep.map(\.sourceName))
        if names.count == 1, let only = names.first { return only }
        return "Apple Health"
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                comparisonCard
                Text("Minute by minute").daybreakSectionLabel()
                hypnogramCard
                if !staged.heartRate.isEmpty {
                    heartRateCard
                }
                Text("The night in numbers").daybreakSectionLabel()
                statsGrid
                Text(mode == .review ? "Before it lands" : "How it holds up").daybreakSectionLabel()
                checksCard
                switch mode {
                case .review: footer
                case .history(let day): historyFooter(day: day)
                }
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 24)
        }
        .daybreakBackground()
        .toolbarBackground(.hidden, for: .navigationBar)
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Header

    /// "Last night" when the session ended today, otherwise the weekday the
    /// night began ("Monday night").
    private var title: String {
        Calendar.current.isDateInToday(session.end)
            ? "Last night"
            : "\(session.start.formatted(.dateTime.weekday(.wide))) night"
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(Daybreak.titleFont)
                .foregroundStyle(Daybreak.ink)
            Text(hasApple
                 ? "\(deviceName)'s reading vs. what's already in Apple Health."
                 : "\(deviceName)'s reading — Apple Health has nothing for this night yet.")
                .font(Daybreak.bodyFont)
                .foregroundStyle(Daybreak.mid)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 8)
    }

    // MARK: - Comparison card

    /// Strip + chart x-domain: the night, plus nearby Apple data so misalignment
    /// shows — but clamped to ±3 h of the session so a distant daytime nap or a
    /// mis-windowed segment can't balloon the axis and squeeze the night into a
    /// sliver. Marks outside this range are clipped by the x-scale.
    private var xDomain: ClosedRange<Date> {
        let lo = session.start.addingTimeInterval(-3 * 3_600)
        let hi = session.end.addingTimeInterval(3 * 3_600)
        let start = ([session.start] + staged.appleSleep.map(\.start)).min()!
        let end = ([session.end] + staged.appleSleep.map(\.end)).max()!
        return Swift.max(start, lo)...Swift.min(end, hi)
    }

    /// A "nice" hour stride (1/2/3/4/6) that keeps ~4–5 x-axis labels for the
    /// visible span instead of crowding them into an unreadable smear.
    private var hourStride: Int {
        let hours = xDomain.upperBound.timeIntervalSince(xDomain.lowerBound) / 3600
        switch hours {
        case ..<5: return 1
        case ..<9: return 2
        case ..<13: return 3
        case ..<19: return 4
        default: return 6
        }
    }

    private var statusChip: DaybreakChip {
        switch staged.worstSeverity {
        case .pass, .info: DaybreakChip("✓ checks pass", status: .ok)
        case .warn: DaybreakChip("! held back", status: .warn)
        case .fail: DaybreakChip("✕ failed checks", status: .fail)
        }
    }

    private var comparisonCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            laneLabel(deviceName, detail: hm(session.end.timeIntervalSince(session.start))) {
                statusChip
            }
            StageStrip(google: session.stages, domain: xDomain, span: session.start...session.end)
            if hasApple {
                laneLabel(appleSourceLabel, detail: "\(hm(appleAsleepSeconds)) · already in Health")
                    .padding(.top, 6)
                StageStrip(apple: staged.appleSleep, domain: xDomain)
            } else {
                Text("No Apple data for this night.")
                    .font(Daybreak.bodyFont)
                    .foregroundStyle(Daybreak.mid)
                    .padding(.top, 6)
            }
            legend
                .padding(.top, 4)
            Rectangle()
                .fill(Daybreak.line)
                .frame(height: 1)
                .padding(.vertical, 4)
            Text("Agreement with \(appleSourceLabel)")
                .font(.system(.caption, design: .rounded, weight: .semibold))
                .foregroundStyle(Daybreak.mid)
            if let percent = agreementPercent {
                AgreementMeter(percent: percent)
            } else {
                Text(hasApple
                     ? "The two nights barely overlap — nothing to compare."
                     : "Nothing to compare against — Apple Health has no sleep for this night.")
                    .font(.system(.caption, design: .rounded, weight: .medium))
                    .foregroundStyle(Daybreak.faint)
            }
        }
        .daybreakCard(padding: 18)
    }

    private var agreementPercent: Double? {
        SleepAgreement.percent(google: session.stages, apple: staged.appleSleep)
    }

    private func laneLabel(
        _ name: String,
        detail: String,
        @ViewBuilder accessory: () -> some View = { EmptyView() }
    ) -> some View {
        HStack(spacing: 8) {
            (Text(name.uppercased()).foregroundStyle(Daybreak.faint)
                + Text(" · \(detail)").foregroundStyle(Daybreak.mid))
                .font(Daybreak.sectionLabelFont)
                .tracking(1.2)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Spacer(minLength: 0)
            accessory()
        }
    }

    /// Stages actually present in either lane, in canonical order — plus
    /// "In bed" when the strips show unscored session time in the in-bed gray.
    private var legendStages: [LaneStage] {
        var present = Set(session.stages.map { LaneStage(google: $0.stage) })
        present.formUnion(staged.appleSleep.compactMap { LaneStage(apple: $0.value) })
        let scored = session.stages.reduce(0) { $0 + $1.end.timeIntervalSince($1.start) }
        if scored + 60 < session.end.timeIntervalSince(session.start) {
            present.insert(.inBed)
        }
        return LaneStage.allCases.filter(present.contains)
    }

    private var legend: some View {
        HStack(spacing: 12) {
            ForEach(legendStages, id: \.self) { stage in
                HStack(spacing: 5) {
                    Circle()
                        .fill(stage.daybreakColor)
                        .frame(width: 7, height: 7)
                    Text(stage.legendName)
                        .font(.system(.caption2, design: .rounded, weight: .semibold))
                        .foregroundStyle(Daybreak.mid)
                }
            }
        }
    }

    // MARK: - Hypnogram

    /// Fitbit stage bands with a minimum display width (~1% of the domain) so
    /// brief wakes stay visible instead of collapsing to hairline slivers.
    private var googleBands: [DepthBand] {
        let minSpan = xDomain.upperBound.timeIntervalSince(xDomain.lowerBound) / 100
        return session.stages.map {
            DepthBand(
                stage: LaneStage(google: $0.stage),
                start: $0.start,
                end: max($0.end, $0.start.addingTimeInterval(minSpan))
            )
        }
    }

    private var appleDepthPoints: [DepthPoint] {
        staged.appleSleep
            .sorted { $0.start < $1.start }
            .flatMap { segment -> [DepthPoint] in
                guard let stage = LaneStage(apple: segment.value) else { return [] }
                return [
                    DepthPoint(date: segment.start, depth: stage.depth),
                    DepthPoint(date: segment.end, depth: stage.depth),
                ]
            }
    }

    private static let depthLabels: [Double: String] = [3: "Awake", 2: "REM", 1: "Light", 0: "Deep"]

    private var hypnogramCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Chart {
                ForEach(googleBands) { band in
                    RectangleMark(
                        xStart: .value("Start", band.start),
                        xEnd: .value("End", band.end),
                        yStart: .value("Depth", band.stage.depth - 0.36),
                        yEnd: .value("Depth", band.stage.depth + 0.36)
                    )
                    .foregroundStyle(band.stage.daybreakColor)
                    .cornerRadius(2)
                }
                ForEach(appleDepthPoints) { point in
                    LineMark(
                        x: .value("Time", point.date),
                        y: .value("Depth", point.depth)
                    )
                    .interpolationMethod(.stepEnd)
                    .foregroundStyle(Daybreak.ink.opacity(0.5))
                    .lineStyle(StrokeStyle(lineWidth: 1.6, lineCap: .round))
                }
            }
            .chartXScale(domain: xDomain)
            .chartYScale(domain: -0.55...3.55)
            .chartXAxis {
                AxisMarks(values: clockAlignedTicks(in: xDomain, everyHours: hourStride)) { _ in
                    AxisGridLine().foregroundStyle(Daybreak.line)
                    AxisValueLabel(format: .dateTime.hour())
                        .font(.system(.caption2, design: .rounded, weight: .medium))
                        .foregroundStyle(Daybreak.faint)
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading, values: [0.0, 1, 2, 3]) { value in
                    AxisGridLine().foregroundStyle(Daybreak.line)
                    AxisValueLabel {
                        Text(Self.depthLabels[value.as(Double.self) ?? -1] ?? "")
                            .font(.system(.caption2, design: .rounded, weight: .semibold))
                            .foregroundStyle(Daybreak.mid)
                    }
                }
            }
            .frame(height: 150)
            if hasApple {
                hypnogramKey
            }
        }
        .daybreakCard(padding: 18)
    }

    private var hypnogramKey: some View {
        HStack(spacing: 14) {
            HStack(spacing: 5) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Daybreak.stageCore)
                    .frame(width: 14, height: 7)
                Text(deviceName)
            }
            HStack(spacing: 5) {
                Capsule()
                    .fill(Daybreak.ink.opacity(0.5))
                    .frame(width: 14, height: 2)
                Text(appleSourceLabel)
            }
        }
        .font(.system(.caption2, design: .rounded, weight: .semibold))
        .foregroundStyle(Daybreak.mid)
    }

    // MARK: - Heart rate

    private var heartRateCard: some View {
        let bpms = staged.heartRate.map(\.bpm)
        let range = "\(Int(bpms.min() ?? 0))–\(Int(bpms.max() ?? 0)) bpm"
        return VStack(alignment: .leading, spacing: 10) {
            laneLabel("Overnight heart rate", detail: "Apple Health · \(range)")
            Chart(staged.heartRate) { sample in
                LineMark(
                    x: .value("Time", sample.date),
                    y: .value("BPM", sample.bpm)
                )
                .interpolationMethod(.monotone)
                .foregroundStyle(Daybreak.sunDeep)
                .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round))
            }
            .chartXScale(domain: xDomain)
            .chartYScale(domain: .automatic(includesZero: false))
            .chartXAxis {
                AxisMarks(values: clockAlignedTicks(in: xDomain, everyHours: hourStride)) { _ in
                    AxisGridLine().foregroundStyle(Daybreak.line)
                    AxisValueLabel(format: .dateTime.hour())
                        .font(.system(.caption2, design: .rounded, weight: .medium))
                        .foregroundStyle(Daybreak.faint)
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { _ in
                    AxisGridLine().foregroundStyle(Daybreak.line)
                    AxisValueLabel()
                        .font(.system(.caption2, design: .rounded, weight: .medium))
                        .foregroundStyle(Daybreak.faint)
                }
            }
            .frame(height: 90)
        }
        .daybreakCard(padding: 18)
    }

    // MARK: - Stats

    private var googleAsleepSeconds: TimeInterval {
        session.stages
            .filter { $0.stage != .wake && $0.stage != .restless }
            .reduce(0) { $0 + $1.end.timeIntervalSince($1.start) }
    }

    private var appleAsleepSeconds: TimeInterval {
        staged.appleSleep.filter(\.isAsleep).reduce(0) { $0 + $1.duration }
    }

    private func googleStageSeconds(_ stage: SleepStage) -> TimeInterval {
        session.stages.filter { $0.stage == stage }
            .reduce(0) { $0 + $1.end.timeIntervalSince($1.start) }
    }

    private func appleStageSeconds(_ value: HKCategoryValueSleepAnalysis) -> TimeInterval {
        staged.appleSleep.filter { $0.value == value }.reduce(0) { $0 + $1.duration }
    }

    /// "Deep · +8 m vs Apple" when Apple recorded the stage too, else just the name.
    private func stageCaption(_ name: String, google: TimeInterval, apple: TimeInterval) -> String {
        guard apple > 0 else { return name }
        let delta = Int(((google - apple) / 60).rounded())
        return "\(name) · \(String(format: "%+d", delta)) m vs Apple"
    }

    /// Mean of the lowest decile of overnight readings — a steadier "resting"
    /// figure than the single minimum.
    private var restingBPM: Int {
        let sorted = staged.heartRate.map(\.bpm).sorted()
        let count = max(1, sorted.count / 10)
        return Int((sorted.prefix(count).reduce(0, +) / Double(count)).rounded())
    }

    private var efficiencyPercent: Int {
        let span = session.end.timeIntervalSince(session.start)
        guard span > 0 else { return 0 }
        return Int((googleAsleepSeconds / span * 100).rounded())
    }

    private var statsGrid: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible())], spacing: 12) {
            MiniStat(
                "🌙",
                value: hm(googleStageSeconds(.deep)),
                caption: stageCaption("Deep", google: googleStageSeconds(.deep), apple: appleStageSeconds(.asleepDeep))
            )
            MiniStat(
                "💭",
                value: hm(googleStageSeconds(.rem)),
                caption: stageCaption("REM", google: googleStageSeconds(.rem), apple: appleStageSeconds(.asleepREM))
            )
            MiniStat("😴", value: hm(googleAsleepSeconds), caption: "asleep total")
            if staged.heartRate.isEmpty {
                MiniStat("✨", value: "\(efficiencyPercent)%", caption: "sleep efficiency")
            } else {
                MiniStat("❤️", value: "\(restingBPM) bpm", caption: "resting overnight")
            }
        }
    }

    // MARK: - Checks

    private var checksCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(staged.checks) { check in
                CheckCard(result: check)
                if check.id != staged.checks.last?.id {
                    Rectangle()
                        .fill(Daybreak.line)
                        .frame(height: 1)
                        .padding(.vertical, 12)
                }
            }
        }
        .daybreakCard(padding: 18)
    }

    // MARK: - Decision

    private var footer: some View {
        VStack(spacing: 10) {
            Button {
                isImporting = true
                importFailed = false
                Task {
                    // A false return means the HealthKit write failed and the
                    // night is still staged — moving on would tell the user
                    // it landed when it didn't.
                    if await model.syncEngine.importStaged(staged.id) {
                        if let onDecision { onDecision() } else { dismiss() }
                    } else {
                        isImporting = false
                        importFailed = true
                    }
                }
            } label: {
                Text(isImporting ? "Adding to Apple Health…" : "Looks right — add to Apple Health")
            }
            .buttonStyle(.daybreakPrimary)
            .disabled(isImporting)

            if importFailed {
                Text("That didn't make it into Apple Health — the night is still here, untouched. Try again in a moment.")
                    .font(.system(.caption, design: .rounded, weight: .semibold))
                    .foregroundStyle(Daybreak.fail)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
            }

            Button("Skip this night") {
                model.syncEngine.toss(staged.id)
                if let onDecision { onDecision() } else { dismiss() }
            }
            .buttonStyle(.daybreakGhost)
            .disabled(isImporting)

            Text("Writes \(session.stages.count) stage samples + 1 in-bed sample. Re-syncs never duplicate.")
                .font(.system(.caption2, design: .rounded, weight: .medium))
                .foregroundStyle(Daybreak.faint)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
        }
        .padding(.top, 6)
    }

    /// Calendar mode: the night is already in Apple Health — the only
    /// decision is whether it stays.
    private func historyFooter(day: Date) -> some View {
        VStack(spacing: 10) {
            Button("Remove from Apple Health") {
                confirmingRemoval = true
            }
            .buttonStyle(.daybreakDestructiveGhost)
            Text("This night is already in Apple Health. Removing takes out Airlift's \(session.stages.count + 1) samples — other sources stay untouched, and it won't come back.")
                .font(.system(.caption2, design: .rounded, weight: .medium))
                .foregroundStyle(Daybreak.faint)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
        }
        .padding(.top, 6)
        .confirmationDialog("Remove this night from Apple Health?", isPresented: $confirmingRemoval, titleVisibility: .visible) {
            Button("Remove from Apple Health", role: .destructive) {
                Task {
                    await model.syncEngine.removeOwnData(kind: nil, day: day)
                    dismiss()
                }
            }
            Button("Keep it", role: .cancel) {}
        } message: {
            Text("Only Airlift's samples are removed. It won't be re-imported.")
        }
    }

    // MARK: - Formatting

    /// "7 h 24 m", or "45 m" under an hour.
    private func hm(_ seconds: TimeInterval) -> String {
        let minutes = Int((seconds / 60).rounded())
        return minutes >= 60 ? "\(minutes / 60) h \(minutes % 60) m" : "\(minutes) m"
    }
}

extension CheckResult.Severity {
    var iconName: String {
        switch self {
        case .pass: return "checkmark.circle.fill"
        case .info: return "info.circle.fill"
        case .warn: return "exclamationmark.triangle.fill"
        case .fail: return "xmark.octagon.fill"
        }
    }

    var iconColor: Color {
        switch self {
        case .pass: return .green
        case .info: return .blue
        case .warn: return .yellow
        case .fail: return .red
        }
    }
}
