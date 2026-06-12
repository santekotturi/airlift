import SwiftUI

/// "Review all": one swipeable pager over every held item — nights first,
/// then metric days — rendering the same compare screens. Deciding an item
/// (import or skip) slides to the next; the last decision pops back home.
struct ReviewPagerView: View {
    /// One swipeable page. Immutable snapshot taken when the pager opens so
    /// pages don't reshuffle mid-swipe; decided items leave the deck instead.
    enum Page: Identifiable, Hashable {
        case session(StagedSession)
        case batch(StagedMetricBatch)

        var id: String {
            switch self {
            case .session(let item): return "session|\(item.id)"
            case .batch(let item): return "batch|\(item.id)"
            }
        }
    }

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var pages: [Page] = []
    @State private var selection: String?
    @State private var totalAtOpen = 0

    private var engine: SyncEngine { model.syncEngine }

    var body: some View {
        TabView(selection: $selection) {
            ForEach(pages) { page in
                Group {
                    switch page {
                    case .session(let item):
                        SessionCompareView(staged: item) { advance(past: page.id) }
                    case .batch(let item):
                        MetricCompareView(batch: item) { advance(past: page.id) }
                    }
                }
                .tag(Optional(page.id))
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
        .ignoresSafeArea(edges: .bottom)
        .daybreakBackground()
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .principal) {
                counterChip
            }
        }
        .onAppear(perform: loadDeck)
    }

    /// "2 of 5" — decided items shrink the denominator's remainder, so the
    /// chip always reflects what's actually left to swipe through.
    private var counterChip: some View {
        let position = pages.firstIndex { $0.id == selection }.map { $0 + 1 } ?? 1
        return Text("\(position) of \(pages.count)")
            .font(.system(size: 12, weight: .bold, design: .rounded))
            .foregroundStyle(Daybreak.mid)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(Daybreak.card.opacity(0.8), in: Capsule())
    }

    private func loadDeck() {
        guard pages.isEmpty else { return }
        pages = engine.staged.map(Page.session) + engine.stagedMetrics.map(Page.batch)
        totalAtOpen = pages.count
        selection = pages.first?.id
        if pages.isEmpty { dismiss() }
    }

    /// Removes the decided page and slides to the one that takes its place;
    /// dismisses when the deck is empty.
    private func advance(past id: String) {
        guard let index = pages.firstIndex(where: { $0.id == id }) else { return }
        var next = pages
        next.remove(at: index)
        guard !next.isEmpty else {
            dismiss()
            return
        }
        let nextSelection = next[min(index, next.count - 1)].id
        withAnimation(.snappy(duration: 0.3)) {
            pages = next
            selection = nextSelection
        }
    }
}
