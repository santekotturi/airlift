import SwiftUI

/// One night's tags and note: what's logged (tap to edit), one-tap chips for
/// the user's usual things, "Add" into the full search, and a free-text note.
/// Used on Today (tonight's log, and embedded in the last-night card) and on
/// each Journal day.
struct NightLogCard: View {
    @Environment(AppModel.self) private var model

    /// Wake day of the night being logged.
    let night: Date
    var title: String? = nil
    /// Inside another card: no card chrome of its own, a section-label title,
    /// and no quick picks — it's for adding what happened, after the fact.
    var embedded = false

    @State private var adding = false
    @State private var editing: JournalEntry?
    @State private var noteDraft = ""
    @FocusState private var noteFocused: Bool

    private var journal: JournalStore { model.journal }
    private var key: String { JournalNight.key(night) }
    private var logged: [JournalEntry] { journal.entries(night: key) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                if embedded {
                    Text(title ?? "Tags & note").daybreakSectionLabel()
                } else {
                    Text(title ?? JournalNight.label(night))
                        .font(.system(.headline, design: .rounded, weight: .bold))
                        .foregroundStyle(Daybreak.ink)
                }
                Spacer()
                Button {
                    adding = true
                } label: {
                    Label("Add", systemImage: "plus")
                        .font(.system(.subheadline, design: .rounded, weight: .semibold))
                }
                .buttonStyle(.borderedProminent)
                .tint(Daybreak.plum)
                .controlSize(.small)
            }

            if logged.isEmpty {
                Text(embedded
                     ? "Nothing logged for this night."
                     : "Nothing logged yet — add what you took or did, and Compare can line it up against your sleep.")
                    .font(Daybreak.captionFont)
                    .foregroundStyle(Daybreak.mid)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                FlowLayout(spacing: 8) {
                    ForEach(logged) { entry in
                        Button { editing = entry } label: {
                            TagChip(symbol: entry.category.symbol, text: entry.summary, style: .logged)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            let quick = embedded ? [] : quickPicks
            if !quick.isEmpty {
                Text("Your usual").daybreakSectionLabel()
                FlowLayout(spacing: 8) {
                    ForEach(quick) { item in
                        Button {
                            let dose = journal.lastDose(itemID: item.id)
                            journal.add(item, night: key, amount: dose?.amount, unit: dose?.unit)
                        } label: {
                            TagChip(symbol: "plus", text: item.name, style: .suggestion)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Add \(item.name)")
                    }
                }
            }

            TextField("Note — how you felt, anything unusual…", text: $noteDraft, axis: .vertical)
                .font(Daybreak.bodyFont)
                .lineLimit(1...5)
                .focused($noteFocused)
                .padding(10)
                .background(Daybreak.track, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .onChange(of: noteFocused) { _, focused in
                    if !focused { journal.setNote(noteDraft, night: key) }
                }
                .onSubmit { journal.setNote(noteDraft, night: key) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .modifier(CardUnlessEmbedded(embedded: embedded))
        .sensoryFeedback(.success, trigger: logged.count)
        .onAppear {
            noteDraft = journal.note(night: key)
            #if DEBUG
            // `-AirliftUIMockScreen addtag` opens the add sheet for screenshots.
            if model.isUIMock, UIMock.screen == "addtag", !embedded, title != nil { adding = true }
            #endif
        }
        .onChange(of: key) { _, newKey in noteDraft = journal.note(night: newKey) }
        .onDisappear { if noteDraft != journal.note(night: key) { journal.setNote(noteDraft, night: key) } }
        .sheet(isPresented: $adding) {
            AddTagSheet(night: night)
        }
        .sheet(item: $editing) { entry in
            EntryEditorSheet(entry: entry)
                .presentationDetents([.medium])
        }
    }

    /// Frequent items not already logged tonight — logging twice is rare
    /// enough that it should take the full Add flow.
    private var quickPicks: [TagItem] {
        let already = Set(logged.map(\.itemID))
        return journal.frequentItems(limit: 10).filter { !already.contains($0.id) }.prefix(6).map { $0 }
    }
}

private struct CardUnlessEmbedded: ViewModifier {
    let embedded: Bool

    func body(content: Content) -> some View {
        if embedded { content } else { content.daybreakCard() }
    }
}

/// Capsule tag: filled plum for what's logged, outlined for a suggestion.
struct TagChip: View {
    enum Style { case logged, suggestion }

    let symbol: String
    let text: String
    let style: Style

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .bold))
            Text(text)
                .font(.system(.footnote, design: .rounded, weight: .semibold))
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .foregroundStyle(style == .logged ? Daybreak.plum : Daybreak.mid)
        .background {
            if style == .logged {
                Capsule().fill(Daybreak.newChipBackground)
            } else {
                Capsule().strokeBorder(Daybreak.line, lineWidth: 1.5)
            }
        }
        .contentShape(Capsule())
    }
}

/// Left-to-right, wrapping rows — chips of varying width.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        let height = rows.last.map { $0.y + $0.height } ?? 0
        let width = rows.map(\.width).max() ?? 0
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for row in arrange(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: bounds.minY + row.y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
        }
    }

    private struct Row {
        var indices: [Int] = []
        var y: CGFloat = 0
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = [Row()]
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let needed = rows[rows.count - 1].indices.isEmpty ? size.width : rows[rows.count - 1].width + spacing + size.width
            if needed > width, !rows[rows.count - 1].indices.isEmpty {
                let previous = rows[rows.count - 1]
                rows.append(Row(y: previous.y + previous.height + spacing))
            }
            var row = rows[rows.count - 1]
            row.width = row.indices.isEmpty ? size.width : row.width + spacing + size.width
            row.height = max(row.height, size.height)
            row.indices.append(index)
            rows[rows.count - 1] = row
        }
        return rows.filter { !$0.indices.isEmpty }
    }
}
