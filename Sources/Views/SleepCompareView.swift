import SwiftUI
import Charts

/// Sleep, the Watch against Fitbit: total sleep and every stage, on average
/// and night by night.
///
/// Read straight from Health, so it works whichever way Fitbit's nights got
/// there — Airlift's import or Google Health's own sync. The Watch side is
/// only what an Apple device recorded.
struct SleepCompareView: View {
    @Environment(AppModel.self) private var model

    /// Opens on the most recent night; the clamp turns `Int.max` into "last".
    @State private var nightIndex = Int.max
    @State private var measure: SleepMeasure = .deep

    @ScaledMetric(relativeTo: .title) private var statValueSize: CGFloat = 22

    private var engine: RecoveryEngine { model.recovery }
    private var fitbitName: String { model.syncEngine.sourceDeviceName }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header
                switch engine.state {
                case .idle:
                    card("Nothing read yet", "Pull a stretch of nights out of Health to compare.")
                case .loading(let step):
                    HStack(spacing: 12) {
                        ProgressView()
                        Text(step).font(Daybreak.bodyFont).foregroundStyle(Daybreak.mid)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .daybreakCard()
                case .failed(let message):
                    card("Could not read Health", message)
                case .ready:
                    content(engine.sleep)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, 40)
        }
        .scrollIndicators(.hidden)
        .daybreakBackground()
        .navigationTitle("Sleep")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task { await engine.load() }
                } label: {
                    Image(systemName: "arrow.clockwise").foregroundStyle(Daybreak.mid)
                }
                .disabled(engine.state.isLoading)
                .accessibilityLabel("Read the nights again")
            }
        }
        .task {
            if case .idle = engine.state { await engine.load() }
        }
    }

    // MARK: - Chrome

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Sleep, side by side")
                .font(Daybreak.titleFont)
                .foregroundStyle(Daybreak.ink)
            Text("How long you slept and in which stages, as your Watch and \(fitbitName) each scored the same nights.")
                .font(Daybreak.bodyFont)
                .foregroundStyle(Daybreak.mid)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func card(_ title: String, _ message: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(.headline, design: .rounded, weight: .bold))
                .foregroundStyle(Daybreak.ink)
            Text(message).font(Daybreak.bodyFont).foregroundStyle(Daybreak.mid)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .daybreakCard()
    }

    @ViewBuilder
    private func content(_ report: SleepComparisonReport) -> some View {
        if report.nights.isEmpty {
            card("No sleep in Health", "Neither the Watch nor \(fitbitName) has a night in Health for this stretch.")
        } else {
            if report.paired.isEmpty {
                card(
                    "No night from both yet",
                    "Wear both overnight and let Fitbit's night reach Health — through Google Health's own sync or Airlift — and the comparison fills in."
                )
            } else {
                Text("On average").daybreakSectionLabel()
                averagesCard(report)
            }
            Text("Night to night").daybreakSectionLabel()
            trendCard(report)
            Text("One night").daybreakSectionLabel()
            nightCard(report)
        }
    }

    // MARK: - Averages

    private func averagesCard(_ report: SleepComparisonReport) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Stage").frame(maxWidth: .infinity, alignment: .leading)
                Text("Watch").frame(width: 62, alignment: .trailing)
                Text("Fitbit").frame(width: 62, alignment: .trailing)
                Text("Fitbit Δ").frame(width: 62, alignment: .trailing)
            }
            .font(.system(.caption2, design: .rounded, weight: .semibold))
            .foregroundStyle(Daybreak.faint)
            ForEach(SleepMeasure.allCases) { measure in
                if let summary = report.summary(measure) {
                    HStack {
                        Text(measure.displayName)
                            .font(.system(.subheadline, design: .rounded, weight: .semibold))
                            .foregroundStyle(Daybreak.ink)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text(Self.duration(summary.watchMean)).frame(width: 62, alignment: .trailing)
                            .foregroundStyle(Daybreak.teal)
                        Text(Self.duration(summary.fitbitMean)).frame(width: 62, alignment: .trailing)
                            .foregroundStyle(Daybreak.sunDeep)
                        Text(Self.signed(summary.meanDifference)).frame(width: 62, alignment: .trailing)
                            .foregroundStyle(Daybreak.mid)
                    }
                    .font(.system(.subheadline, design: .rounded).monospacedDigit())
                }
            }
            Divider().overlay(Daybreak.line)
            Text(averagesFootnote(report))
                .font(Daybreak.captionFont)
                .foregroundStyle(Daybreak.mid)
                .fixedSize(horizontal: false, vertical: true)
        }
        .daybreakCard()
    }

    private func averagesFootnote(_ report: SleepComparisonReport) -> String {
        let count = report.paired.count
        var text = "Across \(count) night\(count == 1 ? "" : "s") both devices scored."
        if let agreement = report.medianAgreement {
            text += " On a typical night they give the same stage \(Int(agreement.rounded()))% of the minutes both were tracking."
        }
        if let deep = report.summary(.deep), let sd = deep.differenceSD, deep.nights >= 3 {
            text += " The deep-sleep gap swings ±\(Int(sd.rounded())) m from night to night, so a single night's difference says little on its own."
        }
        return text
    }

    // MARK: - Trend

    private func trendCard(_ report: SleepComparisonReport) -> some View {
        let nights = report.nights
        return VStack(alignment: .leading, spacing: 12) {
            Picker("Measure", selection: $measure) {
                ForEach(SleepMeasure.allCases) { measure in
                    Text(Self.shortName(measure)).tag(measure)
                }
            }
            .pickerStyle(.segmented)
            Chart {
                ForEach(nights) { night in
                    if let watch = night.watch {
                        LineMark(
                            x: .value("Night", night.night, unit: .day),
                            y: .value("Minutes", measure.minutes(watch)),
                            series: .value("Device", "Watch")
                        )
                        .foregroundStyle(Daybreak.teal)
                        PointMark(
                            x: .value("Night", night.night, unit: .day),
                            y: .value("Minutes", measure.minutes(watch))
                        )
                        .foregroundStyle(Daybreak.teal)
                        .symbolSize(18)
                    }
                    if let fitbit = night.fitbit {
                        LineMark(
                            x: .value("Night", night.night, unit: .day),
                            y: .value("Minutes", measure.minutes(fitbit)),
                            series: .value("Device", "Fitbit")
                        )
                        .foregroundStyle(Daybreak.sunDeep)
                        PointMark(
                            x: .value("Night", night.night, unit: .day),
                            y: .value("Minutes", measure.minutes(fitbit))
                        )
                        .foregroundStyle(Daybreak.sunDeep)
                        .symbolSize(18)
                    }
                }
            }
            .chartYAxis {
                AxisMarks { value in
                    AxisGridLine().foregroundStyle(Daybreak.line)
                    AxisValueLabel {
                        if let minutes = value.as(Double.self) { Text(Self.duration(minutes)) }
                    }
                }
            }
            .frame(height: 190)
            HStack(spacing: 14) {
                legendDot(Daybreak.teal, report.nights.lazy.compactMap(\.watchDevice).first ?? "Watch")
                legendDot(Daybreak.sunDeep, fitbitName)
            }
        }
        .daybreakCard(padding: 18)
    }

    private func legendDot(_ color: Color, _ label: String) -> some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(label)
                .font(.system(.caption2, design: .rounded, weight: .semibold))
                .foregroundStyle(Daybreak.mid)
        }
    }

    // MARK: - One night

    private func nightCard(_ report: SleepComparisonReport) -> some View {
        let nights = report.nights
        let index = min(max(nightIndex, 0), max(nights.count - 1, 0))
        let night = nights[index]
        let domain = StageStrip.sharedDomain(google: night.fitbitSegments, apple: night.watchSegments)

        return VStack(alignment: .leading, spacing: 14) {
            HStack {
                Button { nightIndex = max(0, index - 1) } label: { Image(systemName: "chevron.left") }
                    .disabled(index <= 0)
                Spacer(minLength: 0)
                VStack(spacing: 1) {
                    Text(night.night.formatted(.dateTime.weekday(.wide).month(.abbreviated).day()))
                        .font(.system(.subheadline, design: .rounded, weight: .bold))
                        .foregroundStyle(Daybreak.ink)
                    Text("\(index + 1) of \(nights.count)")
                        .font(Daybreak.captionFont)
                        .foregroundStyle(Daybreak.faint)
                }
                Spacer(minLength: 0)
                Button { nightIndex = min(nights.count - 1, index + 1) } label: { Image(systemName: "chevron.right") }
                    .disabled(index >= nights.count - 1)
            }
            .font(.system(.body, weight: .semibold))
            .foregroundStyle(Daybreak.plum)

            if let domain {
                lane(fitbitName, minutes: night.fitbit) {
                    StageStrip(google: night.fitbitSegments, domain: domain)
                }
                lane(night.watchDevice ?? "Watch", minutes: night.watch) {
                    StageStrip(apple: night.watchSegments.filter { $0.value != .inBed }, domain: domain)
                }
                stageLegend(night)
            }

            VStack(spacing: 8) {
                ForEach(SleepMeasure.allCases) { measure in
                    stageRow(measure, night: night)
                }
            }
            if let agreement = night.agreement {
                Text("Same stage \(Int(agreement.rounded()))% of the minutes both were tracking.")
                    .font(Daybreak.captionFont)
                    .foregroundStyle(Daybreak.mid)
            }
        }
        .daybreakCard(padding: 18)
    }

    private func lane<Strip: View>(
        _ name: String, minutes: StageMinutes?, @ViewBuilder strip: () -> Strip
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(name)
                    .font(.system(.caption, design: .rounded, weight: .semibold))
                    .foregroundStyle(Daybreak.ink)
                Spacer()
                Text(minutes.map { "\(Self.duration($0.asleep)) asleep" } ?? "No night")
                    .font(.system(.caption, design: .rounded).monospacedDigit())
                    .foregroundStyle(Daybreak.mid)
            }
            if minutes != nil { strip() }
        }
    }

    private func stageLegend(_ night: SleepNightComparison) -> some View {
        var present = Set(night.fitbitSegments.map { LaneStage(google: $0.stage) })
        present.formUnion(night.watchSegments.compactMap { LaneStage(apple: $0.value) }.filter { $0 != .inBed })
        return HStack(spacing: 12) {
            ForEach(LaneStage.allCases.filter(present.contains), id: \.self) { stage in
                legendDot(stage.daybreakColor, stage.legendName)
            }
        }
    }

    private func stageRow(_ measure: SleepMeasure, night: SleepNightComparison) -> some View {
        let watch = night.watch.map(measure.minutes)
        let fitbit = night.fitbit.map(measure.minutes)
        return HStack {
            Text(measure.displayName)
                .font(.system(.footnote, design: .rounded, weight: .semibold))
                .foregroundStyle(Daybreak.ink)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(watch.map(Self.duration) ?? "—").frame(width: 62, alignment: .trailing)
                .foregroundStyle(Daybreak.teal)
            Text(fitbit.map(Self.duration) ?? "—").frame(width: 62, alignment: .trailing)
                .foregroundStyle(Daybreak.sunDeep)
            Text(watch.flatMap { w in fitbit.map { Self.signed($0 - w) } } ?? "").frame(width: 62, alignment: .trailing)
                .foregroundStyle(Daybreak.mid)
        }
        .font(.system(.footnote, design: .rounded).monospacedDigit())
    }

    // MARK: - Formatting

    private static func shortName(_ measure: SleepMeasure) -> String {
        switch measure {
        case .total: "Total"
        case .deep: "Deep"
        case .rem: "REM"
        case .core: "Light"
        case .awake: "Awake"
        }
    }

    /// "7h 42m", or "48m" under an hour.
    static func duration(_ minutes: Double) -> String {
        let total = Int(minutes.rounded())
        return total >= 60 ? "\(total / 60)h \(String(format: "%02d", total % 60))m" : "\(total)m"
    }

    /// "+23m" / "−1h 05m".
    static func signed(_ minutes: Double) -> String {
        let rounded = Int(minutes.rounded())
        if rounded == 0 { return "±0m" }
        return (rounded > 0 ? "+" : "−") + duration(Double(abs(rounded)))
    }
}
