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

    var color: Color {
        switch self {
        case .awake: return .orange
        case .rem: return .purple
        case .core: return .teal
        case .deep: return .indigo
        case .asleep: return .blue
        case .inBed: return .gray.opacity(0.6)
        }
    }

    static var colorScale: KeyValuePairs<String, Color> {
        [
            "Awake": .orange,
            "REM": .purple,
            "Light/Core": .teal,
            "Deep": .indigo,
            "Asleep": .blue,
            "In Bed": Color.gray.opacity(0.6),
        ]
    }
}

/// One bar in the hypnogram.
private struct LaneMark: Identifiable {
    let id = UUID()
    let lane: String
    let stage: LaneStage
    let start: Date
    let end: Date
}

/// Side-by-side validation of one Google sleep session against Apple Watch data:
/// dual-lane hypnogram, overnight heart rate, sanity checks, and the
/// import-or-toss decision.
struct SessionCompareView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    let staged: StagedSession

    private var session: SleepSession { staged.session }

    var body: some View {
        List {
            chartSection
            if !staged.heartRate.isEmpty {
                heartRateSection
            }
            statsSection
            checksSection
            decisionSection
        }
        .navigationTitle(session.end.formatted(date: .abbreviated, time: .omitted))
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Hypnogram

    private var laneMarks: [LaneMark] {
        let google = session.stages.map {
            LaneMark(lane: "Google", stage: LaneStage(google: $0.stage), start: $0.start, end: $0.end)
        }
        let apple = staged.appleSleep.compactMap { segment -> LaneMark? in
            guard let stage = LaneStage(apple: segment.value) else { return nil }
            return LaneMark(lane: "Apple", stage: stage, start: segment.start, end: segment.end)
        }
        return google + apple
    }

    /// Chart x-domain: union of both sources, so misaligned nights are obvious.
    private var xDomain: ClosedRange<Date> {
        let starts = [session.start] + staged.appleSleep.map(\.start)
        let ends = [session.end] + staged.appleSleep.map(\.end)
        return starts.min()!...ends.max()!
    }

    private var chartSection: some View {
        Section("Stages — Apple vs Google") {
            if staged.appleSleep.isEmpty {
                Text("No Apple sleep data for this night.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Chart(laneMarks) { mark in
                RectangleMark(
                    xStart: .value("Start", mark.start),
                    xEnd: .value("End", mark.end),
                    y: .value("Source", mark.lane)
                )
                .foregroundStyle(by: .value("Stage", mark.stage.rawValue))
                .cornerRadius(2)
            }
            .chartForegroundStyleScale(LaneStage.colorScale)
            .chartXScale(domain: xDomain)
            .chartLegend(position: .bottom, spacing: 8)
            .frame(height: 140)
            .padding(.vertical, 4)
        }
    }

    // MARK: - Heart rate

    private var heartRateSection: some View {
        Section("Overnight heart rate (Apple Watch)") {
            Chart(staged.heartRate) { sample in
                LineMark(
                    x: .value("Time", sample.date),
                    y: .value("BPM", sample.bpm)
                )
                .interpolationMethod(.monotone)
                .foregroundStyle(.red)
            }
            .chartXScale(domain: xDomain)
            .chartYScale(domain: .automatic(includesZero: false))
            .frame(height: 100)
            .padding(.vertical, 4)
        }
    }

    // MARK: - Stats

    private var googleAsleepHours: Double {
        session.stages
            .filter { $0.stage != .wake && $0.stage != .restless }
            .reduce(0.0) { $0 + $1.end.timeIntervalSince($1.start) } / 3600
    }

    private var appleAsleepHours: Double {
        staged.appleSleep.filter(\.isAsleep).reduce(0.0) { $0 + $1.duration } / 3600
    }

    private var statsSection: some View {
        Section("Numbers") {
            LabeledContent("Google session") {
                Text("\(session.start.formatted(date: .omitted, time: .shortened)) – \(session.end.formatted(date: .omitted, time: .shortened))")
            }
            LabeledContent("Google asleep", value: String(format: "%.1f h", googleAsleepHours))
            if !staged.appleSleep.isEmpty {
                LabeledContent("Apple asleep", value: String(format: "%.1f h", appleAsleepHours))
                LabeledContent("Δ asleep", value: String(format: "%+.0f min", (googleAsleepHours - appleAsleepHours) * 60))
                if let source = staged.appleSleep.first?.sourceName {
                    LabeledContent("Apple source", value: source)
                }
            }
            LabeledContent("Stage segments", value: "\(session.stages.count)")
            LabeledContent("dataPoint ID") {
                Text(session.id).font(.caption2.monospaced()).lineLimit(1).truncationMode(.middle)
            }
        }
    }

    // MARK: - Checks

    private var checksSection: some View {
        Section("Sanity checks") {
            ForEach(staged.checks) { check in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Image(systemName: check.severity.iconName)
                        .foregroundStyle(check.severity.iconColor)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(check.name).font(.subheadline.weight(.medium))
                        Text(check.detail).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    // MARK: - Decision

    private var decisionSection: some View {
        Section {
            Button {
                Task {
                    await model.syncEngine.importStaged(staged.id)
                    dismiss()
                }
            } label: {
                Label("Import into Apple Health", systemImage: "square.and.arrow.down.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)

            Button(role: .destructive) {
                model.syncEngine.toss(staged.id)
                dismiss()
            } label: {
                Label("Toss (never import)", systemImage: "trash")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
        } footer: {
            Text("Import writes per-stage samples plus one In Bed sample. Toss permanently hides this session from future fetches.")
        }
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
