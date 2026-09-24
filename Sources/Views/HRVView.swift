import SwiftUI
import Charts

/// HRV only: the Watch's own RMSSD where it writes one, Apple's published SDNN,
/// the RMSSD recomputed here from Apple's own beats, and Fitbit's RMSSD — on one
/// axis, region by region.
///
/// All are milliseconds, which is what makes the overlay legitimate. Not all
/// are the same statistic, so the screen keeps saying which is which rather
/// than letting the shared axis imply they are interchangeable.
///
/// The unit of comparison is the *window*, not the night. On older watches
/// that is a ~60 s spot check every two hours; on watchOS 27 Ultra 4 hardware
/// it is one of the Watch's ~5-minute RMSSD readings. Either way each is matched
/// to whatever Fitbit was reporting at the same moment. A nightly average would
/// hide the thing worth seeing — that the two can agree at 2am and disagree at
/// 5am — because averaging is the operation that removes it.
struct HRVView: View {
    @Environment(AppModel.self) private var model

    /// Opens on the most recent night; the clamp wherever it is read turns
    /// `Int.max` into "last".
    @State private var nightIndex = Int.max
    @State private var visible: Set<HRVSource> = Set(HRVSource.allCases)

    @ScaledMetric(relativeTo: .title) private var statValueSize: CGFloat = 26

    private var engine: RecoveryEngine { model.recovery }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header
                stagingCard
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
                case .ready(let report):
                    body(for: report.hrv, staging: report.staging)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, 40)
        }
        .scrollIndicators(.hidden)
        .daybreakBackground()
        .navigationTitle("HRV")
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
            Text("HRV, side by side")
                .font(Daybreak.titleFont)
                .foregroundStyle(Daybreak.ink)
            Text("What the Watch publishes, what its raw beats actually say, and what Fitbit measured at the same moment.")
                .font(Daybreak.bodyFont)
                .foregroundStyle(Daybreak.mid)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var stagingCard: some View {
        @Bindable var engine = engine
        return VStack(alignment: .leading, spacing: 6) {
            Text("Stages scored by").daybreakSectionLabel()
            Picker("Stages scored by", selection: $engine.staging) {
                ForEach(StagingSource.allCases) { source in
                    Text(source.displayName).tag(source)
                }
            }
            .pickerStyle(.segmented)
            Text("Only labels which zone each reading fell in — every reading is compared either way.")
                .font(Daybreak.captionFont)
                .foregroundStyle(Daybreak.mid)
        }
        .daybreakCard()
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

    // MARK: - Report

    /// The night-by-night view shows as soon as there is any Apple reading, so
    /// a new watch can be looked at before there is a Fitbit night to compare
    /// it with; only the statistics wait for matched readings.
    @ViewBuilder
    private func body(for report: HRVReport, staging: StagingSource) -> some View {
        let isMatched = report.completeWindowCount >= 3
        if report.windows.isEmpty {
            card(
                "No Apple HRV readings",
                "No beat-to-beat series and no Watch RMSSD came back for these nights, so there is nothing to compare. Apple's published SDNN is all that exists."
            )
        } else {
            if isMatched {
                verdictCard(report)
            } else {
                card("Not enough matched readings", unmatchedMessage(report))
            }
            Text("Reading by reading").daybreakSectionLabel()
            nightCard(report)
            if isMatched {
                Text("By zone").daybreakSectionLabel()
                zoneCard(report)
                Text("Every matched reading").daybreakSectionLabel()
                scatterCard(report)
            }
            densityCard(report)
        }
    }

    private func unmatchedMessage(_ report: HRVReport) -> String {
        if report.hasNative {
            let perNight = report.nativeReadingsPerNight.map { " — about \(Int($0.rounded())) a night" } ?? ""
            return "The Watch wrote its own RMSSD\(perNight), but only \(report.completeWindowCount) of those readings have a Fitbit reading beside them. Wear the Fitbit overnight, sync its HRV, and the comparison fills in."
        }
        return "Found \(report.windows.count) Apple readings but only \(report.completeWindowCount) had a Fitbit reading within five minutes. Sync more Fitbit nights and come back."
    }

    // MARK: - Verdict

    /// Did recomputing from raw beats actually beat Apple's own number? That is
    /// the question this screen exists to answer, so it goes first.
    private func verdictCard(_ report: HRVReport) -> some View {
        let derived = report.derivedOverall.spearman
        let published = report.publishedOverall.spearman
        let native = report.nativeOverall.spearman
        let wins = (derived ?? 0) > (published ?? 0)
        let best = [native, derived, published].compactMap { $0 }.max()
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 14) {
                if native != nil {
                    statColumn("Watch RMSSD", value: native, highlight: native == best)
                }
                statColumn("Recomputed", value: derived, highlight: derived != nil && derived == best)
                statColumn("Apple SDNN", value: published, highlight: published != nil && published == best)
                Spacer(minLength: 0)
            }
            Text(native != nil ? nativeSentence(report.nativeOverall) : verdictSentence(report, wins: wins))
                .font(Daybreak.bodyFont)
                .foregroundStyle(Daybreak.mid)
            Text(native != nil
                 ? "Rank agreement with Fitbit, reading by reading: \(report.nativeOverall.n) Watch readings, \(report.derivedOverall.n) spot checks, over \(report.nightCount) nights."
                 : "Rank agreement with Fitbit across \(report.completeWindowCount) matched readings on \(report.nightCount) nights. Both from the same Apple Watch — the only difference is what gets computed from the beats.")
                .font(Daybreak.captionFont)
                .foregroundStyle(Daybreak.faint)
        }
        .daybreakCard()
    }

    /// The Watch's own RMSSD is the first Apple series that is the same
    /// statistic *and* the same cadence as Fitbit's, so its offset is a real
    /// disagreement in milliseconds, not an artefact of comparing unlike things.
    private func nativeSentence(_ summary: RecoveryStats.AgreementSummary) -> String {
        guard let rho = summary.spearman else {
            return "Not enough matched Watch readings to compare yet."
        }
        var sentence = "The Watch's own RMSSD — same statistic, same five-minute cadence as Fitbit — ranks \(summary.n) matched readings at ρ \(Self.format(rho))"
        if let bias = summary.ratioBiasPct {
            sentence += String(format: ", reading %@%.0f%% against Fitbit", bias >= 0 ? "+" : "", bias)
            if let low = summary.ratioLoALowPct, let high = summary.ratioLoAHighPct {
                sentence += String(format: " (95%% of readings within %+.0f%% to %+.0f%%)", low, high)
            }
        }
        return sentence + ". Five-minute readings are noisy on both devices, so expect this lower than the nightly agreement on the Recovery screen."
    }

    private func statColumn(_ label: String, value: Double?, highlight: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(Self.format(value))
                .font(Daybreak.numberFont(size: statValueSize * 1.2))
                .foregroundStyle(highlight ? Daybreak.sunDeep : Daybreak.mid)
            Text(label)
                .font(.system(.caption2, design: .rounded, weight: .semibold))
                .foregroundStyle(Daybreak.faint)
        }
    }

    private func verdictSentence(_ report: HRVReport, wins: Bool) -> String {
        guard let derived = report.derivedOverall.spearman,
              let published = report.publishedOverall.spearman else {
            return "Not enough matched readings to compare the two."
        }
        // Two rank correlations this close are the same answer. Calling a 0.01
        // difference a win is how a screen starts lying quietly.
        if abs(derived - published) < 0.03 {
            return "Recomputing from the raw beats and taking Apple's published SDNN rank these readings about equally well against Fitbit. They diverge more on nightly values than on ordering — see the zone table and the scatter below."
        }
        if wins {
            let ratio = derived / published
            let gain = published > 0 && ratio >= 1.1
                ? " — \(String(format: "%.1f×", ratio)) the agreement"
                : ""
            return "Recomputing RMSSD from the raw beats tracks Fitbit better than Apple's published SDNN does\(gain). Same sensor, same minute; the difference is the statistic and the artifact filter."
        }
        return "Apple's published SDNN is tracking Fitbit better than the recomputed RMSSD here. Worth checking the artifact rates by zone below before concluding — a high rejection rate means the recomputation had little left to work with."
    }

    // MARK: - One night

    private func nightCard(_ report: HRVReport) -> some View {
        let nights = Array(Set(report.windows.map(\.night))).sorted()
        let index = min(max(nightIndex, 0), max(nights.count - 1, 0))
        let night = nights.isEmpty ? Date() : nights[index]
        let windows = report.windows(for: night)
        let chart = model.recovery.state.report?.chart(for: night)

        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Button { nightIndex = max(0, index - 1) } label: { Image(systemName: "chevron.left") }
                    .disabled(index <= 0)
                Spacer(minLength: 0)
                VStack(spacing: 1) {
                    Text(night.formatted(.dateTime.weekday(.wide).month(.abbreviated).day()))
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

            if let chart, !chart.bands.isEmpty {
                stageStrip(chart)
            }
            overlayChart(windows: windows, chart: chart)
            legend(Self.sources(in: windows, fitbit: !(chart?.fitbit.isEmpty ?? true)))
            if windows.count > 12 {
                DisclosureGroup("All \(windows.count) readings") {
                    windowList(windows)
                }
                .font(.system(.footnote, design: .rounded, weight: .semibold))
                .tint(Daybreak.plum)
            } else {
                windowList(windows)
            }
        }
        .daybreakCard(padding: 18)
    }

    private func stageStrip(_ chart: NightChart) -> some View {
        Chart(chart.bands) { band in
            RectangleMark(
                xStart: .value("Start", band.start), xEnd: .value("End", band.end),
                yStart: .value("Lane", 0), yEnd: .value("Lane", 1)
            )
            .foregroundStyle(Self.color(band.stage))
        }
        .chartXScale(domain: chart.domain)
        .chartYScale(domain: 0...1)
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .frame(height: 20)
        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
    }

    /// Fitbit and the Watch's own RMSSD as lines because both sample every few
    /// minutes; the spot-check series as points because four readings a night
    /// is not a line, and drawing them as one would imply a continuity that was
    /// never measured.
    private func overlayChart(windows: [HRVWindow], chart: NightChart?) -> some View {
        let domain = chart?.domain ?? Self.domain(of: windows)
        return Chart {
            if visible.contains(.fitbit), let chart {
                ForEach(chart.fitbit) { point in
                    LineMark(
                        x: .value("Time", point.date),
                        y: .value("HRV", point.value),
                        series: .value("Source", "Fitbit")
                    )
                    .foregroundStyle(Daybreak.sunDeep)
                    .lineStyle(StrokeStyle(lineWidth: 1.6, lineCap: .round))
                    .interpolationMethod(.monotone)
                    .opacity(0.85)
                }
            }
            if visible.contains(.appleNative) {
                ForEach(windows.filter { $0.appleNative != nil }) { window in
                    LineMark(
                        x: .value("Time", window.at),
                        y: .value("HRV", window.appleNative ?? 0),
                        series: .value("Source", "Watch")
                    )
                    .foregroundStyle(Daybreak.teal)
                    .lineStyle(StrokeStyle(lineWidth: 1.6, lineCap: .round))
                    .interpolationMethod(.monotone)
                    .opacity(0.9)
                }
            }
            ForEach(windows) { window in
                if visible.contains(.applePublished), let value = window.applePublished {
                    PointMark(x: .value("Time", window.at), y: .value("HRV", value))
                        .symbol(.diamond)
                        .symbolSize(80)
                        .foregroundStyle(Daybreak.stageREM)
                }
                if visible.contains(.appleDerived), let value = window.appleDerived {
                    PointMark(x: .value("Time", window.at), y: .value("HRV", value))
                        .symbol(.circle)
                        .symbolSize(90)
                        .foregroundStyle(Daybreak.plum)
                }
                // The gap between what Apple says and what its beats say, drawn
                // as the distance it actually is.
                if visible.contains(.applePublished), visible.contains(.appleDerived),
                   let published = window.applePublished, let derived = window.appleDerived {
                    RuleMark(
                        x: .value("Time", window.at),
                        yStart: .value("From", min(published, derived)),
                        yEnd: .value("To", max(published, derived))
                    )
                    .foregroundStyle(Daybreak.plum.opacity(0.3))
                    .lineStyle(StrokeStyle(lineWidth: 1.5))
                }
            }
        }
        .chartXScale(domain: domain)
        .chartYScale(domain: .automatic(includesZero: false))
        .chartXAxis {
            AxisMarks(values: clockAlignedTicks(in: domain, everyHours: 2)) { _ in
                AxisGridLine().foregroundStyle(Daybreak.line)
                AxisValueLabel(format: .dateTime.hour())
                    .font(.system(.caption2, design: .rounded, weight: .medium))
                    .foregroundStyle(Daybreak.faint)
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { value in
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
        .frame(height: 190)
    }

    /// Tapping a series hides it — three overlaid series on one axis is exactly
    /// two too many when you are chasing one of them.
    private func legend(_ sources: [HRVSource]) -> some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 120), spacing: 12, alignment: .leading)],
            alignment: .leading,
            spacing: 6
        ) {
            ForEach(sources) { source in
                Button {
                    if visible.contains(source), visible.count > 1 {
                        visible.remove(source)
                    } else {
                        visible.insert(source)
                    }
                } label: {
                    HStack(spacing: 5) {
                        Circle()
                            .fill(Self.color(source))
                            .frame(width: 8, height: 8)
                            .opacity(visible.contains(source) ? 1 : 0.25)
                        Text(source.displayName)
                            .font(.system(.caption2, design: .rounded, weight: .semibold))
                            .foregroundStyle(visible.contains(source) ? Daybreak.mid : Daybreak.faint)
                    }
                }
                .buttonStyle(.plain)
            }
        }
    }

    /// Each reading spelled out, because with four a night the individual
    /// numbers are readable and a chart alone hides the artifact rate.
    @ViewBuilder
    private func windowList(_ windows: [HRVWindow]) -> some View {
        if windows.contains(where: { $0.appleNative != nil }) {
            nativeWindowList(windows)
        } else {
            spotWindowList(windows)
        }
    }

    /// The Watch's own readings against Fitbit's, with any spot check that fell
    /// inside a window spelled out beneath it rather than as three more
    /// mostly-empty columns.
    private func nativeWindowList(_ windows: [HRVWindow]) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Text("Time").frame(width: 52, alignment: .leading)
                Text("Zone").frame(maxWidth: .infinity, alignment: .leading)
                Text("Watch").frame(width: 46, alignment: .trailing)
                Text("Fitbit").frame(width: 44, alignment: .trailing)
                Text("Diff").frame(width: 44, alignment: .trailing)
            }
            .font(Daybreak.sectionLabelFont)
            .foregroundStyle(Daybreak.faint)
            ForEach(windows) { window in
                Divider().overlay(Daybreak.line).padding(.vertical, 6)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(window.at.formatted(date: .omitted, time: .shortened))
                            .frame(width: 52, alignment: .leading)
                            .foregroundStyle(Daybreak.mid)
                        HStack(spacing: 4) {
                            Circle()
                                .fill(window.stage.map(Self.color) ?? Daybreak.faint)
                                .frame(width: 6, height: 6)
                            Text(Self.stageName(window.stage))
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        Text(Self.ms(window.appleNative)).frame(width: 46, alignment: .trailing)
                        Text(Self.ms(window.fitbit)).frame(width: 44, alignment: .trailing)
                        Text(Self.signedPct(window.nativeErrorPct))
                            .frame(width: 44, alignment: .trailing)
                            .foregroundStyle(Daybreak.faint)
                    }
                    .font(.system(.caption, design: .rounded, weight: .semibold))
                    .foregroundStyle(Daybreak.ink)
                    if window.appleDerived != nil || window.applePublished != nil {
                        Text("Spot check: SDNN \(Self.ms(window.applePublished)) · recomputed RMSSD \(Self.ms(window.appleDerived)) · \(Self.pct(window.rejectionRate)) dropped")
                            .font(Daybreak.captionFont)
                            .foregroundStyle(Daybreak.faint)
                    }
                }
            }
            Divider().overlay(Daybreak.line).padding(.vertical, 6)
            Text("Diff is the Watch against Fitbit for the same five minutes.")
                .font(Daybreak.captionFont)
                .foregroundStyle(Daybreak.faint)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func spotWindowList(_ windows: [HRVWindow]) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Text("Time").frame(width: 52, alignment: .leading)
                Text("Zone").frame(maxWidth: .infinity, alignment: .leading)
                Text("SDNN").frame(width: 44, alignment: .trailing)
                Text("RMSSD").frame(width: 50, alignment: .trailing)
                Text("Fitbit").frame(width: 44, alignment: .trailing)
                Text("Drop").frame(width: 40, alignment: .trailing)
            }
            .font(Daybreak.sectionLabelFont)
            .foregroundStyle(Daybreak.faint)
            ForEach(windows) { window in
                Divider().overlay(Daybreak.line).padding(.vertical, 7)
                HStack(spacing: 6) {
                    Text(window.at.formatted(date: .omitted, time: .shortened))
                        .frame(width: 52, alignment: .leading)
                        .foregroundStyle(Daybreak.mid)
                    HStack(spacing: 4) {
                        Circle()
                            .fill(window.stage.map(Self.color) ?? Daybreak.faint)
                            .frame(width: 6, height: 6)
                        Text(Self.stageName(window.stage))
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Text(Self.ms(window.applePublished)).frame(width: 44, alignment: .trailing)
                    Text(Self.ms(window.appleDerived)).frame(width: 50, alignment: .trailing)
                    Text(Self.ms(window.fitbit)).frame(width: 44, alignment: .trailing)
                    Text(Self.pct(window.rejectionRate))
                        .frame(width: 40, alignment: .trailing)
                        .foregroundStyle(
                            (window.rejectionRate ?? 0) > 0.2 ? Daybreak.warn : Daybreak.faint
                        )
                }
                .font(.system(.caption, design: .rounded, weight: .semibold))
                .foregroundStyle(Daybreak.ink)
            }
            Divider().overlay(Daybreak.line).padding(.vertical, 7)
            Text("Drop is the share of beats the artifact filter rejected in that window. Over 20% and the RMSSD beside it rests on very little.")
                .font(Daybreak.captionFont)
                .foregroundStyle(Daybreak.faint)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Zones

    /// The stage breakdown — the "regions" question. If the derived RMSSD only
    /// beats the published SDNN in deep sleep, that is a different claim from
    /// beating it everywhere, and it changes what the metric is good for.
    private func zoneCard(_ report: HRVReport) -> some View {
        let showsNative = report.hasNative
        return VStack(spacing: 0) {
            HStack(spacing: 6) {
                Text("Zone").frame(maxWidth: .infinity, alignment: .leading)
                Text("n").frame(width: 30, alignment: .trailing)
                if showsNative {
                    Text("Watch").frame(width: 46, alignment: .trailing)
                }
                Text(showsNative ? "Recomp" : "RMSSD").frame(width: 52, alignment: .trailing)
                Text("SDNN").frame(width: 46, alignment: .trailing)
                if !showsNative {
                    Text("Drop").frame(width: 40, alignment: .trailing)
                }
            }
            .font(Daybreak.sectionLabelFont)
            .foregroundStyle(Daybreak.faint)
            ForEach(report.zones) { zone in
                Divider().overlay(Daybreak.line).padding(.vertical, 8)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        HStack(spacing: 5) {
                            Circle().fill(Self.color(zone.stage)).frame(width: 7, height: 7)
                            Text(zone.displayName)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        Text("\(zone.windowCount)").frame(width: 30, alignment: .trailing)
                        if showsNative {
                            Text(Self.format(zone.nativeSpearman)).frame(width: 46, alignment: .trailing)
                        }
                        Text(Self.format(zone.derivedSpearman))
                            .frame(width: 52, alignment: .trailing)
                            .foregroundStyle(zone.derivationWins ? Daybreak.sunDeep : Daybreak.ink)
                        Text(Self.format(zone.publishedSpearman)).frame(width: 46, alignment: .trailing)
                        if !showsNative {
                            Text(Self.pct(zone.medianRejectionRate)).frame(width: 40, alignment: .trailing)
                        }
                    }
                    .font(.system(.footnote, design: .rounded, weight: .semibold))
                    .foregroundStyle(Daybreak.ink)
                    if let median = zone.medians[.appleNative],
                       let fitbit = zone.medians[.fitbit] {
                        Text("Watch median \(Int(median)) ms vs Fitbit's \(Int(fitbit)) ms\(zone.nativeBiasPct.map { String(format: " · reads %@%.0f%%", $0 >= 0 ? "+" : "", $0) } ?? "").")
                            .font(Daybreak.captionFont)
                            .foregroundStyle(Daybreak.faint)
                    } else if let median = zone.medians[.appleDerived],
                       let fitbit = zone.medians[.fitbit] {
                        Text("Median \(Int(median)) ms vs Fitbit's \(Int(fitbit)) ms\(zone.derivedBiasPct.map { String(format: " · reads %@%.0f%%", $0 >= 0 ? "+" : "", $0) } ?? "").")
                            .font(Daybreak.captionFont)
                            .foregroundStyle(Daybreak.faint)
                    }
                }
            }
            Divider().overlay(Daybreak.line).padding(.vertical, 8)
            Text("Rank agreement with Fitbit inside each stage, orange where recomputing beats Apple's SDNN. Zones with fewer than five matched readings are left out rather than shown as a number that cannot mean anything; a spot-check column with too few of its own readings shows a dash.")
                .font(Daybreak.captionFont)
                .foregroundStyle(Daybreak.faint)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .daybreakCard(padding: 16)
    }

    // MARK: - Scatter

    private func scatterCard(_ report: HRVReport) -> some View {
        let complete = report.windows.filter(\.isComplete)
        return VStack(alignment: .leading, spacing: 10) {
            Chart {
                ForEach(complete) { window in
                    if visible.contains(.appleNative), let value = window.appleNative, let fitbit = window.fitbit {
                        PointMark(x: .value("Fitbit", fitbit), y: .value("Apple", value))
                            .symbol(.square)
                            .symbolSize(18)
                            .foregroundStyle(Daybreak.teal.opacity(0.45))
                    }
                    if visible.contains(.applePublished), let value = window.applePublished, let fitbit = window.fitbit {
                        PointMark(x: .value("Fitbit", fitbit), y: .value("Apple", value))
                            .symbol(.diamond)
                            .symbolSize(30)
                            .foregroundStyle(Daybreak.stageREM.opacity(0.55))
                    }
                    if visible.contains(.appleDerived), let value = window.appleDerived, let fitbit = window.fitbit {
                        PointMark(x: .value("Fitbit", fitbit), y: .value("Apple", value))
                            .symbolSize(34)
                            .foregroundStyle(Daybreak.plum.opacity(0.7))
                    }
                }
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
            .frame(height: 210)
            Text("Fitbit RMSSD across, Apple up — one point per matched reading, \(complete.count) in total. Tighter to a straight line is better agreement. Squares are the Watch's own RMSSD; diamonds sitting above the circles is SDNN reading high, which is expected and is not error.")
                .font(Daybreak.captionFont)
                .foregroundStyle(Daybreak.faint)
        }
        .daybreakCard(padding: 18)
    }

    // MARK: - Density

    private func densityCard(_ report: HRVReport) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(report.hasNative ? "Density is no longer the ceiling" : "Why the ceiling is where it is")
                .font(.system(.footnote, design: .rounded, weight: .bold))
                .foregroundStyle(Daybreak.ink)
            HStack(spacing: 18) {
                if let native = report.nativeReadingsPerNight {
                    statColumn("Watch RMSSD / night", value: native, highlight: false)
                } else if let apple = report.appleWindowsPerNight {
                    statColumn("Apple readings / night", value: apple, highlight: false)
                }
                if let fitbit = report.fitbitSamplesPerNight {
                    statColumn("Fitbit readings / night", value: fitbit, highlight: false)
                }
                Spacer(minLength: 0)
            }
            Text(report.hasNative
                 ? "On watchOS 27 the Watch reads RMSSD itself about every five minutes asleep — Fitbit's cadence. The spot checks and their beat series are still there for the older comparison, but whatever gap remains against Fitbit is now the sensors and the algorithms, not how often anyone looked."
                 : "The Watch opens its sensor for about a minute every two hours, and only at rest. Recomputing from the raw beats is worth doing — it is what the numbers above measure — but it cannot manufacture readings that were never taken, and that is what caps agreement with Fitbit rather than anything about the algorithm.")
                .font(Daybreak.captionFont)
                .foregroundStyle(Daybreak.mid)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .daybreakCard(padding: 16)
    }

    // MARK: - Formatting

    private static func format(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "—" }
        return String(format: "%.2f", value)
    }

    private static func ms(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "—" }
        return String(format: "%.0f", value)
    }

    private static func signedPct(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "—" }
        return String(format: "%+.0f%%", value)
    }

    /// The series this night actually has, so the legend never offers a toggle
    /// for something that is not on the chart.
    private static func sources(in windows: [HRVWindow], fitbit: Bool) -> [HRVSource] {
        HRVSource.allCases.filter { source in
            source == .fitbit ? fitbit : windows.contains { $0.value(source) != nil }
        }
    }

    private static func pct(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "—" }
        return String(format: "%.0f%%", value * 100)
    }

    private static func stageName(_ stage: SleepAgreement.Stage?) -> String {
        switch stage {
        case .awake: "Awake"
        case .core: "Core"
        case .deep: "Deep"
        case .rem: "REM"
        case .asleep: "Asleep"
        case nil: "Unscored"
        }
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

    private static func color(_ source: HRVSource) -> Color {
        switch source {
        case .appleNative: Daybreak.teal
        case .applePublished: Daybreak.stageREM
        case .appleDerived: Daybreak.plum
        case .fitbit: Daybreak.sunDeep
        }
    }

    private static func domain(of windows: [HRVWindow]) -> ClosedRange<Date> {
        guard let first = windows.map(\.at).min(), let last = windows.map(\.at).max(), last > first else {
            let now = Date()
            return now.addingTimeInterval(-3600)...now
        }
        let pad = max(900, last.timeIntervalSince(first) * 0.05)
        return first.addingTimeInterval(-pad)...last.addingTimeInterval(pad)
    }
}

/// Navigation token for the HRV screen.
struct HRVRoute: Hashable {}
