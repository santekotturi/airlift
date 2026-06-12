import SwiftUI
import Charts

/// Validation view for one day of one quantity metric: Google readings charted
/// against Apple's for the same day, summary stats, sanity checks, and the
/// import-or-toss decision.
struct MetricCompareView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    let batch: StagedMetricBatch

    var body: some View {
        List {
            chartSection
            statsSection
            checksSection
            decisionSection
        }
        .navigationTitle("\(batch.kind.displayName) — \(batch.day.formatted(date: .abbreviated, time: .omitted))")
        .navigationBarTitleDisplayMode(.inline)
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

    private var chartSection: some View {
        Section("Google vs Apple") {
            if batch.appleSamples.isEmpty {
                Text("No Apple \(batch.kind.displayName) data for this day.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            comparisonChart
                .chartForegroundStyleScale(["Fitbit Air": Color.blue, "Apple": Color.red])
                .chartXScale(domain: dayInterval)
                .chartYScale(domain: .automatic(includesZero: batch.kind.isCumulative))
                .chartLegend(position: .bottom, spacing: 8)
                .frame(height: 200)
                .padding(.vertical, 4)
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
                        series: .value("Source", "Fitbit Air")
                    )
                    .foregroundStyle(by: .value("Source", "Fitbit Air"))
                    .lineStyle(StrokeStyle(lineWidth: 1.2))
                    .interpolationMethod(.monotone)
                }
                ForEach(batch.appleSamples) { sample in
                    LineMark(
                        x: .value("Time", sample.start),
                        y: .value(batch.kind.displayName, sample.value),
                        series: .value("Source", "Apple")
                    )
                    .foregroundStyle(by: .value("Source", "Apple"))
                    .lineStyle(StrokeStyle(lineWidth: 1.2))
                    .interpolationMethod(.monotone)
                    .opacity(0.75)
                }
            }
        case .points:
            Chart {
                ForEach(batch.samples) { sample in
                    PointMark(
                        x: .value("Time", sample.start),
                        y: .value(batch.kind.displayName, sample.value)
                    )
                    .symbolSize(14)
                    .foregroundStyle(by: .value("Source", "Fitbit Air"))
                }
                ForEach(batch.appleSamples) { sample in
                    PointMark(
                        x: .value("Time", sample.start),
                        y: .value(batch.kind.displayName, sample.value)
                    )
                    .symbolSize(28)
                    .foregroundStyle(by: .value("Source", "Apple"))
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
                    .foregroundStyle(by: .value("Source", "Fitbit Air"))
                    .position(by: .value("Source", "Fitbit Air"))
                }
                ForEach(batch.appleHourly) { bucket in
                    BarMark(
                        x: .value("Hour", bucket.start, unit: .hour),
                        y: .value(batch.kind.displayName, bucket.value)
                    )
                    .foregroundStyle(by: .value("Source", "Apple"))
                    .position(by: .value("Source", "Apple"))
                }
            }
        case .dailyValue:
            Chart {
                if let google = batch.samples.first {
                    RuleMark(y: .value(batch.kind.displayName, google.value))
                        .foregroundStyle(by: .value("Source", "Fitbit Air"))
                        .lineStyle(StrokeStyle(lineWidth: 2, dash: [6, 3]))
                        .annotation(position: .top, alignment: .leading) {
                            Text("Fitbit \(batch.kind.format(google.value))")
                                .font(.caption2)
                                .foregroundStyle(.blue)
                        }
                }
                ForEach(batch.appleSamples) { sample in
                    PointMark(
                        x: .value("Time", sample.start),
                        y: .value(batch.kind.displayName, sample.value)
                    )
                    .symbolSize(20)
                    .foregroundStyle(by: .value("Source", "Apple"))
                }
            }
        }
    }

    // MARK: - Stats

    private func summary(_ values: [Double]) -> String {
        guard !values.isEmpty else { return "—" }
        if batch.kind.isCumulative {
            return "total \(batch.kind.format(values.reduce(0, +)))"
        }
        let avg = values.reduce(0, +) / Double(values.count)
        return "min \(batch.kind.format(values.min()!)) · avg \(batch.kind.format(avg)) · max \(batch.kind.format(values.max()!))"
    }

    /// Apple's line uses the HealthKit-deduplicated day total for cumulative
    /// kinds — summing the raw samples double-counts iPhone + Watch overlap.
    private var appleSummary: String {
        if batch.appleSamples.isEmpty { return "no data" }
        if batch.kind.isCumulative, let total = batch.appleTotal {
            return "\(batch.appleSamples.count) samples · total \(batch.kind.format(total)) (deduplicated)"
        }
        return "\(batch.appleSamples.count) samples · \(summary(batch.appleSamples.map(\.value)))"
    }

    private var statsSection: some View {
        Section("Numbers") {
            LabeledContent("Google") {
                Text("\(batch.samples.count) samples · \(summary(batch.samples.map(\.value)))")
                    .multilineTextAlignment(.trailing)
            }
            LabeledContent("Apple") {
                Text(appleSummary)
                    .multilineTextAlignment(.trailing)
            }
            if batch.kind == .heartRateVariability {
                Text("Note: Fitbit HRV is RMSSD; Apple's is SDNN. They correlate but aren't directly comparable — expect a systematic offset.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Checks

    private var checksSection: some View {
        Section("Sanity checks") {
            ForEach(batch.checks) { check in
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
                    await model.syncEngine.importMetricBatch(batch.id)
                    dismiss()
                }
            } label: {
                Label("Import \(batch.samples.count) samples", systemImage: "square.and.arrow.down.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)

            Button(role: .destructive) {
                model.syncEngine.tossMetricBatch(batch.id)
                dismiss()
            } label: {
                Label("Toss (never import)", systemImage: "trash")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
        } footer: {
            Text("Import writes \(batch.kind.displayName) samples to Apple Health attributed to the Fitbit Air. Toss permanently hides this day's batch.")
        }
    }
}
