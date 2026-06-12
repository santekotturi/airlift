import SwiftUI
import Charts

/// Daybreak metric review: one day of one quantity metric, Google's readings
/// charted against Apple's, the headline numbers with their delta, sanity
/// checks, and the import-or-skip decision. Nothing is written until approved.
struct MetricCompareView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    let batch: StagedMetricBatch

    @State private var isImporting = false

    private static let googleSeries = "Fitbit Air"
    private static let appleSeries = "Apple Health"

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header
                chartCard
                VStack(alignment: .leading, spacing: 10) {
                    Text("The numbers").daybreakSectionLabel()
                    numbersCard
                }
                VStack(alignment: .leading, spacing: 10) {
                    Text("Before it lands").daybreakSectionLabel()
                    checksCard
                }
                decisionFooter
            }
            .padding(.horizontal, 20)
            .padding(.top, 4)
            .padding(.bottom, 28)
        }
        .scrollIndicators(.hidden)
        .daybreakBackground()
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("\(batch.kind.displayName), side by side")
                .font(Daybreak.titleFont)
                .foregroundStyle(Daybreak.ink)
            HStack(spacing: 8) {
                Text(dayLabel)
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundStyle(Daybreak.mid)
                DaybreakChip(
                    batch.worstSeverity == .pass ? "new to Apple" : "! held back",
                    status: batch.worstSeverity == .pass ? .new : .warn
                )
            }
            Text("Fitbit Air's reading vs. what's already in Apple Health.")
                .font(Daybreak.bodyFont)
                .foregroundStyle(Daybreak.mid)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var dayLabel: String {
        if Calendar.current.isDateInToday(batch.day) { return "Today" }
        if Calendar.current.isDateInYesterday(batch.day) { return "Yesterday" }
        return batch.day.formatted(.dateTime.weekday(.wide).month(.abbreviated).day())
    }

    /// "heart rate", "SpO₂" — the kind as it reads mid-sentence.
    private var kindNoun: String {
        switch batch.kind {
        case .heartRate: "heart rate"
        case .restingHeartRate: "resting heart rate"
        case .heartRateVariability: "HRV"
        case .oxygenSaturation: "SpO₂"
        case .respiratoryRate: "respiratory rate"
        case .steps: "steps"
        case .distance: "distance"
        }
    }

    // MARK: - Chart

    /// How this kind reads best when compared by source.
    private enum ChartStyle {
        /// Continuous series → one line per source (HR, HRV).
        case lines
        /// Sparse readings → scatter by source (SpO2).
        case points
        /// Cumulative → hourly side-by-side bars; Apple's bars come from the
        /// deduplicated hourly statistics, never raw samples (steps, distance).
        case hourlyBars
        /// One value per day → Fitbit reference line over Apple's readings
        /// (resting HR, respiratory rate).
        case dailyValue
    }

    private var style: ChartStyle {
        switch batch.kind {
        case .heartRate, .heartRateVariability: return .lines
        case .oxygenSaturation: return .points
        case .steps, .distance: return .hourlyBars
        case .restingHeartRate, .respiratoryRate: return .dailyValue
        }
    }

    private var dayInterval: ClosedRange<Date> {
        batch.day...batch.day.addingTimeInterval(86_400)
    }

    /// Bars span the whole day; sampled kinds zoom to the data (overnight
    /// vitals would otherwise occupy a sliver of a 24 h axis).
    private var chartDomain: ClosedRange<Date> {
        guard style != .hourlyBars else { return dayInterval }
        let dates = batch.samples.flatMap { [$0.start, $0.end] }
            + batch.appleSamples.flatMap { [$0.start, $0.end] }
        guard let min = dates.min(), let max = dates.max(), max > min else { return dayInterval }
        let pad = Swift.max(900, (max.timeIntervalSince(min)) * 0.04)
        return min.addingTimeInterval(-pad)...max.addingTimeInterval(pad)
    }

    /// Hour stride that yields 4–5 x-axis labels for the visible span.
    private var hourStride: Int {
        let hours = chartDomain.upperBound.timeIntervalSince(chartDomain.lowerBound) / 3600
        switch hours {
        case ..<5: return 1
        case ..<10: return 2
        case ..<16: return 3
        default: return 6
        }
    }

    private var chartCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 16) {
                legendEntry(color: Daybreak.sunDeep, label: Self.googleSeries)
                legendEntry(
                    color: batch.appleSamples.isEmpty ? Daybreak.faint : Daybreak.plum,
                    label: Self.appleSeries
                )
                Spacer(minLength: 0)
            }
            styledChart
            if batch.appleSamples.isEmpty {
                Text("No Apple \(kindNoun) for this day — nothing to compare against.")
                    .font(Daybreak.captionFont)
                    .foregroundStyle(Daybreak.mid)
            }
        }
        .daybreakCard()
    }

    private func legendEntry(color: Color, label: String) -> some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(label)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(Daybreak.mid)
        }
    }

    private var styledChart: some View {
        comparisonChart
            .chartForegroundStyleScale([
                Self.googleSeries: Daybreak.sunDeep,
                Self.appleSeries: Daybreak.plum,
            ])
            .chartLegend(.hidden)
            .chartXScale(domain: chartDomain)
            .chartYScale(domain: .automatic(includesZero: batch.kind.isCumulative))
            .chartXAxis {
                AxisMarks(values: .stride(by: .hour, count: hourStride)) { _ in
                    AxisGridLine().foregroundStyle(Daybreak.line)
                    AxisValueLabel(format: .dateTime.hour())
                        .font(.system(size: 10, weight: .medium, design: .rounded))
                        .foregroundStyle(Daybreak.faint)
                }
            }
            .chartYAxis {
                AxisMarks { value in
                    AxisGridLine().foregroundStyle(Daybreak.line)
                    AxisValueLabel {
                        if let v = value.as(Double.self) {
                            Text(yAxisLabel(v))
                                .font(.system(size: 10, weight: .medium, design: .rounded))
                                .foregroundStyle(Daybreak.faint)
                        }
                    }
                }
            }
            .frame(height: 210)
    }

    /// Compact unit-less axis labels; SpO₂ fractions read as percent.
    private func yAxisLabel(_ value: Double) -> String {
        switch batch.kind {
        case .oxygenSaturation:
            return String(format: "%.0f%%", value * 100)
        case .distance where value >= 1000:
            return String(format: "%.1f km", value / 1000)
        default:
            return value == value.rounded()
                ? String(format: "%.0f", value)
                : String(format: "%.1f", value)
        }
    }

    @ViewBuilder
    private var comparisonChart: some View {
        switch style {
        case .lines:
            Chart {
                ForEach(batch.samples) { sample in
                    LineMark(
                        x: .value("Time", sample.start),
                        y: .value(batch.kind.displayName, sample.value),
                        series: .value("Source", Self.googleSeries)
                    )
                    .foregroundStyle(by: .value("Source", Self.googleSeries))
                    .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round))
                    .interpolationMethod(.monotone)
                }
                ForEach(batch.appleSamples) { sample in
                    LineMark(
                        x: .value("Time", sample.start),
                        y: .value(batch.kind.displayName, sample.value),
                        series: .value("Source", Self.appleSeries)
                    )
                    .foregroundStyle(by: .value("Source", Self.appleSeries))
                    .lineStyle(StrokeStyle(lineWidth: 1.6, lineCap: .round))
                    .interpolationMethod(.monotone)
                    .opacity(0.8)
                }
            }
        case .points:
            Chart {
                ForEach(batch.samples) { sample in
                    PointMark(
                        x: .value("Time", sample.start),
                        y: .value(batch.kind.displayName, sample.value)
                    )
                    .symbolSize(20)
                    .foregroundStyle(by: .value("Source", Self.googleSeries))
                }
                ForEach(batch.appleSamples) { sample in
                    PointMark(
                        x: .value("Time", sample.start),
                        y: .value(batch.kind.displayName, sample.value)
                    )
                    .symbolSize(36)
                    .foregroundStyle(by: .value("Source", Self.appleSeries))
                    .opacity(0.85)
                }
            }
        case .hourlyBars:
            let googleHourly = batch.samples.downsampled(bucket: 3600, kind: batch.kind, aggregation: .sum)
            Chart {
                ForEach(googleHourly) { bucket in
                    BarMark(
                        x: .value("Hour", bucket.start, unit: .hour),
                        y: .value(batch.kind.displayName, bucket.value)
                    )
                    .foregroundStyle(by: .value("Source", Self.googleSeries))
                    .position(by: .value("Source", Self.googleSeries))
                    .cornerRadius(2)
                }
                ForEach(batch.appleHourly) { bucket in
                    BarMark(
                        x: .value("Hour", bucket.start, unit: .hour),
                        y: .value(batch.kind.displayName, bucket.value)
                    )
                    .foregroundStyle(by: .value("Source", Self.appleSeries))
                    .position(by: .value("Source", Self.appleSeries))
                    .cornerRadius(2)
                }
            }
        case .dailyValue:
            Chart {
                if let google = batch.samples.first {
                    RuleMark(y: .value(batch.kind.displayName, google.value))
                        .foregroundStyle(by: .value("Source", Self.googleSeries))
                        .lineStyle(StrokeStyle(lineWidth: 2, dash: [6, 3]))
                        .annotation(position: .top, alignment: .leading) {
                            Text("Fitbit \(batch.kind.format(google.value))")
                                .font(.system(size: 11, weight: .bold, design: .rounded))
                                .foregroundStyle(Daybreak.sunDeep)
                        }
                }
                ForEach(batch.appleSamples) { sample in
                    PointMark(
                        x: .value("Time", sample.start),
                        y: .value(batch.kind.displayName, sample.value)
                    )
                    .symbolSize(28)
                    .foregroundStyle(by: .value("Source", Self.appleSeries))
                }
            }
        }
    }

    // MARK: - Numbers

    /// Google's headline: day total for cumulative kinds, average otherwise.
    private var googleValue: Double {
        let sum = batch.samples.reduce(0) { $0 + $1.value }
        return batch.kind.isCumulative ? sum : sum / Double(max(batch.samples.count, 1))
    }

    /// Apple's headline on the same basis. Cumulative kinds use the
    /// HealthKit-deduplicated day total — summing raw samples double-counts
    /// overlapping iPhone + Watch sources.
    private var appleValue: Double? {
        guard !batch.appleSamples.isEmpty else { return nil }
        if batch.kind.isCumulative { return batch.appleTotal }
        let sum = batch.appleSamples.reduce(0) { $0 + $1.value }
        return sum / Double(batch.appleSamples.count)
    }

    private var numbersCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 14) {
                statColumn(
                    source: Self.googleSeries,
                    value: batch.samples.isEmpty ? "—" : batch.kind.format(googleValue),
                    caption: googleCaption
                )
                Rectangle().fill(Daybreak.line).frame(width: 1)
                statColumn(
                    source: Self.appleSeries,
                    value: appleValue.map(batch.kind.format) ?? "—",
                    caption: appleCaption
                )
            }
            if let delta {
                Rectangle().fill(Daybreak.line).frame(height: 1)
                Text(delta.text)
                    .font(.system(size: 12.5, weight: .bold, design: .rounded))
                    .foregroundStyle(delta.tint)
            }
            if let caveat = batch.kind.appleComparisonCaveat {
                Text(caveat)
                    .font(Daybreak.captionFont)
                    .foregroundStyle(Daybreak.faint)
            }
        }
        .daybreakCard()
    }

    private func statColumn(source: String, value: String, caption: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(source).daybreakSectionLabel()
            Text(value)
                .font(Daybreak.numberFont(size: 26))
                .foregroundStyle(Daybreak.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(caption)
                .font(.system(size: 11.5, weight: .medium, design: .rounded))
                .foregroundStyle(Daybreak.mid)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var googleCaption: String {
        guard !batch.samples.isEmpty else { return "no data" }
        let count = "\(batch.samples.count) reading\(batch.samples.count == 1 ? "" : "s")"
        if batch.kind.isCumulative { return "total across \(count)" }
        if batch.samples.count == 1 { return "single daily reading" }
        let values = batch.samples.map(\.value)
        return "average of \(count) · \(yAxisLabel(values.min()!))–\(batch.kind.format(values.max()!))"
    }

    private var appleCaption: String {
        guard !batch.appleSamples.isEmpty else { return "no data for this day" }
        if batch.kind.isCumulative { return "day total, deduplicated" }
        let count = batch.appleSamples.count
        return "average of \(count) sample\(count == 1 ? "" : "s") already in Health"
    }

    private struct Delta {
        let text: String
        let tint: Color
    }

    /// Plain-language read of how far apart the two sources sit.
    private var delta: Delta? {
        guard let apple = appleValue, !batch.samples.isEmpty else { return nil }
        let diff = googleValue - apple
        let magnitude = batch.kind.format(abs(diff))
        if batch.kind.appleComparisonCaveat != nil {
            return Delta(text: "\(magnitude) apart — different statistics, an offset is expected", tint: Daybreak.mid)
        }
        let pct = abs(diff) / max(abs(apple), .ulpOfOne)
        if pct < 0.005 || magnitude == batch.kind.format(0) {
            return Delta(text: "Practically identical — adds up cleanly", tint: Daybreak.ok)
        }
        let direction = diff > 0 ? "higher on Fitbit" : "lower on Fitbit"
        switch pct {
        case ..<0.05:
            return Delta(text: "\(magnitude) \(direction) — adds up cleanly", tint: Daybreak.ok)
        case ..<0.15:
            return Delta(text: "\(magnitude) \(direction) — close enough to tell the same story", tint: Daybreak.ok)
        default:
            return Delta(text: "\(magnitude) \(direction) — worth a look", tint: Daybreak.warn)
        }
    }

    // MARK: - Checks

    private var checksCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            ForEach(batch.checks) { CheckCard(result: $0) }
        }
        .daybreakCard(padding: 18)
    }

    // MARK: - Decision

    private var decisionFooter: some View {
        VStack(spacing: 10) {
            Button("Looks right — add to Apple Health") {
                guard !isImporting else { return }
                isImporting = true
                Task {
                    await model.syncEngine.importMetricBatch(batch.id)
                    dismiss()
                }
            }
            .buttonStyle(.daybreakPrimary)
            .disabled(isImporting)

            Button("Skip this day") {
                model.syncEngine.tossMetricBatch(batch.id)
                dismiss()
            }
            .buttonStyle(.daybreakGhost)
            .disabled(isImporting)

            Text(microcopy)
                .font(Daybreak.captionFont)
                .foregroundStyle(Daybreak.mid)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .padding(.top, 2)
        }
        .padding(.top, 4)
    }

    private var microcopy: String {
        let count = batch.samples.count
        return "Adds \(count) \(sampleNoun(count: count)) to Apple Health, marked as Fitbit Air data. Re-syncs never duplicate. Skipping writes nothing."
    }

    private func sampleNoun(count: Int) -> String {
        let singular: String
        switch batch.kind {
        case .heartRate: singular = "heart-rate reading"
        case .restingHeartRate: singular = "resting heart-rate reading"
        case .heartRateVariability: singular = "HRV reading"
        case .oxygenSaturation: singular = "SpO₂ reading"
        case .respiratoryRate: singular = "respiratory-rate reading"
        case .steps: singular = "hourly step total"
        case .distance: singular = "distance reading"
        }
        return count == 1 ? singular : singular + "s"
    }
}
