import CoreTransferable
import Foundation
import UniformTypeIdentifiers

/// The journal as a spreadsheet: one row per night, the night's sleep from
/// both devices, and one column per thing ever logged — the shape a pivot
/// table or a pandas `groupby` wants for "deep sleep on magnesium nights vs
/// not".
enum JournalExport {
    static func csv(
        entries: [JournalEntry],
        notes: [String: String],
        sleep: SleepComparisonReport
    ) -> String {
        let sleepByNight = Dictionary(
            sleep.nights.map { (JournalNight.key($0.night), $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let entriesByNight = Dictionary(grouping: entries, by: \.night)
        let nights = Set(sleepByNight.keys).union(entriesByNight.keys).union(notes.keys).sorted()

        // One column per item, named with its unit when every entry agreed
        // on one; the cell is the night's total dose, or 1 when undosed.
        let items = Dictionary(grouping: entries, by: \.itemID)
            .map { id, group -> (id: String, header: String) in
                let units = Set(group.compactMap(\.unit))
                let name = group.max { $0.loggedAt < $1.loggedAt }?.name ?? id
                return (id, units.count == 1 ? "\(name) (\(units.first!))" : name)
            }
            .sorted { $0.header.localizedCaseInsensitiveCompare($1.header) == .orderedAscending }

        let stages: [(String, SleepMeasure)] = [
            ("total", .total), ("deep", .deep), ("rem", .rem), ("core", .core), ("awake", .awake),
        ]
        var header = ["night_ending", "note"]
        header += stages.map { "watch_\($0.0)_min" }
        header += stages.map { "fitbit_\($0.0)_min" }
        header += ["stage_agreement_pct"]
        header += items.map(\.header)

        var rows = [header.map(escape).joined(separator: ",")]
        for night in nights {
            let comparison = sleepByNight[night]
            var row = [night, notes[night] ?? ""]
            row += stages.map { stage in comparison?.watch.map { format(stage.1.minutes($0)) } ?? "" }
            row += stages.map { stage in comparison?.fitbit.map { format(stage.1.minutes($0)) } ?? "" }
            row.append(comparison?.agreement.map(format) ?? "")
            let logged = Dictionary(grouping: entriesByNight[night] ?? [], by: \.itemID)
            row += items.map { item in
                guard let group = logged[item.id] else { return "" }
                let doses = group.compactMap(\.amount)
                return doses.isEmpty ? "1" : format(doses.reduce(0, +))
            }
            rows.append(row.map(escape).joined(separator: ","))
        }
        return rows.joined(separator: "\n") + "\n"
    }

    private static func format(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0...1)).grouping(.never).locale(Locale(identifier: "en_US_POSIX")))
    }

    private static func escape(_ field: String) -> String {
        guard field.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" }) else { return field }
        return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}

/// The CSV as a shareable file ("Airlift journal.csv"), written only when the
/// user actually shares it.
struct JournalCSV: Transferable {
    let text: String

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .commaSeparatedText) { csv in
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("Airlift journal.csv")
            try Data(csv.text.utf8).write(to: url, options: .atomic)
            return SentTransferredFile(url)
        }
    }
}
