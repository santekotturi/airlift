import SwiftUI

/// Journal → metric history pager entry (newest day, swipe back from there).
struct BrowseTarget: Hashable, Identifiable {
    let kindRaw: String?
    let startDay: Date
    var id: String { kindRaw ?? "sleep" }
    var kind: MetricKind? { kindRaw.flatMap(MetricKind.init) }
}

/// One row per data kind Airlift has ever landed in Apple Health — tapping
/// opens the day-swipeable history on its newest day. Empty (renders nothing)
/// until something has synced.
struct YourMetricsCard: View {
    @Environment(AppModel.self) private var model
    let onSelect: (BrowseTarget) -> Void

    private var engine: SyncEngine { model.syncEngine }

    private struct Row: Identifiable {
        let kindRaw: String?
        let name: String
        let symbol: String
        let dayCount: Int
        let newestDay: Date
        var id: String { kindRaw ?? "sleep" }

        /// "18 nights of sleep" / "20 days of heart rate" — what the count
        /// actually counts.
        var countLine: String {
            guard let kindRaw else {
                return "\(dayCount) night\(dayCount == 1 ? "" : "s") of sleep synced"
            }
            let noun = MetricKind(rawValue: kindRaw)?.inlineName ?? name.lowercased()
            return "\(dayCount) day\(dayCount == 1 ? "" : "s") of \(noun) synced"
        }
    }

    private var rows: [Row] {
        var rows: [Row] = []
        let sleepDays = engine.daysWithData(kind: nil)
        if let newest = sleepDays.last {
            rows.append(Row(kindRaw: nil, name: "Sleep", symbol: "moon.zzz.fill", dayCount: sleepDays.count, newestDay: newest))
        }
        for kind in MetricKind.allCases {
            let days = engine.daysWithData(kind: kind)
            guard let newest = days.last else { continue }
            rows.append(Row(kindRaw: kind.rawValue, name: kind.displayName, symbol: kind.systemImage, dayCount: days.count, newestDay: newest))
        }
        return rows
    }

    var body: some View {
        let rows = rows
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text("Synced by Airlift").daybreakSectionLabel()
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(rows) { row in
                        DaybreakNavRow(
                            icon: row.symbol,
                            title: row.name,
                            detail: row.countLine,
                            footnote: "Newest · \(row.newestDay.formatted(date: .abbreviated, time: .omitted))"
                        ) {
                            onSelect(BrowseTarget(kindRaw: row.kindRaw, startDay: row.newestDay))
                        }
                        if row.id != rows.last?.id {
                            Divider().overlay(Daybreak.line)
                        }
                    }
                }
                .daybreakCard(padding: 16)
            }
        }
    }
}
