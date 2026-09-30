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
    /// The night under the finger in the trend chart.
    @State private var selectedDay: Date?

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
                Text("Fitbit Δ").frame(width: 70, alignment: .trailing)
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
                        Text(Self.signed(summary.meanDifference)).frame(width: 70, alignment: .trailing)
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

    /// One stick per night: the Watch's value and Fitbit's joined by a rule
    /// whose length is the gap. Nights are separate measurements, so nothing
    /// connects one night to the next — a line would draw values across nights
    /// that were never worn. A night only one device scored is a lone marker.
    private func trendCard(_ report: SleepComparisonReport) -> some View {
        let nights = report.nights
        let selected = selectedDay.flatMap { day in
            nights.first { Calendar.current.isDate($0.night, inSameDayAs: day) }
        }
        return VStack(alignment: .leading, spacing: 12) {
            Picker("Measure", selection: $measure) {
                ForEach(SleepMeasure.allCases) { measure in
                    Text(Self.shortName(measure)).tag(measure)
                }
            }
            .pickerStyle(.segmented)
            Chart {
                ForEach(nights) { night in
                    let watch = night.watch.map(measure.minutes)
                    let fitbit = night.fitbit.map(measure.minutes)
                    let dimmed = selected != nil && selected?.night != night.night
                    if let watch, let fitbit {
                        RuleMark(
                            x: .value("Night", night.night, unit: .day),
                            yStart: .value("Minutes", min(watch, fitbit)),
                            yEnd: .value("Minutes", max(watch, fitbit))
                        )
                        .foregroundStyle(Daybreak.faint)
                        .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round))
                        .opacity(dimmed ? 0.3 : 1)
                    }
                    if let watch {
                        marker(night.night, watch, color: Daybreak.teal, shape: .circle, device: "Watch", dimmed: dimmed)
                    }
                    if let fitbit {
                        marker(night.night, fitbit, color: Daybreak.sunDeep, shape: .diamond, device: "Fitbit", dimmed: dimmed)
                    }
                }
                if let selected {
                    RuleMark(x: .value("Night", selected.night, unit: .day))
                        .foregroundStyle(Daybreak.line)
                        .zIndex(-1)
                        .annotation(
                            position: .top, spacing: 4,
                            overflowResolution: .init(x: .fit(to: .chart), y: .disabled)
                        ) {
                            selectionCallout(selected)
                        }
                }
            }
            .chartXSelection(value: $selectedDay)
            .chartYScale(domain: .automatic(includesZero: true))
            .chartYAxis {
                AxisMarks(values: .stride(by: Self.tickMinutes(nights, measure))) { value in
                    AxisGridLine().foregroundStyle(Daybreak.line)
                    AxisValueLabel {
                        if let minutes = value.as(Double.self) { Text(Self.duration(minutes)) }
                    }
                }
            }
            .chartXAxis {
                AxisMarks(values: .stride(by: .day, count: 14)) { _ in
                    AxisGridLine().foregroundStyle(Daybreak.line)
                    AxisValueLabel(format: .dateTime.month(.abbreviated).day())
                }
            }
            .frame(height: 210)
            .padding(.top, selected == nil ? 0 : 36)
            .onChange(of: selectedDay) { _, day in
                // A tapped night opens in the card below, so the stick and its
                // hypnograms are one tap apart.
                guard let day, let index = nights.firstIndex(where: {
                    Calendar.current.isDate($0.night, inSameDayAs: day)
                }) else { return }
                nightIndex = index
            }
            HStack(spacing: 14) {
                legendMarker(Daybreak.teal, "circle.fill", report.nights.lazy.compactMap(\.watchDevice).first ?? "Watch")
                legendMarker(Daybreak.sunDeep, "diamond.fill", fitbitName)
            }
            Text("Each stick is one night: its length is how far apart the two devices were. Touch a night to see it below.")
                .font(Daybreak.captionFont)
                .foregroundStyle(Daybreak.faint)
                .fixedSize(horizontal: false, vertical: true)
        }
        .daybreakCard(padding: 18)
    }

    /// A marker with a card-colored ring, so a Watch dot and a Fitbit diamond
    /// on the same night stay separable where they overlap.
    @ChartContentBuilder
    private func marker(
        _ night: Date, _ minutes: Double, color: Color,
        shape: BasicChartSymbolShape, device: String, dimmed: Bool
    ) -> some ChartContent {
        PointMark(
            x: .value("Night", night, unit: .day),
            y: .value("Minutes", minutes)
        )
        .symbol(shape)
        .symbolSize(56)
        .foregroundStyle(Daybreak.card)
        PointMark(
            x: .value("Night", night, unit: .day),
            y: .value("Minutes", minutes)
        )
        .symbol(shape)
        .symbolSize(26)
        .foregroundStyle(color)
        .opacity(dimmed ? 0.3 : 1)
        .accessibilityLabel("\(device), \(night.formatted(date: .abbreviated, time: .omitted))")
        .accessibilityValue(Self.duration(minutes))
    }

    private func selectionCallout(_ night: SleepNightComparison) -> some View {
        let watch = night.watch.map(measure.minutes)
        let fitbit = night.fitbit.map(measure.minutes)
        return VStack(alignment: .leading, spacing: 2) {
            Text(night.night.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()))
                .font(.system(.caption2, design: .rounded, weight: .bold))
                .foregroundStyle(Daybreak.ink)
            HStack(spacing: 8) {
                Text("Watch \(watch.map(Self.duration) ?? "—")")
                Text("Fitbit \(fitbit.map(Self.duration) ?? "—")")
                if let watch, let fitbit {
                    Text(Self.signed(fitbit - watch)).fontWeight(.bold)
                }
            }
            .font(.system(.caption2, design: .rounded).monospacedDigit())
            .foregroundStyle(Daybreak.mid)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(Daybreak.card, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Daybreak.line))
    }

    private func legendMarker(_ color: Color, _ symbol: String, _ label: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: symbol)
                .font(.system(size: 8))
                .foregroundStyle(color)
            Text(label)
                .font(.system(.caption2, design: .rounded, weight: .semibold))
                .foregroundStyle(Daybreak.mid)
        }
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
            Text(watch.flatMap { w in fitbit.map { Self.signed($0 - w) } } ?? "").frame(width: 70, alignment: .trailing)
                .foregroundStyle(Daybreak.mid)
        }
        .font(.system(.footnote, design: .rounded).monospacedDigit())
    }

    // MARK: - Formatting

    /// Ticks on whole hours or half hours — Charts' own picks land on
    /// minute counts like 1h 40m that nobody reads a clock in.
    private static func tickMinutes(_ nights: [SleepNightComparison], _ measure: SleepMeasure) -> Double {
        let peak = nights.flatMap { [$0.watch, $0.fitbit].compactMap { $0.map(measure.minutes) } }.max() ?? 0
        switch peak {
        case ..<90: return 15
        case ..<200: return 30
        case ..<420: return 60
        default: return 120
        }
    }

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

    /// "+23m" / "−1h5m" — compact, since a difference column must stay one line.
    static func signed(_ minutes: Double) -> String {
        let rounded = Int(minutes.rounded())
        if rounded == 0 { return "±0m" }
        let size = abs(rounded)
        let body = size >= 60 ? "\(size / 60)h\(size % 60)m" : "\(size)m"
        return (rounded > 0 ? "+" : "−") + body
    }
}

struct SleepRoute: Hashable {}
