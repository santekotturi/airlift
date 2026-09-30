import SwiftUI

/// Find something to log: type-ahead over ~650 catalog items plus the user's
/// own, or browse by category. Picking an item with a unit asks for the dose
/// (prefilled with the last one); anything else is logged in one tap. The
/// sheet stays open after each add so an evening stack goes in quickly.
struct AddTagSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    let night: Date

    @State private var query = ""
    @State private var path: [TagItem] = []
    @State private var justAdded: String?
    @FocusState private var searchFocused: Bool

    private var journal: JournalStore { model.journal }
    private var key: String { JournalNight.key(night) }

    var body: some View {
        NavigationStack(path: $path) {
            List {
                if let justAdded {
                    Label("Added \(justAdded)", systemImage: "checkmark.circle.fill")
                        .font(.system(.subheadline, design: .rounded, weight: .semibold))
                        .foregroundStyle(Daybreak.ok)
                        .listRowBackground(Daybreak.okChipBackground)
                }
                if query.trimmingCharacters(in: .whitespaces).isEmpty {
                    browse
                } else {
                    results
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(Daybreak.sky.ignoresSafeArea())
            .safeAreaInset(edge: .top) { searchField }
            .navigationTitle("Add to \(JournalNight.label(night).lowercased())")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .navigationDestination(for: TagItem.self) { item in
                DoseStep(item: item, nightLabel: JournalNight.label(night)) { amount, unit, time in
                    log(item, amount: amount, unit: unit, time: time)
                }
            }
            .navigationDestination(for: TagCategory.self) { category in
                CategoryList(category: category, pick: pick)
            }
        }
        .onAppear {
            searchFocused = true
            #if DEBUG
            if model.isUIMock, let mockQuery = UserDefaults.standard.string(forKey: "AirliftUIMockQuery") {
                query = mockQuery
            }
            #endif
        }
    }

    // MARK: - Search

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(Daybreak.faint)
            TextField("Magnesium, sauna, late dinner…", text: $query)
                .focused($searchFocused)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.done)
                .onSubmit(submitTopResult)
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(Daybreak.faint)
                }
                .accessibilityLabel("Clear search")
            }
        }
        .font(Daybreak.bodyFont)
        .padding(12)
        .background(Daybreak.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private var matches: [TagItem] {
        TagSearch.results(query, in: journal.allItems, usage: journal.usage)
    }

    @ViewBuilder
    private var results: some View {
        let matches = matches
        Section {
            ForEach(matches) { item in
                Button { pick(item) } label: { ItemRow(item: item, query: query) }
            }
            let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
            // Offered only when the text isn't already a name or alias —
            // otherwise a misspelling the catalog knows becomes a duplicate.
            let typed = TagSearch.normalize(trimmed)
            if !matches.contains(where: { item in
                ([item.name] + item.aliases).contains { TagSearch.normalize($0) == typed }
            }) {
                Button {
                    pick(journal.customItem(named: trimmed))
                } label: {
                    Label("Add “\(trimmed)” as your own tag", systemImage: "plus.circle.fill")
                        .foregroundStyle(Daybreak.plum)
                }
            }
        } footer: {
            if matches.isEmpty {
                Text("Nothing in the catalog matches — add it as your own and it'll autocomplete next time.")
            }
        }
    }

    private func submitTopResult() {
        if let first = matches.first { pick(first) }
    }

    // MARK: - Browse

    @ViewBuilder
    private var browse: some View {
        let usual = journal.frequentItems(limit: 12)
        if !usual.isEmpty {
            Section("Your usual") {
                ForEach(usual) { item in
                    Button { pick(item) } label: { ItemRow(item: item, query: "") }
                }
            }
        }
        Section("Browse") {
            ForEach(TagCategory.allCases.filter { category in
                journal.allItems.contains { $0.category == category }
            }) { category in
                NavigationLink(value: category) {
                    Label(category.displayName, systemImage: category.symbol)
                        .foregroundStyle(Daybreak.ink)
                }
            }
        }
    }

    // MARK: - Logging

    private func pick(_ item: TagItem) {
        if item.units.isEmpty {
            log(item, amount: nil, unit: nil, time: nil)
        } else {
            path.append(item)
        }
    }

    private func log(_ item: TagItem, amount: Double?, unit: String?, time: Date?) {
        journal.add(item, night: key, amount: amount, unit: unit, time: time)
        justAdded = item.name
        query = ""
        path = []
        searchFocused = true
    }
}

/// Symbol, name, category — with the alias that matched when it wasn't the
/// name ("mag gly" → Magnesium glycinate · matched "mag glycinate").
private struct ItemRow: View {
    let item: TagItem
    let query: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: item.category.symbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Daybreak.plum)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.name)
                    .font(.system(.body, design: .rounded))
                    .foregroundStyle(Daybreak.ink)
                Text(subtitle)
                    .font(.system(.caption, design: .rounded))
                    .foregroundStyle(Daybreak.mid)
            }
        }
    }

    private var subtitle: String {
        let normalized = TagSearch.normalize(query)
        if !normalized.isEmpty,
           !TagSearch.normalize(item.name).contains(normalized),
           let alias = item.aliases.first(where: { TagSearch.normalize($0).contains(normalized) }) {
            return "\(item.category.displayName) · “\(alias)”"
        }
        return item.category.displayName
    }
}

private struct CategoryList: View {
    @Environment(AppModel.self) private var model
    let category: TagCategory
    let pick: (TagItem) -> Void

    var body: some View {
        List(model.journal.allItems.filter { $0.category == category }.sorted { $0.name < $1.name }) { item in
            Button { pick(item) } label: { ItemRow(item: item, query: "") }
        }
        .navigationTitle(category.displayName)
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// Dose (prefilled with the last one logged), unit, and an optional time.
private struct DoseStep: View {
    @Environment(AppModel.self) private var model

    let item: TagItem
    let nightLabel: String
    let add: (Double?, String?, Date?) -> Void

    @State private var amountText = ""
    @State private var unit = ""
    @State private var hasTime = false
    @State private var time = Date()
    @FocusState private var amountFocused: Bool

    var body: some View {
        Form {
            Section {
                HStack {
                    TextField("Amount", text: $amountText)
                        .keyboardType(.decimalPad)
                        .focused($amountFocused)
                        .font(.system(.title2, design: .rounded, weight: .semibold))
                    if item.units.count == 1 {
                        Text(item.units[0]).foregroundStyle(Daybreak.mid)
                    }
                }
                if item.units.count > 1 {
                    Picker("Unit", selection: $unit) {
                        ForEach(item.units, id: \.self) { Text($0).tag($0) }
                    }
                    .pickerStyle(.segmented)
                }
            } header: {
                Text("How much")
            } footer: {
                Text("Optional — leave it empty to log just that you had it.")
            }
            Section {
                Toggle("Set a time", isOn: $hasTime)
                if hasTime {
                    DatePicker("Time", selection: $time, displayedComponents: .hourAndMinute)
                }
            }
            Section {
                Button {
                    add(amount, amount == nil ? nil : unit, hasTime ? time : nil)
                } label: {
                    Text("Add to \(nightLabel.lowercased())")
                        .frame(maxWidth: .infinity)
                        .font(.system(.body, design: .rounded, weight: .bold))
                }
            }
        }
        .navigationTitle(item.name)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            let last = model.journal.lastDose(itemID: item.id)
            if let amount = last?.amount {
                amountText = amount.formatted(.number.precision(.fractionLength(0...2)).grouping(.never))
            }
            unit = last?.unit.flatMap { item.units.contains($0) ? $0 : nil } ?? item.units.first ?? ""
            amountFocused = true
        }
    }

    private var amount: Double? {
        let cleaned = amountText.replacingOccurrences(of: ",", with: ".")
        guard let value = Double(cleaned), value > 0 else { return nil }
        return value
    }
}

/// Change a logged entry's dose or time, or remove it.
struct EntryEditorSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    let entry: JournalEntry

    @State private var amountText = ""
    @State private var unit = ""
    @State private var hasTime = false
    @State private var time = Date()

    private var units: [String] {
        let known = model.journal.allItems.first { $0.id == entry.itemID }?.units ?? []
        return known.isEmpty ? (entry.unit.map { [$0] } ?? []) : known
    }

    var body: some View {
        NavigationStack {
            Form {
                if !units.isEmpty {
                    Section("How much") {
                        HStack {
                            TextField("Amount", text: $amountText)
                                .keyboardType(.decimalPad)
                            if units.count == 1 { Text(units[0]).foregroundStyle(Daybreak.mid) }
                        }
                        if units.count > 1 {
                            Picker("Unit", selection: $unit) {
                                ForEach(units, id: \.self) { Text($0).tag($0) }
                            }
                            .pickerStyle(.segmented)
                        }
                    }
                }
                Section {
                    Toggle("Set a time", isOn: $hasTime)
                    if hasTime {
                        DatePicker("Time", selection: $time, displayedComponents: .hourAndMinute)
                    }
                }
                Section {
                    Button("Remove from this night", role: .destructive) {
                        model.journal.remove(entry.id)
                        dismiss()
                    }
                }
            }
            .navigationTitle(entry.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        var updated = entry
                        let value = Double(amountText.replacingOccurrences(of: ",", with: "."))
                        updated.amount = value.flatMap { $0 > 0 ? $0 : nil }
                        updated.unit = updated.amount == nil ? nil : (unit.isEmpty ? nil : unit)
                        updated.time = hasTime ? time : nil
                        model.journal.update(updated)
                        dismiss()
                    }
                }
            }
        }
        .onAppear {
            amountText = entry.amount.map { $0.formatted(.number.precision(.fractionLength(0...2)).grouping(.never)) } ?? ""
            unit = entry.unit ?? units.first ?? ""
            hasTime = entry.time != nil
            time = entry.time ?? Date()
        }
    }
}
