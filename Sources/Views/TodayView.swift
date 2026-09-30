import SwiftUI

/// The Today tab: how last night went on both devices, and a one-line sync
/// status that only asks for attention when something is held or broken.
/// Syncing itself lives on the Sync tab — for most mornings it ran on its own.
struct TodayView: View {
    @Environment(AppModel.self) private var model

    /// Tab switches, owned by the shell.
    let openCompare: () -> Void
    let openSync: () -> Void

    private var recovery: RecoveryEngine { model.recovery }
    private var sync: SyncEngine { model.syncEngine }
    private var fitbitName: String { sync.sourceDeviceName }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                syncLine
                // Evening leads with what's about to be slept on; the rest of
                // the day leads with how last night went.
                if isEvening {
                    tonightCard
                    lastNightSection
                } else {
                    lastNightSection
                    tonightCard
                }
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 28)
        }
        .daybreakBackground()
        .toolbarBackground(.hidden, for: .navigationBar)
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await recovery.load() }
        .task {
            if case .idle = recovery.state { await recovery.load() }
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(greeting)
                .font(Daybreak.titleFont)
                .foregroundStyle(Daybreak.ink)
            Text(Date().formatted(.dateTime.weekday(.wide).month(.wide).day()))
                .font(Daybreak.bodyFont)
                .foregroundStyle(Daybreak.mid)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 8)
    }

    private var greeting: String {
        switch Calendar.current.component(.hour, from: Date()) {
        case 5..<12: "Good morning ☀️"
        case 12..<17: "Good afternoon 🌤️"
        default: "Good evening 🌙"
        }
    }

    // MARK: - Tonight

    private var isEvening: Bool {
        let hour = Calendar.current.component(.hour, from: Date())
        return hour >= 17 || hour < JournalNight.smallHoursEnd
    }

    private var tonightCard: some View {
        NightLogCard(night: JournalNight.tonight(), title: "Tonight's log")
    }

    // MARK: - Sync line

    private var syncLine: some View {
        let (icon, tint, text) = syncState
        return Button(action: openSync) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(tint)
                Text(text)
                    .font(.system(.footnote, design: .rounded, weight: .semibold))
                    .foregroundStyle(Daybreak.ink)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Daybreak.faint)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .background(Daybreak.card, in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private var syncState: (String, Color, String) {
        let held = sync.staged.count + sync.stagedMetrics.count
        switch sync.status {
        case .syncing:
            return ("arrow.triangle.2.circlepath", Daybreak.plum, "Syncing with Google…")
        case .needsConnection:
            return ("exclamationmark.triangle.fill", Daybreak.warn, "Reconnect Google to keep HRV coming over")
        case .failed:
            return ("exclamationmark.triangle.fill", Daybreak.fail, "The last sync didn't finish")
        default:
            break
        }
        if !sync.isConnected {
            return ("link", Daybreak.warn, "Connect Google Health to start syncing")
        }
        if held > 0 {
            return ("tray.full.fill", Daybreak.warn, "\(held) item\(held == 1 ? "" : "s") held for your review")
        }
        if let last = sync.lastSyncedDate {
            let when = Calendar.current.isDateInToday(last)
                ? last.formatted(date: .omitted, time: .shortened)
                : last.formatted(date: .abbreviated, time: .shortened)
            return ("checkmark.circle.fill", Daybreak.ok, "Synced \(when) · all caught up")
        }
        return ("arrow.triangle.2.circlepath", Daybreak.mid, "Not synced yet")
    }

    // MARK: - Last night

    private var latest: SleepNightComparison? { recovery.sleep.nights.last }

    private var nightLabel: String {
        guard let night = latest?.night else { return "Last night" }
        if Calendar.current.isDateInToday(night) { return "Last night" }
        return night.formatted(.dateTime.weekday(.wide)) + " night"
    }

    private var lastNightSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(nightLabel).daybreakSectionLabel()
            lastNightCard
        }
    }

    @ViewBuilder
    private var lastNightCard: some View {
        switch recovery.state {
        case .loading, .idle:
            HStack(spacing: 12) {
                ProgressView()
                Text("Reading last night from Health…")
                    .font(Daybreak.bodyFont)
                    .foregroundStyle(Daybreak.mid)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .daybreakCard()
        case .failed(let message):
            Text(message)
                .font(Daybreak.bodyFont)
                .foregroundStyle(Daybreak.mid)
                .frame(maxWidth: .infinity, alignment: .leading)
                .daybreakCard()
        case .ready:
            if let night = latest {
                nightCard(night)
            } else {
                Text("No night in Health yet from either device.")
                    .font(Daybreak.bodyFont)
                    .foregroundStyle(Daybreak.mid)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .daybreakCard()
            }
        }
    }

    private func nightCard(_ night: SleepNightComparison) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("").frame(maxWidth: .infinity, alignment: .leading)
                Text(night.watchDevice ?? "Watch").frame(width: 84, alignment: .trailing)
                Text("Fitbit").frame(width: 64, alignment: .trailing)
                Text("Δ").frame(width: 56, alignment: .trailing)
            }
            .font(.system(.caption2, design: .rounded, weight: .semibold))
            .foregroundStyle(Daybreak.faint)
            .lineLimit(1)
            ForEach([SleepMeasure.total, .deep, .rem]) { measure in
                let watch = night.watch.map(measure.minutes)
                let fitbit = night.fitbit.map(measure.minutes)
                HStack {
                    Text(measure.displayName)
                        .font(.system(.subheadline, design: .rounded, weight: .semibold))
                        .foregroundStyle(Daybreak.ink)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text(watch.map(SleepCompareView.duration) ?? "—")
                        .frame(width: 84, alignment: .trailing)
                        .foregroundStyle(Daybreak.teal)
                    Text(fitbit.map(SleepCompareView.duration) ?? "—")
                        .frame(width: 64, alignment: .trailing)
                        .foregroundStyle(Daybreak.sunDeep)
                    Text(watch.flatMap { w in fitbit.map { SleepCompareView.signed($0 - w) } } ?? "")
                        .frame(width: 56, alignment: .trailing)
                        .foregroundStyle(Daybreak.mid)
                }
                .font(.system(.subheadline, design: .rounded).monospacedDigit())
            }
            Divider().overlay(Daybreak.line)
            Text(nightFootnote(night))
                .font(Daybreak.captionFont)
                .foregroundStyle(Daybreak.mid)
                .fixedSize(horizontal: false, vertical: true)
            Button("Compare every night →", action: openCompare)
                .font(.system(.footnote, design: .rounded, weight: .semibold))
                .foregroundStyle(Daybreak.plum)
            Divider().overlay(Daybreak.line)
            // The night's tags sit beside its numbers — "magnesium · deep
            // +38m" is the thing worth seeing first thing in the morning.
            NightLogCard(night: night.night, embedded: true)
        }
        .daybreakCard()
    }

    private func nightFootnote(_ night: SleepNightComparison) -> String {
        if night.fitbit == nil { return "No \(fitbitName) night in Health for this one." }
        if night.watch == nil { return "The Watch didn't record this night." }
        if let agreement = night.agreement {
            return "Same stage \(Int(agreement.rounded()))% of the minutes both were tracking."
        }
        return "Both devices scored this night."
    }
}
