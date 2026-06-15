import SwiftUI

/// "What crossed over" — the plain-language record of every sync: a 2×2 stat
/// grid over a dot-and-line timeline rendered straight from the sync log.
struct HistoryView: View {
    @Environment(AppModel.self) private var model

    private var log: SyncLogStore { model.syncLog }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                statGrid
                timelineCard
                HeadsUpCard(message: HeadsUpCard.historyMessage)
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 28)
        }
        .daybreakBackground()
        .toolbarBackground(.hidden, for: .navigationBar)
        .navigationBarTitleDisplayMode(.inline)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("What crossed over")
                .font(Daybreak.titleFont)
                .foregroundStyle(Daybreak.ink)
            Text("A plain-language record of every sync.")
                .font(Daybreak.bodyFont)
                .foregroundStyle(Daybreak.mid)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 8)
    }

    // MARK: - Stats

    private var statGrid: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible())], spacing: 12) {
            MiniStat("🌉", value: "\(nightsBridged)",
                     caption: nightsBridged == 1 ? "night bridged" : "nights bridged")
            MiniStat("🛡️", value: "\(log.count(of: .held))", caption: "held back by checks")
            MiniStat("📥", value: readingsWritten.formatted(),
                     caption: readingsWritten == 1 ? "reading written" : "readings written")
            MiniStat("🔒", value: "0", caption: "bytes off-device")
        }
    }

    /// Nights of sleep the ledger says actually landed — counted at write
    /// time, not inferred from log copy that might change wording.
    private var nightsBridged: Int {
        model.syncEngine.ledger.all.filter { entry in
            guard entry.kind == sleepLedgerKind else { return false }
            if case .synced = entry.status { return true }
            return false
        }.count
    }

    /// Every sample Airlift has written into Apple Health, straight from the
    /// ledger's per-day synced counts.
    private var readingsWritten: Int {
        model.syncEngine.ledger.all.reduce(0) { total, entry in
            if case .synced(let samples, _) = entry.status { return total + samples }
            return total
        }
    }

    // MARK: - Timeline

    private var timelineCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            if log.entries.isEmpty {
                emptyTimeline
            }
            ForEach(log.entries) { entry in
                timelineRow(entry, isLast: entry.id == log.entries.last?.id)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .daybreakCard()
    }

    private var emptyTimeline: some View {
        VStack(spacing: 8) {
            Text("🌉")
                .font(.system(.title))
            Text("Nothing has crossed the bridge yet")
                .font(.system(.subheadline, design: .rounded, weight: .bold))
                .foregroundStyle(Daybreak.ink)
            Text("Fetch from Google on the home screen and every crossing will be recorded here.")
                .font(.system(.caption, design: .rounded))
                .foregroundStyle(Daybreak.mid)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
    }

    private func timelineRow(_ entry: SyncLogEntry, isLast: Bool) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(spacing: 0) {
                ZStack {
                    Circle()
                        .fill(dotColor(entry.kind).opacity(0.18))
                        .frame(width: 17, height: 17)
                    Circle()
                        .fill(dotColor(entry.kind))
                        .frame(width: 8, height: 8)
                }
                if !isLast {
                    Rectangle()
                        .fill(Daybreak.line)
                        .frame(width: 2)
                        .frame(maxHeight: .infinity)
                        .padding(.vertical, 2)
                }
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(dayLabel(entry.date))
                    .daybreakSectionLabel()
                Text(entry.title)
                    .font(.system(.subheadline, design: .rounded, weight: .bold))
                    .foregroundStyle(Daybreak.ink)
                    .fixedSize(horizontal: false, vertical: true)
                Text(entry.detail)
                    .font(.system(.caption, design: .rounded))
                    .foregroundStyle(Daybreak.mid)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.bottom, isLast ? 0 : 18)
            Spacer(minLength: 0)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func dotColor(_ kind: SyncLogEntry.Kind) -> Color {
        switch kind {
        case .imported: Daybreak.sunDeep
        case .autoImported: Daybreak.ok
        case .fetched: Daybreak.plum
        case .tossed, .held: Daybreak.warn
        case .nothingNew: Daybreak.faint
        case .connected: Daybreak.ok
        case .disconnected: Daybreak.faint
        case .error: Daybreak.fail
        }
    }

    private func dayLabel(_ date: Date) -> String {
        let time = date.formatted(date: .omitted, time: .shortened)
        if Calendar.current.isDateInToday(date) { return "Today · \(time)" }
        if Calendar.current.isDateInYesterday(date) { return "Yesterday · \(time)" }
        return "\(date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())) · \(time)"
    }
}
