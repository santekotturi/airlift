import SwiftUI

/// One day's data, read back from Apple Health: what Airlift wrote (with the
/// other-sources comparison when one exists), anything still waiting for
/// review, and per-kind removal for data that looks wrong.
struct CalendarDayView: View {
    @Environment(AppModel.self) private var model

    let day: Date

    @State private var snapshots: [SyncEngine.DayKindSnapshot]?
    /// Pager entry: which kind to open the day-swipeable history on.
    struct HistoryTarget: Hashable, Identifiable {
        let kindRaw: String?
        var id: String { kindRaw ?? "sleep" }
        var kind: MetricKind? { kindRaw.flatMap(MetricKind.init) }
    }

    @State private var pushedSession: StagedSession?
    @State private var pushedBatch: StagedMetricBatch?
    @State private var historyTarget: HistoryTarget?

    private var engine: SyncEngine { model.syncEngine }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                if let snapshots {
                    if snapshots.isEmpty && stagedForDay.isEmpty && stagedBatchesForDay.isEmpty {
                        emptyCard
                    } else {
                        if !snapshots.isEmpty {
                            landedCard(snapshots)
                        }
                        reviewCard
                    }
                } else {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 30)
                }
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 28)
        }
        .daybreakBackground()
        .toolbarBackground(.hidden, for: .navigationBar)
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(item: $pushedSession) { SessionCompareView(staged: $0) }
        .navigationDestination(item: $pushedBatch) { MetricCompareView(batch: $0) }
        .navigationDestination(item: $historyTarget) {
            MetricHistoryPagerView(kind: $0.kind, startDay: day)
        }
        // Re-reads on every appearance so a removal done one level deeper is
        // reflected the moment the user pops back.
        .onAppear {
            Task { snapshots = await engine.calendarSnapshot(for: day) }
            #if DEBUG
            // `-AirliftUIMockScreen history-pager` deep-links into the
            // day-swipeable heart-rate history for screenshot runs.
            if engine.isUIMock, UIMock.screen == "history-pager", historyTarget == nil {
                historyTarget = HistoryTarget(kindRaw: MetricKind.heartRate.rawValue)
            }
            #endif
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(day.formatted(.dateTime.weekday(.wide).month(.wide).day()))
                .font(Daybreak.titleFont)
                .foregroundStyle(Daybreak.ink)
            Text("What the airlift carried this day.")
                .font(Daybreak.bodyFont)
                .foregroundStyle(Daybreak.mid)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 8)
    }

    // MARK: - Landed data

    private func landedCard(_ snapshots: [SyncEngine.DayKindSnapshot]) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("In Apple Health from Airlift")
                .daybreakSectionLabel()
            ForEach(snapshots) { snapshot in
                Button {
                    open(snapshot)
                } label: {
                    HStack(alignment: .top, spacing: 12) {
                        Circle()
                            .fill(Daybreak.okChipBackground)
                            .frame(width: 34, height: 34)
                            .overlay {
                                Image(systemName: snapshot.systemImage)
                                    .font(.system(size: 13, weight: .bold))
                                    .foregroundStyle(Daybreak.ok)
                            }
                        VStack(alignment: .leading, spacing: 2) {
                            Text(snapshot.displayName)
                                .font(.system(.subheadline, design: .rounded, weight: .bold))
                                .foregroundStyle(Daybreak.ink)
                            Text("\(snapshot.ownCount.formatted()) reading\(snapshot.ownCount == 1 ? "" : "s") · \(snapshot.ownSummary)")
                                .font(.system(.caption, design: .rounded))
                                .foregroundStyle(Daybreak.mid)
                            if let other = snapshot.otherSummary {
                                Text(other)
                                    .font(.system(.caption, design: .rounded))
                                    .foregroundStyle(Daybreak.plum)
                            }
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(Daybreak.faint)
                            .padding(.top, 10)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if snapshot.id != snapshots.last?.id {
                    Divider().overlay(Daybreak.line)
                }
            }
            Text("Tap a metric for the full side-by-side charts — removal lives there too.")
                .font(.system(.caption2, design: .rounded))
                .foregroundStyle(Daybreak.faint)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .daybreakCard()
    }

    /// Opens the day-swipeable history pager on the tapped kind.
    private func open(_ snapshot: SyncEngine.DayKindSnapshot) {
        historyTarget = HistoryTarget(kindRaw: snapshot.kind?.rawValue)
    }

    // MARK: - Waiting for review

    private var stagedForDay: [StagedSession] {
        engine.staged.filter { Calendar.current.isDate($0.session.end, inSameDayAs: day) }
    }

    private var stagedBatchesForDay: [StagedMetricBatch] {
        engine.stagedMetrics.filter { Calendar.current.isDate($0.day, inSameDayAs: day) }
    }

    @ViewBuilder
    private var reviewCard: some View {
        if !stagedForDay.isEmpty || !stagedBatchesForDay.isEmpty {
            VStack(alignment: .leading, spacing: 14) {
                Text("Still waiting for review")
                    .daybreakSectionLabel()
                ForEach(stagedForDay) { item in
                    Button {
                        pushedSession = item
                    } label: {
                        reviewRow(
                            symbol: "moon.zzz.fill",
                            title: "Sleep",
                            detail: "\(item.session.start.formatted(date: .omitted, time: .shortened)) – \(item.session.end.formatted(date: .omitted, time: .shortened))"
                        )
                    }
                    .buttonStyle(.plain)
                }
                ForEach(stagedBatchesForDay) { batch in
                    Button {
                        pushedBatch = batch
                    } label: {
                        reviewRow(
                            symbol: batch.kind.systemImage,
                            title: batch.kind.displayName,
                            detail: "\(batch.samples.count.formatted()) readings · \(batch.aggregateDescription)"
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .daybreakCard()
        }
    }

    private func reviewRow(symbol: String, title: String, detail: String) -> some View {
        HStack(spacing: 12) {
            Circle()
                .fill(Daybreak.warnChipBackground)
                .frame(width: 34, height: 34)
                .overlay {
                    Image(systemName: symbol)
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(Daybreak.warn)
                }
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(.subheadline, design: .rounded, weight: .bold))
                    .foregroundStyle(Daybreak.ink)
                Text(detail)
                    .font(.system(.caption, design: .rounded))
                    .foregroundStyle(Daybreak.mid)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(Daybreak.faint)
        }
        .contentShape(Rectangle())
    }

    private var emptyCard: some View {
        VStack(spacing: 10) {
            Image(systemName: "moon.stars")
                .font(.system(size: 28))
                .foregroundStyle(Daybreak.faint)
            Text("Nothing crossed the bridge this day.")
                .font(Daybreak.bodyFont)
                .foregroundStyle(Daybreak.mid)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 26)
        .daybreakCard()
    }
}
