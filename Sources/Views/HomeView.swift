import SwiftUI

/// Home: time-of-day greeting, the bridge card (live engine status + CTA),
/// the ready-for-review queue, recent crossings, and the pre-GA heads-up.
struct HomeView: View {
    @Environment(AppModel.self) private var model

    private var engine: SyncEngine { model.syncEngine }
    private var log: SyncLogStore { model.syncLog }

    // Buttons drive these pushes — a `NavigationLink` nested in a List row is
    // hijacked by the List (whole-row tap target, stray chevron, no style).
    @State private var pushedSession: StagedSession?
    @State private var pushedBatch: StagedMetricBatch?
    @State private var showHistory = false
    @State private var showPager = false
    @State private var browseTarget: BrowseTarget?

    /// Home → metric history pager entry (newest day, swipe back from there).
    struct BrowseTarget: Hashable, Identifiable {
        let kindRaw: String?
        let startDay: Date
        var id: String { kindRaw ?? "sleep" }
        var kind: MetricKind? { kindRaw.flatMap(MetricKind.init) }
    }

    var body: some View {
        List {
            greetingHeader
                .homeRow(top: 8, bottom: 18)
            if !model.isConfigured {
                setupCard
                    .homeRow()
            }
            bridgeCard
                .homeRow(bottom: 26)
            metricsSection
            recentSection
            HeadsUpCard.forMode(engine.syncMode)
                .homeRow(bottom: 24)
        }
        .listStyle(.plain)
        .environment(\.defaultMinListRowHeight, 10)
        .scrollContentBackground(.hidden)
        .daybreakBackground()
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .navigationDestination(item: $pushedSession) { SessionCompareView(staged: $0) }
        .navigationDestination(item: $pushedBatch) { MetricCompareView(batch: $0) }
        .navigationDestination(isPresented: $showHistory) { HistoryView() }
        .navigationDestination(isPresented: $showPager) { ReviewPagerView() }
        .navigationDestination(item: $browseTarget) {
            MetricHistoryPagerView(kind: $0.kind, startDay: $0.startDay)
        }
    }

    // MARK: - Greeting

    private var greetingHeader: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(greeting)
                .font(Daybreak.titleFont)
                .foregroundStyle(Daybreak.ink)
            Text(greetingSubline)
                .font(Daybreak.bodyFont)
                .foregroundStyle(Daybreak.mid)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var greeting: String {
        switch Calendar.current.component(.hour, from: Date()) {
        case 5..<12: "Good morning ☀️"
        case 12..<17: "Good afternoon 🌤️"
        default: "Good evening 🌙"
        }
    }

    private var greetingSubline: String {
        if let landed = log.entries.first(where: { $0.kind == .imported || $0.kind == .autoImported }),
           Calendar.current.isDateInToday(landed.date) {
            return "Last night came over the bridge at \(landed.date.formatted(date: .omitted, time: .shortened))."
        }
        if !engine.isConnected { return "Connect Google Health to start the airlift." }
        if waitingCount > 0 { return "New data is waiting for your OK below." }
        if let last = engine.lastSyncedDate {
            return "Last checked \(last.formatted(date: .abbreviated, time: .shortened))."
        }
        return "Nothing has crossed the bridge yet."
    }

    // MARK: - Bridge card

    /// Which body the bridge card shows — exactly one engine state at a time.
    private enum BridgeBody: Equatable {
        case syncing, reconnect, connect, queue, allClear
        case failed(String)
    }

    private var bridgeBody: BridgeBody {
        switch engine.status {
        case .syncing: return .syncing
        case .needsConnection: return .reconnect
        case .failed(let message): return .failed(message)
        default: break
        }
        if !engine.isConnected { return .connect }
        return waitingCount > 0 ? .queue : .allClear
    }

    private var bridgeCard: some View {
        VStack(spacing: 18) {
            BridgeView(deviceName: engine.sourceDeviceName)
            switch bridgeBody {
            case .syncing: pipelineBody
            case .reconnect: reconnectBody
            case .failed(let message): failedBody(message)
            case .connect: connectBody
            case .queue: queueBody
            case .allClear: allClearBody
            }
        }
        .daybreakCard()
        .animation(.easeInOut(duration: 0.25), value: bridgeBody)
    }

    // MARK: Queue banner

    private var waitingCount: Int { engine.staged.count + engine.stagedMetrics.count }

    private var pointCount: Int { engine.stagedMetrics.reduce(0) { $0 + $1.samples.count } }

    /// Counts what the user acts on — nights and metric-days — never raw
    /// sample counts ("229 points" read as 229 separate decisions when it was
    /// one day of distance). Sample counts live in the rows and sublines.
    private var queueHeadline: String {
        var parts: [String] = []
        let nights = engine.staged.count
        if nights > 0 { parts.append("\(nights) night\(nights == 1 ? "" : "s")") }
        let batches = engine.stagedMetrics
        let kinds = Set(batches.map(\.kind))
        switch (batches.count, kinds.count) {
        case (0, _):
            break
        case (1, _):
            parts.append("a day of \(batches[0].kind.inlineName)")
        case (let days, 1):
            parts.append("\(days) days of \(batches[0].kind.inlineName)")
        case (let days, _):
            parts.append("\(days) metrics")
        }
        let joined = parts.joined(separator: " + ")
        // "a day of distance" can lead the banner — give it a capital.
        return joined.prefix(1).uppercased() + joined.dropFirst()
    }

    /// Big banner: counts in sunDeep; automatic mode appends a smaller
    /// "held for review" so the number reads as the held queue, not new data.
    private var queueBanner: Text {
        let counts = Text(queueHeadline).foregroundStyle(Daybreak.sunDeep)
        guard engine.syncMode == .automatic else { return counts }
        return counts
            + Text(" held for review")
                .font(Daybreak.numberFont(size: 22))
                .foregroundStyle(Daybreak.ink)
    }

    private var queueSubline: String {
        let readings = pointCount > 0 ? "\(pointCount.formatted()) readings, fetched & checked" : "Fetched & checked"
        guard engine.syncMode == .automatic else {
            return "\(readings) — waiting for your OK. Nothing is written until you approve it."
        }
        let lead = autoLandedTodayLead ?? "Clean nights land on their own"
        let nights = engine.staged.count
        let held = switch nights {
        case 0: "this data is held for review"
        case 1: "\(Self.nightPhrase(for: engine.staged[0].session.end)) is held for review"
        default: "\(nights) nights are held for review"
        }
        return "\(lead) — \(held)."
    }

    /// "Last night landed on its own" when today's log says so — suppressed if
    /// last night is itself still queued, so the card never contradicts itself.
    private var autoLandedTodayLead: String? {
        guard log.entries.contains(where: {
            ($0.kind == .autoImported || $0.kind == .imported) && Calendar.current.isDateInToday($0.date)
        }), !engine.staged.contains(where: { Calendar.current.isDateInToday($0.session.end) })
        else { return nil }
        return "Last night landed on its own"
    }

    private var queueBody: some View {
        VStack(spacing: 14) {
            queueBanner
                .font(Daybreak.numberFont(size: 40))
                .multilineTextAlignment(.center)
                .minimumScaleFactor(0.7)
            Text(queueSubline)
                .font(.system(size: 13, design: .rounded))
                .foregroundStyle(Daybreak.mid)
                .multilineTextAlignment(.center)
            if waitingCount > 1 {
                Button("Review all \(waitingCount) →") {
                    showPager = true
                }
                .buttonStyle(.daybreakPrimary)
            } else if let night = engine.staged.first {
                Button("Review \(Self.nightPhrase(for: night.session.end)) →") {
                    pushedSession = night
                }
                .buttonStyle(.daybreakPrimary)
            } else if let batch = engine.stagedMetrics.first {
                Button("Review what's new →") {
                    pushedBatch = batch
                }
                .buttonStyle(.daybreakPrimary)
            }
            fetchMenu
        }
    }

    /// "last night" / "yesterday's night" / "Tuesday night" for CTA labels.
    private static func nightPhrase(for end: Date) -> String {
        if Calendar.current.isDateInToday(end) { return "last night" }
        if Calendar.current.isDateInYesterday(end) { return "yesterday's night" }
        return "\(end.formatted(.dateTime.weekday(.wide))) night"
    }

    // MARK: All clear

    private var allClearSubline: String {
        switch engine.status {
        case .autoSynced(let written, _, _) where written > 0:
            return "\(written) clean item\(written == 1 ? "" : "s") landed automatically — nothing else is waiting."
        case .success:
            return "Everything you approved is in Apple Health."
        case .fetched, .autoSynced:
            return "Nothing new from Google — you're all caught up."
        default:
            if let last = engine.lastSyncedDate {
                return "Quiet since \(last.formatted(date: .abbreviated, time: .shortened)) — fetch to check for new nights."
            }
            return "Fetch from Google to carry your first night across."
        }
    }

    private var allClearBody: some View {
        VStack(spacing: 14) {
            Text("All caught up")
                .font(Daybreak.numberFont(size: 30))
                .foregroundStyle(Daybreak.ink)
            Text(allClearSubline)
                .font(.system(size: 13, design: .rounded))
                .foregroundStyle(Daybreak.mid)
                .multilineTextAlignment(.center)
            Menu {
                fetchOptions
            } label: {
                primaryMenuLabel("Fetch now")
            } primaryAction: {
                fetch(days: 7)
            }
            .disabled(!model.isConfigured)
            Text("Checks the last 7 days · touch and hold for more")
                .font(.system(size: 11.5, weight: .medium, design: .rounded))
                .foregroundStyle(Daybreak.faint)
        }
    }

    // MARK: Live pipeline

    private var pipelineBody: some View {
        VStack(alignment: .leading, spacing: 12) {
            if case .syncing(let phase) = engine.status {
                Text(phase)
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .foregroundStyle(Daybreak.ink)
                    .contentTransition(.opacity)
            }
            ForEach(engine.pipeline) { item in
                HStack(spacing: 10) {
                    pipelineIcon(item.step)
                        .font(.system(size: 14))
                        .frame(width: 22)
                    Text(item.name)
                        .font(.system(size: 13.5, weight: .medium, design: .rounded))
                        .foregroundStyle(Daybreak.ink)
                    Spacer()
                    Text(pipelineLabel(item))
                        .font(.system(size: 12, design: .rounded))
                        .foregroundStyle(Daybreak.mid)
                        .contentTransition(.opacity)
                }
            }
            Text("Nothing lands without checks.")
                .font(.system(size: 11.5, weight: .medium, design: .rounded))
                .foregroundStyle(Daybreak.faint)
                .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(.easeInOut(duration: 0.2), value: engine.pipeline)
    }

    @ViewBuilder
    private func pipelineIcon(_ step: PipelineItem.Step) -> some View {
        switch step {
        case .waiting:
            Image(systemName: "circle.dotted").foregroundStyle(Daybreak.faint)
        case .fetching:
            Image(systemName: "arrow.down.circle")
                .foregroundStyle(Daybreak.plum)
                .symbolEffect(.pulse)
        case .comparing:
            Image(systemName: "chart.bar.xaxis")
                .foregroundStyle(Daybreak.sunDeep)
                .symbolEffect(.pulse)
        case .done:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(Daybreak.ok)
        case .failed:
            Image(systemName: "xmark.circle.fill").foregroundStyle(Daybreak.fail)
        }
    }

    private func pipelineLabel(_ item: PipelineItem) -> String {
        switch item.step {
        case .waiting: return "waiting"
        case .fetching(let readings):
            let noun = item.id == "sleep" ? "nights" : "readings"
            return readings > 0 ? "\(readings.formatted()) \(noun)…" : "fetching…"
        case .comparing: return "comparing vs Apple…"
        case .done(let imported, let held):
            switch (imported, held) {
            case (0, 0): return "nothing new"
            case (_, 0): return "\(imported) landed ✓"
            case (0, _): return "\(held) to review"
            default: return "\(imported) landed · \(held) to review"
            }
        case .failed: return "didn't make it"
        }
    }

    // MARK: Connect / reconnect / failed

    private var connectBody: some View {
        VStack(spacing: 14) {
            Text("Start the airlift")
                .font(Daybreak.numberFont(size: 30))
                .foregroundStyle(Daybreak.ink)
            Text("All your Fitbit data is fetched locally and merged into Apple Health. You're in control — review everything yourself, or let Airlift auto-merge what passes its checks. Undo anytime.")
                .font(.system(size: 13, design: .rounded))
                .foregroundStyle(Daybreak.mid)
                .multilineTextAlignment(.center)
            TrustList()
            Button("Connect Google Health") {
                Task { await engine.connect() }
            }
            .buttonStyle(.daybreakPrimary)
            .disabled(!model.isConfigured)
            Text("One Google limitation while their Health API is pre-release: sign-ins last about 7 days, so you'll reconnect weekly. Airlift sends a reminder when it's time.")
                .font(.system(size: 11.5, design: .rounded))
                .foregroundStyle(Daybreak.faint)
                .multilineTextAlignment(.center)
        }
    }

    private var reconnectBody: some View {
        VStack(spacing: 14) {
            noticeBanner(
                symbol: "key.slash",
                tint: Daybreak.warn,
                background: Daybreak.warnChipBackground,
                title: "The bridge is paused",
                detail: "Your weekly Google sign-in expired — reconnect to keep the bridge open."
            )
            Button("Reconnect Google") {
                Task { await engine.connect() }
            }
            .buttonStyle(.daybreakPrimary)
        }
    }

    private func failedBody(_ message: String) -> some View {
        VStack(spacing: 14) {
            noticeBanner(
                symbol: "cloud.rain",
                tint: Daybreak.fail,
                background: Daybreak.failChipBackground,
                title: "That fetch didn't make it across",
                detail: message
            )
            Button("Try again") { fetch(days: 7) }
                .buttonStyle(.daybreakPrimary)
                .disabled(!model.isConfigured)
        }
    }

    private func noticeBanner(symbol: String, tint: Color, background: Color, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(tint)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .foregroundStyle(Daybreak.ink)
                Text(detail)
                    .font(.system(size: 12.5, design: .rounded))
                    .foregroundStyle(Daybreak.mid)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(background.opacity(0.6), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    // MARK: Fetch

    private var fetchOptions: some View {
        ForEach([7, 14, 30], id: \.self) { days in
            Button("Last \(days) days") { fetch(days: days) }
        }
    }

    private var fetchMenu: some View {
        Menu {
            fetchOptions
        } label: {
            Text("Fetch again · last 7 days")
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .foregroundStyle(Daybreak.plum)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 13)
                .background(Daybreak.plum.opacity(0.08), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        } primaryAction: {
            fetch(days: 7)
        }
        .disabled(!model.isConfigured)
    }

    /// Mirrors the primary button style for `Menu`, which can't take a `ButtonStyle`.
    private func primaryMenuLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 17, weight: .bold, design: .rounded))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 15)
            .background(Daybreak.cta, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .shadow(color: Daybreak.sunDeep.opacity(0.45), radius: 14, y: 8)
    }

    private func fetch(days: Int) {
        Task {
            await engine.fetchForReview(days: days)
            if engine.syncMode == .automatic {
                await engine.autoImportClean()
            }
        }
    }

    // MARK: - Your metrics

    /// One row per data kind that has ever landed in Apple Health — tapping
    /// opens the day-swipeable history on its newest day.
    private struct MetricRowInfo: Identifiable {
        let kindRaw: String?
        let name: String
        let symbol: String
        let dayCount: Int
        let newestDay: Date
        var id: String { kindRaw ?? "sleep" }
    }

    private var metricRows: [MetricRowInfo] {
        var rows: [MetricRowInfo] = []
        let sleepDays = engine.daysWithData(kind: nil)
        if let newest = sleepDays.last {
            rows.append(MetricRowInfo(kindRaw: nil, name: "Sleep", symbol: "moon.zzz.fill", dayCount: sleepDays.count, newestDay: newest))
        }
        for kind in MetricKind.allCases {
            let days = engine.daysWithData(kind: kind)
            guard let newest = days.last else { continue }
            rows.append(MetricRowInfo(kindRaw: kind.rawValue, name: kind.displayName, symbol: kind.systemImage, dayCount: days.count, newestDay: newest))
        }
        return rows
    }

    @ViewBuilder
    private var metricsSection: some View {
        let rows = metricRows
        if !rows.isEmpty {
            Text("Your metrics")
                .daybreakSectionLabel()
                .homeRow(bottom: 10)
            VStack(alignment: .leading, spacing: 14) {
                ForEach(rows) { row in
                    Button {
                        browseTarget = BrowseTarget(kindRaw: row.kindRaw, startDay: row.newestDay)
                    } label: {
                        HStack(spacing: 12) {
                            Circle()
                                .fill(Daybreak.newChipBackground)
                                .frame(width: 34, height: 34)
                                .overlay {
                                    Image(systemName: row.symbol)
                                        .font(.system(size: 13, weight: .bold))
                                        .foregroundStyle(Daybreak.plum)
                                }
                            VStack(alignment: .leading, spacing: 2) {
                                Text(row.name)
                                    .font(.system(size: 14.5, weight: .bold, design: .rounded))
                                    .foregroundStyle(Daybreak.ink)
                                Text("\(row.dayCount) day\(row.dayCount == 1 ? "" : "s") in Apple Health · newest \(row.newestDay.formatted(date: .abbreviated, time: .omitted))")
                                    .font(.system(size: 12.5, design: .rounded))
                                    .foregroundStyle(Daybreak.mid)
                            }
                            Spacer(minLength: 0)
                            Image(systemName: "chevron.right")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundStyle(Daybreak.faint)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    if row.id != rows.last?.id {
                        Divider().overlay(Daybreak.line)
                    }
                }
            }
            .daybreakCard(padding: 16)
            .homeRow(bottom: 26)
        }
    }

    // MARK: - Recent crossings

    @ViewBuilder
    private var recentSection: some View {
        if !log.entries.isEmpty {
            Text("Recent crossings")
                .daybreakSectionLabel()
                .homeRow(bottom: 10)
            recentCard
                .homeRow(bottom: 26)
        }
    }

    private var recentCard: some View {
        let recent = Array(log.entries.prefix(3))
        return VStack(alignment: .leading, spacing: 0) {
            ForEach(recent) { entry in
                HStack(alignment: .top, spacing: 10) {
                    Circle()
                        .fill(dotColor(entry.kind))
                        .frame(width: 7, height: 7)
                        .padding(.top, 5)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.title)
                            .font(.system(size: 13.5, weight: .bold, design: .rounded))
                            .foregroundStyle(Daybreak.ink)
                        Text("\(Self.whenLabel(entry.date)) — \(Self.previewDetail(entry.detail))")
                            .font(.system(size: 12, design: .rounded))
                            .foregroundStyle(Daybreak.mid)
                            .lineLimit(3)
                    }
                    Spacer(minLength: 0)
                }
                Divider()
                    .overlay(Daybreak.line)
                    .padding(.vertical, 10)
            }
            Button {
                showHistory = true
            } label: {
                HStack(spacing: 4) {
                    Text("See all")
                    Image(systemName: "arrow.right")
                        .font(.system(size: 11, weight: .bold))
                }
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .foregroundStyle(Daybreak.plum)
            }
            .buttonStyle(.plain)
        }
        .daybreakCard(padding: 16)
    }

    private func dotColor(_ kind: SyncLogEntry.Kind) -> Color {
        switch kind {
        case .imported, .autoImported: Daybreak.sunDeep
        case .fetched: Daybreak.plum
        case .tossed, .held: Daybreak.warn
        case .nothingNew: Daybreak.faint
        case .connected: Daybreak.ok
        case .error: Daybreak.fail
        }
    }

    /// Home previews the log: long details are cut at a sentence or clause
    /// boundary so rows never ellipsize mid-word — the full story is in History.
    private static func previewDetail(_ detail: String) -> String {
        guard detail.count > 90 else { return detail }
        if let sentence = detail.range(of: ". ") {
            return String(detail[..<sentence.lowerBound]) + "."
        }
        if let clause = detail.range(of: " — "), clause.lowerBound != detail.startIndex {
            return String(detail[..<clause.lowerBound]) + "."
        }
        return detail
    }

    private static func whenLabel(_ date: Date) -> String {
        let time = date.formatted(date: .omitted, time: .shortened)
        if Calendar.current.isDateInToday(date) { return "Today · \(time)" }
        if Calendar.current.isDateInYesterday(date) { return "Yesterday · \(time)" }
        return "\(date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())) · \(time)"
    }

    // MARK: - Setup hint

    private var setupCard: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 16))
                .foregroundStyle(Daybreak.warn)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 3) {
                Text("Not configured")
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .foregroundStyle(Daybreak.ink)
                Text("Copy Config.example.xcconfig to Config.xcconfig and add your Google Cloud iOS OAuth client ID, then rebuild. See the README.")
                    .font(.system(size: 12.5, design: .rounded))
                    .foregroundStyle(Daybreak.mid)
            }
            Spacer(minLength: 0)
        }
        .daybreakCard(padding: 16)
    }

}

// MARK: - Stage agreement


// MARK: - Row plumbing

private extension View {
    /// One transparent, separator-free list row with the Daybreak gutters —
    /// `List` only so swipe-to-toss keeps working on queue rows.
    func homeRow(top: CGFloat = 0, bottom: CGFloat = 18) -> some View {
        listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets(top: top, leading: 18, bottom: bottom, trailing: 18))
    }
}
