import SwiftUI
import Charts

/// Recovery: Fitbit's HRV against what the Apple Watch can be made to say,
/// over a stretch of nights, restricted to the stages that are supposed to
/// carry the signal.
///
/// Three questions, in order down the screen:
///
/// 1. **Do the two devices rank nights the same way?** With the ceiling that
///    their own measurement noise puts on the answer, because a correlation of
///    0.73 against a ceiling of 0.73 is not mediocre agreement.
/// 2. **What does the restriction actually keep?** The night chart draws the
///    discarded samples faded rather than dropping them, so "core + deep" reads
///    as a quantity of data and not just a label.
/// 3. **Which staging?** Airlift lands Fitbit's hypnogram beside Apple's, so
///    Apple's own samples can be labelled with Fitbit's scoring — the one
///    comparison this app is uniquely placed to make.
struct RecoveryView: View {
    @Environment(AppModel.self) private var model

    /// Opens on the most recent night; the clamp wherever it is read turns
    /// `Int.max` into "last".
    @State private var nightIndex = Int.max
    /// Which series the scatter and headline follow.
    @State private var focus: RecoverySeries = .heartRate

    @ScaledMetric(relativeTo: .title) private var statValueSize: CGFloat = 26

    private var engine: RecoveryEngine { model.recovery }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header
                controlsCard
                switch engine.state {
                case .idle:
                    idleCard
                case .loading(let step):
                    loadingCard(step)
                case .failed(let message):
                    messageCard(
                        title: "Could not read Health",
                        body: message,
                        status: .fail
                    )
                case .ready(let report):
                    reportBody(report)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, 40)
        }
        .scrollIndicators(.hidden)
        .daybreakBackground()
        .navigationTitle("Recovery")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task { await engine.load() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .foregroundStyle(Daybreak.mid)
                }
                .disabled(engine.state.isLoading)
                .accessibilityLabel("Read the nights again")
            }
        }
        // Read once on first open; the toggles rebuild from what is already in
        // memory, so nothing below this re-queries Health.
        .task {
            if case .idle = engine.state { await engine.load() }
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Two devices, one night")
                .font(Daybreak.titleFont)
                .foregroundStyle(Daybreak.ink)
            Text("Fitbit's HRV against the Apple Watch's, \(nightSpan) — and what happens when only the stages that should carry recovery are counted.")
                .font(Daybreak.bodyFont)
                .foregroundStyle(Daybreak.mid)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The nights actually found, not the number asked for — a stretch with
    /// gaps in it would otherwise be described as denser than it is.
    private var nightSpan: String {
        guard let found = engine.state.report?.nights.count, found > 0 else {
            return "over the last \(engine.nightCount) nights"
        }
        return "across \(found) night\(found == 1 ? "" : "s") in the last \(engine.nightCount)"
    }

    // MARK: - Controls

    private var controlsCard: some View {
        @Bindable var engine = engine
        return VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Stages counted").daybreakSectionLabel()
                Picker("Stages counted", selection: $engine.selection) {
                    ForEach(StageSelection.allCases) { selection in
                        Text(selection.displayName).tag(selection)
                    }
                }
                .pickerStyle(.segmented)
                Text(engine.selection.detail)
                    .font(Daybreak.captionFont)
                    .foregroundStyle(Daybreak.mid)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Scored by").daybreakSectionLabel()
                Picker("Scored by", selection: $engine.staging) {
                    ForEach(StagingSource.allCases) { source in
                        Text(source.displayName).tag(source)
                    }
                }
                .pickerStyle(.segmented)
                Text(engine.staging.detail)
                    .font(Daybreak.captionFont)
                    .foregroundStyle(Daybreak.mid)
            }
        }
        .daybreakCard()
    }

    // MARK: - States

    private var idleCard: some View {
        messageCard(
            title: "Nothing read yet",
            body: "Pull a stretch of nights out of Health to compare.",
            status: .neutral
        )
    }

    private func loadingCard(_ step: String) -> some View {
        HStack(spacing: 12) {
            ProgressView()
            Text(step)
                .font(Daybreak.bodyFont)
                .foregroundStyle(Daybreak.mid)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .daybreakCard()
    }

    private func messageCard(title: String, body: String, status: DaybreakChip.Status) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(.headline, design: .rounded, weight: .bold))
                .foregroundStyle(Daybreak.ink)
            Text(body)
                .font(Daybreak.bodyFont)
                .foregroundStyle(Daybreak.mid)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .daybreakCard()
    }

    // MARK: - Report

    @ViewBuilder
    private func reportBody(_ report: RecoveryReport) -> some View {
        if report.comparisons.isEmpty {
            messageCard(
                title: "No paired nights",
                body: "Every comparison here is anchored to Fitbit's HRV, so it needs nights where Airlift imported Fitbit HRV *and* the Watch was worn. Sync a few nights and come back.",
                status: .warn
            )
        } else {
            headlineCard(report)
            Text("How they agree").daybreakSectionLabel()
            comparisonCard(report)
            if let chart = currentChart(report) {
                Text("One night").daybreakSectionLabel()
                nightCard(report, chart: chart)
            }
            Text("Night against night").daybreakSectionLabel()
            scatterCard(report)
            Text("How much is signal").daybreakSectionLabel()
            reliabilityCard(report)
            beatSeriesCard(report)
            limitationsCard(report)
        }
    }

    // MARK: - Headline

    /// The finding, in a sentence: which Apple-side series tracks Fitbit best,
    /// and whether it has run out of room to do better.
    private func headlineCard(_ report: RecoveryReport) -> some View {
        let best = report.comparisons
            .filter { $0.summary.spearman != nil }
            .max { ($0.summary.spearman ?? 0) < ($1.summary.spearman ?? 0) }
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(Self.format(best?.summary.spearman))
                    .font(Daybreak.numberFont(size: statValueSize * 1.5))
                    .foregroundStyle(Daybreak.sunDeep)
                Text("ρ")
                    .font(.system(.title3, design: .rounded, weight: .bold))
                    .foregroundStyle(Daybreak.mid)
                Spacer(minLength: 0)
                if best?.isAtCeiling == true {
                    DaybreakChip("at the ceiling", status: .ok)
                }
            }
            Text(headlineSentence(report, best: best))
                .font(Daybreak.bodyFont)
                .foregroundStyle(Daybreak.mid)
            if let n = best?.summary.n {
                Text("\(n) paired nights\(best?.summary.isUnderpowered == true ? " — thin, so read the interval, not the point" : "").")
                    .font(Daybreak.captionFont)
                    .foregroundStyle(Daybreak.faint)
            }
        }
        .daybreakCard()
    }

    private func headlineSentence(_ report: RecoveryReport, best: RecoveryComparison?) -> String {
        guard let best else { return "Not enough paired nights to say anything yet." }
        let name = best.series.displayName
        let zone = report.selection == .allSleep
            ? "across the whole night"
            : "over \(report.selection.displayName.lowercased())"
        if best.isAtCeiling {
            return "\(name) tracks Fitbit as closely as two instruments this noisy could, \(zone). The remaining gap is measurement error in both, not disagreement about the night."
        }
        if let ceiling = best.ceiling {
            return "\(name) is the closest match to Fitbit \(zone), against a ceiling of \(Self.format(ceiling)) set by how noisy the two series are."
        }
        return "\(name) is the closest match to Fitbit \(zone)."
    }

    // MARK: - Comparison table

    private func comparisonCard(_ report: RecoveryReport) -> some View {
        VStack(spacing: 0) {
            comparisonHeaderRow
            ForEach(report.comparisons) { comparison in
                Divider().overlay(Daybreak.line).padding(.vertical, 9)
                Button {
                    focus = comparison.series
                } label: {
                    comparisonRow(comparison)
                }
                .buttonStyle(.plain)
            }
            Divider().overlay(Daybreak.line).padding(.vertical, 9)
            Text("Level is how alike the nights rank. Change is how alike last night's move was — the harder test, and the one a recovery number is actually read for. Ceiling is the best either could have scored given its own noise.")
                .font(Daybreak.captionFont)
                .foregroundStyle(Daybreak.faint)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .daybreakCard(padding: 16)
    }

    private var comparisonHeaderRow: some View {
        HStack(spacing: 8) {
            Text("vs Fitbit RMSSD")
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("Level").frame(width: 48, alignment: .trailing)
            Text("Change").frame(width: 52, alignment: .trailing)
            Text("Ceiling").frame(width: 52, alignment: .trailing)
        }
        .font(Daybreak.sectionLabelFont)
        .foregroundStyle(Daybreak.faint)
    }

    private func comparisonRow(_ comparison: RecoveryComparison) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(focus == comparison.series ? Daybreak.sunDeep : Color.clear)
                        .frame(width: 6, height: 6)
                    Text(comparison.series.displayName)
                        .font(.system(.footnote, design: .rounded, weight: .semibold))
                        .foregroundStyle(Daybreak.ink)
                        .lineLimit(2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Text(Self.format(comparison.summary.spearman))
                    .frame(width: 48, alignment: .trailing)
                Text(Self.format(comparison.summary.changeSpearman))
                    .frame(width: 52, alignment: .trailing)
                Text(Self.format(comparison.ceiling))
                    .frame(width: 52, alignment: .trailing)
            }
            .font(.system(.footnote, design: .rounded, weight: .semibold))
            .foregroundStyle(Daybreak.ink)

            if let low = comparison.summary.spearmanCILow, let high = comparison.summary.spearmanCIHigh {
                Text("95% interval \(Self.format(low)) to \(Self.format(high)) · n = \(comparison.summary.n)")
                    .font(Daybreak.captionFont)
                    .foregroundStyle(Daybreak.faint)
            }
            if comparison.showsBias,
               let bias = comparison.summary.ratioBiasPct,
               let low = comparison.summary.ratioLoALowPct,
               let high = comparison.summary.ratioLoAHighPct {
                Text("Reads \(Self.signedPercent(bias)) vs Fitbit, 95% of nights within \(Self.signedPercent(low)) to \(Self.signedPercent(high)).")
                    .font(Daybreak.captionFont)
                    .foregroundStyle(Daybreak.mid)
            }
            if let caveat = comparison.caveat {
                Text(caveat)
                    .font(Daybreak.captionFont)
                    .foregroundStyle(Daybreak.faint)
            }
        }
        .contentShape(Rectangle())
    }

    // MARK: - One night

    private func currentChart(_ report: RecoveryReport) -> NightChart? {
        guard !report.charts.isEmpty else { return nil }
        let index = min(max(nightIndex, 0), report.charts.count - 1)
        return report.charts[index]
    }

    private func nightCard(_ report: RecoveryReport, chart: NightChart) -> some View {
        let hrv = chart.kept(chart.apple)
        let hr = chart.kept(chart.heartRate)
        return VStack(alignment: .leading, spacing: 12) {
            nightStepper(report, chart: chart)
            stageStripChart(chart)
            hrvChart(chart)
            heartRateChart(chart)
            nightLegend(chart)
            Text(report.selection == .allSleep
                 ? (chart.appleKind == .native
                    ? "\(hrv.total) Watch RMSSD readings and \(hr.total) heart-rate samples across the night, against \(chart.fitbit.count) from Fitbit."
                    : "\(hrv.total) Apple HRV readings and \(hr.total) heart-rate samples across the night — a 17-to-1 gap that no amount of processing closes.")
                 : "\(report.selection.displayName) keeps \(hrv.kept) of \(hrv.total) Apple HRV readings and \(hr.kept) of \(hr.total) heart-rate samples. Faded marks are the ones it dropped.")
                .font(Daybreak.captionFont)
                .foregroundStyle(Daybreak.mid)
        }
        .daybreakCard(padding: 18)
    }

    private func nightStepper(_ report: RecoveryReport, chart: NightChart) -> some View {
        HStack {
            Button {
                nightIndex = max(0, min(nightIndex, report.charts.count - 1) - 1)
            } label: {
                Image(systemName: "chevron.left")
            }
            .disabled(nightIndex <= 0)
            Spacer(minLength: 0)
            VStack(spacing: 1) {
                Text(chart.night.formatted(.dateTime.weekday(.wide).month(.abbreviated).day()))
                    .font(.system(.subheadline, design: .rounded, weight: .bold))
                    .foregroundStyle(Daybreak.ink)
                Text("\(min(nightIndex, report.charts.count - 1) + 1) of \(report.charts.count)")
                    .font(Daybreak.captionFont)
                    .foregroundStyle(Daybreak.faint)
            }
            Spacer(minLength: 0)
            Button {
                nightIndex = min(report.charts.count - 1, min(nightIndex, report.charts.count - 1) + 1)
            } label: {
                Image(systemName: "chevron.right")
            }
            .disabled(min(nightIndex, report.charts.count - 1) >= report.charts.count - 1)
        }
        .font(.system(.body, weight: .semibold))
        .foregroundStyle(Daybreak.plum)
    }

    /// The hypnogram as a colored strip. Runs outside the selection drop to a
    /// hairline so the target zone reads as a shape, not a legend entry.
    private func stageStripChart(_ chart: NightChart) -> some View {
        Chart(chart.bands) { band in
            RectangleMark(
                xStart: .value("Start", band.start),
                xEnd: .value("End", band.end),
                yStart: .value("Lane", 0),
                yEnd: .value("Lane", 1)
            )
            .foregroundStyle(Self.color(band.stage).opacity(band.inZone ? 1 : 0.18))
        }
        .chartXScale(domain: chart.domain)
        .chartYScale(domain: 0...1)
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .frame(height: 22)
        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
    }

    private func hrvChart(_ chart: NightChart) -> some View {
        Chart {
            ForEach(chart.fitbit) { point in
                LineMark(
                    x: .value("Time", point.date),
                    y: .value("HRV", point.value),
                    series: .value("Source", "Fitbit")
                )
                .foregroundStyle(Daybreak.sunDeep)
                .lineStyle(StrokeStyle(lineWidth: 1.8, lineCap: .round))
                .interpolationMethod(.monotone)
                .opacity(point.inZone ? 1 : 0.25)
            }
            // The Watch's own RMSSD is as dense as Fitbit's and is drawn the
            // same way; a handful of spot checks is not a line.
            if chart.appleKind == .native {
                ForEach(chart.apple) { point in
                    LineMark(
                        x: .value("Time", point.date),
                        y: .value("HRV", point.value),
                        series: .value("Source", "Watch")
                    )
                    .foregroundStyle(Daybreak.plum)
                    .lineStyle(StrokeStyle(lineWidth: 1.8, lineCap: .round))
                    .interpolationMethod(.monotone)
                    .opacity(point.inZone ? 1 : 0.25)
                }
            } else {
                ForEach(chart.apple) { point in
                    PointMark(
                        x: .value("Time", point.date),
                        y: .value("HRV", point.value)
                    )
                    .symbolSize(70)
                    .foregroundStyle(Daybreak.plum)
                    .opacity(point.inZone ? 1 : 0.22)
                }
            }
        }
        .chartXScale(domain: chart.domain)
        .chartYScale(domain: .automatic(includesZero: false))
        .chartXAxis(.hidden)
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { value in
                AxisGridLine().foregroundStyle(Daybreak.line)
                AxisValueLabel {
                    if let ms = value.as(Double.self) {
                        Text("\(Int(ms))")
                            .font(.system(.caption2, design: .rounded, weight: .medium))
                            .foregroundStyle(Daybreak.faint)
                    }
                }
            }
        }
        .frame(height: 140)
    }

    private func heartRateChart(_ chart: NightChart) -> some View {
        Chart {
            ForEach(chart.heartRate) { point in
                LineMark(
                    x: .value("Time", point.date),
                    y: .value("BPM", point.value)
                )
                .foregroundStyle(Daybreak.ink.opacity(0.35))
                .lineStyle(StrokeStyle(lineWidth: 1.4, lineCap: .round))
                .interpolationMethod(.monotone)
            }
            ForEach(chart.heartRate.filter(\.inZone)) { point in
                PointMark(
                    x: .value("Time", point.date),
                    y: .value("BPM", point.value)
                )
                .symbolSize(9)
                .foregroundStyle(Daybreak.stageDeep)
            }
        }
        .chartXScale(domain: chart.domain)
        .chartYScale(domain: .automatic(includesZero: false))
        .chartXAxis {
            AxisMarks(values: clockAlignedTicks(in: chart.domain, everyHours: 2)) { _ in
                AxisGridLine().foregroundStyle(Daybreak.line)
                AxisValueLabel(format: .dateTime.hour())
                    .font(.system(.caption2, design: .rounded, weight: .medium))
                    .foregroundStyle(Daybreak.faint)
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { _ in
                AxisGridLine().foregroundStyle(Daybreak.line)
                AxisValueLabel()
                    .font(.system(.caption2, design: .rounded, weight: .medium))
                    .foregroundStyle(Daybreak.faint)
            }
        }
        .frame(height: 84)
    }

    private func nightLegend(_ chart: NightChart) -> some View {
        HStack(spacing: 14) {
            legendEntry(color: Daybreak.sunDeep, label: "Fitbit RMSSD")
            legendEntry(
                color: Daybreak.plum,
                label: chart.appleKind.label
            )
            legendEntry(color: Daybreak.stageDeep, label: "Apple HR")
            Spacer(minLength: 0)
        }
    }

    private func legendEntry(color: Color, label: String) -> some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(label)
                .font(.system(.caption2, design: .rounded, weight: .semibold))
                .foregroundStyle(Daybreak.mid)
        }
    }

    // MARK: - Scatter

    /// Every paired night as a point: Fitbit across, the focused Apple series
    /// up. Scatter rather than two time series because the question is whether
    /// the nights line up, not what happened on any one of them.
    private func scatterCard(_ report: RecoveryReport) -> some View {
        let points = scatterPoints(report)
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(focus.displayName)
                    .font(.system(.footnote, design: .rounded, weight: .bold))
                    .foregroundStyle(Daybreak.ink)
                Spacer(minLength: 0)
                Text("tap a row above to switch")
                    .font(Daybreak.captionFont)
                    .foregroundStyle(Daybreak.faint)
            }
            if points.count < 3 {
                Text("Too few paired nights for this series to plot.")
                    .font(Daybreak.captionFont)
                    .foregroundStyle(Daybreak.mid)
            } else {
                Chart(points) { point in
                    PointMark(
                        x: .value("Fitbit RMSSD (ms)", point.reference),
                        y: .value(focus.shortName, point.target)
                    )
                    .symbolSize(46)
                    .foregroundStyle(Daybreak.plum.opacity(0.75))
                }
                .chartXScale(domain: .automatic(includesZero: false))
                .chartYScale(domain: .automatic(includesZero: false))
                .chartXAxis {
                    AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                        AxisGridLine().foregroundStyle(Daybreak.line)
                        AxisValueLabel()
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
                .frame(height: 200)
                Text("Fitbit RMSSD (ms) across · \(focus.displayName)\(focus.unit.map { " (\($0))" } ?? "") up. \(focus == .heartRate ? "Heart rate is plotted as measured, so a good match slopes down." : "A good match slopes up.")")
                    .font(Daybreak.captionFont)
                    .foregroundStyle(Daybreak.faint)
            }
        }
        .daybreakCard(padding: 18)
    }

    private struct ScatterPoint: Identifiable {
        let id: Date
        let reference: Double
        let target: Double
    }

    private func scatterPoints(_ report: RecoveryReport) -> [ScatterPoint] {
        report.nights.compactMap { night in
            guard let reference = night.fitbitRMSSD?.value else { return nil }
            let target: Double? = focus == .appleCombined
                ? report.combinedIndex[night.night]
                // Drawn the way it was measured — bpm, not the inverted form
                // the statistics use — so the axis is a number you recognise.
                : focus.display(in: night)?.value
            guard let target else { return nil }
            return ScatterPoint(id: night.night, reference: reference, target: target)
        }
    }

    // MARK: - Reliability

    private func reliabilityCard(_ report: RecoveryReport) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("Series")
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text("Signal").frame(width: 52, alignment: .trailing)
                Text("Samples").frame(width: 62, alignment: .trailing)
            }
            .font(Daybreak.sectionLabelFont)
            .foregroundStyle(Daybreak.faint)
            ForEach(report.reliabilities.filter { $0.nightsWithData > 0 }) { entry in
                Divider().overlay(Daybreak.line).padding(.vertical, 9)
                HStack(spacing: 8) {
                    Text(entry.series.displayName)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .lineLimit(2)
                    Text(Self.format(entry.reliability))
                        .frame(width: 52, alignment: .trailing)
                    Text(entry.medianSamplesPerNight.map { String(format: "%.0f", $0) } ?? "—")
                        .frame(width: 62, alignment: .trailing)
                }
                .font(.system(.footnote, design: .rounded, weight: .semibold))
                .foregroundStyle(Daybreak.ink)
            }
            Divider().overlay(Daybreak.line).padding(.vertical, 9)
            Text("Signal is split-half reliability: each night's samples split into two halves, and the halves compared across nights. Near 1, the nightly moves are real. Near 0, the series is mostly the device arguing with itself — and no smoothing recovers a signal that was never sampled. Samples is the median readings a night.")
                .font(Daybreak.captionFont)
                .foregroundStyle(Daybreak.faint)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .daybreakCard(padding: 16)
    }

    // MARK: - Beat series

    /// The one thing that could not be known before running on a real device:
    /// whether the Watch hands over the beat-to-beat series its HRV is made of.
    @ViewBuilder
    private func beatSeriesCard(_ report: RecoveryReport) -> some View {
        if let probe = report.probe {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Text("Beat-to-beat data")
                        .font(.system(.footnote, design: .rounded, weight: .bold))
                        .foregroundStyle(Daybreak.ink)
                    Spacer(minLength: 0)
                    DaybreakChip(
                        probe.seriesCount > 0 ? "available" : "not available",
                        status: probe.seriesCount > 0 ? .ok : .warn
                    )
                }
                Text(probe.summary)
                    .font(Daybreak.captionFont)
                    .foregroundStyle(Daybreak.mid)
                Text(probe.seriesCount > 0
                     ? "Apple HRV is recomputed here as RMSSD with a visible 20% artifact filter, which is what makes it the same statistic Fitbit reports instead of Apple's SDNN."
                     : "Without the raw beats, Apple's HRV can only be compared as the SDNN it publishes — a different statistic from Fitbit's RMSSD, so expect the values to differ even when the nights agree.")
                    .font(Daybreak.captionFont)
                    .foregroundStyle(Daybreak.faint)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .daybreakCard(padding: 16)
        }
    }

    // MARK: - Limitations

    private func limitationsCard(_ report: RecoveryReport) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Read this with")
                .font(.system(.footnote, design: .rounded, weight: .bold))
                .foregroundStyle(Daybreak.ink)
            ForEach(Self.limitations(report), id: \.self) { line in
                HStack(alignment: .top, spacing: 7) {
                    Circle()
                        .fill(Daybreak.faint)
                        .frame(width: 4, height: 4)
                        .padding(.top, 6)
                    Text(line)
                        .font(Daybreak.captionFont)
                        .foregroundStyle(Daybreak.mid)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .daybreakCard(padding: 16)
    }

    private static func limitations(_ report: RecoveryReport) -> [String] {
        var lines = [
            "One person, one pair of devices. Nothing here generalises past this wrist.",
            "Fitbit is the reference, not the truth. It is the denser measurement, which is a different claim.",
            "The first 30 minutes of sleep are dropped from every night — heart rate is still falling steeply through onset.",
        ]
        if report.selection == .deepOnly {
            lines.append("Deep-only usually leaves too few Apple readings a night to support any of these numbers. The counts above are the finding.")
        }
        if report.staging == .bothAgree {
            lines.append("Agreement-only staging keeps the minutes both devices scored the same way, which is the cleanest label and the smallest sample.")
        }
        if report.comparisons.contains(where: { $0.summary.isUnderpowered }) {
            lines.append("Under about 30 paired nights the 95% intervals are wide enough to cover most of the range. Wait for more nights before ranking anything.")
        }
        lines.append("Restricting to a stage cuts sample count as well as noise. When a restriction looks worse, check whether it simply left less data.")
        return lines
    }

    // MARK: - Formatting

    private static func format(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "—" }
        return String(format: "%.2f", value)
    }

    private static func signedPercent(_ value: Double) -> String {
        String(format: "%@%.0f%%", value >= 0 ? "+" : "", value)
    }

    private static func color(_ stage: SleepAgreement.Stage) -> Color {
        switch stage {
        case .awake: Daybreak.stageAwake
        case .rem: Daybreak.stageREM
        case .core: Daybreak.stageCore
        case .deep: Daybreak.stageDeep
        case .asleep: Daybreak.stageCore
        }
    }
}

/// Navigation token for the Recovery screen.
struct RecoveryRoute: Hashable {}
