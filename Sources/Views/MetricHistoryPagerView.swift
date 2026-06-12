import SwiftUI

/// Day pager for one metric's history: swipe left/right to walk every day the
/// ledger says this kind landed in Apple Health, each page the full compare
/// screen. The nav bar pins which day is on screen ("Tue, Jun 9 · 3 of 14").
struct MetricHistoryPagerView: View {
    /// Nil = sleep.
    let kind: MetricKind?
    let startDay: Date

    @Environment(AppModel.self) private var model

    @State private var days: [Date] = []
    @State private var selection: Date?

    private var engine: SyncEngine { model.syncEngine }

    var body: some View {
        TabView(selection: $selection) {
            ForEach(days, id: \.self) { day in
                MetricHistoryPage(kind: kind, day: day)
                    .tag(Optional(day))
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
        .contentMargins(.top, 8, for: .scrollContent)
        .ignoresSafeArea(edges: .bottom)
        .daybreakBackground()
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .principal) { dayChip }
        }
        .onAppear(perform: loadDays)
    }

    private var dayChip: some View {
        let index = selection.flatMap { days.firstIndex(of: $0) } ?? 0
        let label = selection?.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
            ?? startDay.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
        return HStack(spacing: 6) {
            Text(label)
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .foregroundStyle(Daybreak.ink)
            if days.count > 1 {
                Text("·")
                    .foregroundStyle(Daybreak.faint)
                Text("\(index + 1) of \(days.count)")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(Daybreak.mid)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(Daybreak.card.opacity(0.8), in: Capsule())
    }

    private func loadDays() {
        guard days.isEmpty else { return }
        var found = engine.daysWithData(kind: kind)
        let start = Calendar.current.startOfDay(for: startDay)
        if !found.contains(start) {
            // The entry day should always be present, but never strand the
            // user on an empty pager if the ledger disagrees.
            found.append(start)
            found.sort()
        }
        days = found
        selection = start
    }
}

/// One day's page: loads the history model lazily, then renders the same
/// compare screen the review flow uses.
private struct MetricHistoryPage: View {
    let kind: MetricKind?
    let day: Date

    @Environment(AppModel.self) private var model

    @State private var session: StagedSession?
    @State private var batch: StagedMetricBatch?
    @State private var loaded = false

    var body: some View {
        Group {
            if let session {
                SessionCompareView(staged: session, mode: .history(day: day))
            } else if let batch {
                MetricCompareView(batch: batch, mode: .history(day: day))
            } else if loaded {
                emptyState
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: day) {
            guard !loaded else { return }
            if let kind {
                batch = await model.syncEngine.historicalBatch(kind: kind, day: day)
            } else {
                session = await model.syncEngine.historicalSession(day: day)
            }
            loaded = true
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "moon.stars")
                .font(.system(size: 28))
                .foregroundStyle(Daybreak.faint)
            Text("Nothing in Apple Health for this day.")
                .font(Daybreak.bodyFont)
                .foregroundStyle(Daybreak.mid)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
