import SwiftUI

/// One day's data, read back from Apple Health: what Airlift wrote (with the
/// other-sources comparison when one exists), anything still waiting for
/// review, and per-kind removal for data that looks wrong.
struct CalendarDayView: View {
    @Environment(AppModel.self) private var model

    let day: Date

    @State private var snapshots: [SyncEngine.DayKindSnapshot]?
    @State private var pendingRemoval: SyncEngine.DayKindSnapshot?
    @State private var pushedSession: StagedSession?
    @State private var pushedBatch: StagedMetricBatch?

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
        .task { snapshots = await engine.calendarSnapshot(for: day) }
        .confirmationDialog(
            "Remove \(pendingRemoval?.displayName.lowercased() ?? "this") for \(day.formatted(date: .abbreviated, time: .omitted))?",
            isPresented: Binding(
                get: { pendingRemoval != nil },
                set: { if !$0 { pendingRemoval = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Remove from Apple Health", role: .destructive) {
                guard let snapshot = pendingRemoval else { return }
                pendingRemoval = nil
                Task {
                    await engine.removeOwnData(kind: snapshot.kind, day: day)
                    snapshots = await engine.calendarSnapshot(for: day)
                }
            }
            Button("Keep it", role: .cancel) { pendingRemoval = nil }
        } message: {
            Text("Only Airlift's samples are removed — other sources stay untouched. It won't be re-imported.")
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
                            .font(.system(size: 14.5, weight: .bold, design: .rounded))
                            .foregroundStyle(Daybreak.ink)
                        Text("\(snapshot.ownCount.formatted()) reading\(snapshot.ownCount == 1 ? "" : "s") · \(snapshot.ownSummary)")
                            .font(.system(size: 12.5, design: .rounded))
                            .foregroundStyle(Daybreak.mid)
                        if let other = snapshot.otherSummary {
                            Text(other)
                                .font(.system(size: 12, design: .rounded))
                                .foregroundStyle(Daybreak.plum)
                        }
                    }
                    Spacer(minLength: 0)
                    Button {
                        pendingRemoval = snapshot
                    } label: {
                        Image(systemName: "trash")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Daybreak.fail)
                            .frame(width: 32, height: 32)
                            .background(Daybreak.failChipBackground.opacity(0.6), in: Circle())
                    }
                    .buttonStyle(.plain)
                }
                if snapshot.id != snapshots.last?.id {
                    Divider().overlay(Daybreak.line)
                }
            }
            Text("Removing takes Airlift's samples out of Apple Health for this day; other sources are never touched.")
                .font(.system(size: 11.5, design: .rounded))
                .foregroundStyle(Daybreak.faint)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .daybreakCard()
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
                    .font(.system(size: 14.5, weight: .bold, design: .rounded))
                    .foregroundStyle(Daybreak.ink)
                Text(detail)
                    .font(.system(size: 12.5, design: .rounded))
                    .foregroundStyle(Daybreak.mid)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(Daybreak.faint)
        }
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
