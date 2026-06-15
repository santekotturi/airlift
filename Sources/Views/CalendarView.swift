import SwiftUI

/// Pure month-grid math, kept view-free so it's unit-testable.
enum MonthGrid {
    /// The cells of a month laid out on a weekday grid: leading nils pad to
    /// the calendar's first weekday, then one date per day of the month.
    static func cells(for month: Date, calendar: Calendar = .current) -> [Date?] {
        guard
            let interval = calendar.dateInterval(of: .month, for: month),
            let dayCount = calendar.range(of: .day, in: .month, for: month)?.count
        else { return [] }
        let firstWeekday = calendar.component(.weekday, from: interval.start)
        let leading = (firstWeekday - calendar.firstWeekday + 7) % 7
        let days = (0..<dayCount).compactMap {
            calendar.date(byAdding: .day, value: $0, to: interval.start)
        }
        return Array(repeating: nil, count: leading) + days
    }

    /// Short weekday symbols rotated to the calendar's first weekday.
    static func weekdaySymbols(calendar: Calendar = .current) -> [String] {
        let symbols = calendar.veryShortStandaloneWeekdaySymbols
        let first = calendar.firstWeekday - 1
        return Array(symbols[first...] + symbols[..<first])
    }
}

/// Month calendar of everything that has crossed the bridge: a dot per data
/// kind on each day (colored by status), tap-through to the day's detail
/// where Airlift-written data can be compared with other sources and removed.
struct CalendarView: View {
    @Environment(AppModel.self) private var model

    @State private var month = Calendar.current.startOfDay(for: Date())
    @State private var pushedDay: Date?

    /// Day cells hold scaling text, so their height scales with it — fixed
    /// rows would clip large type sizes.
    @ScaledMetric(relativeTo: .subheadline) private var cellHeight: CGFloat = 44

    private var engine: SyncEngine { model.syncEngine }

    /// Ledger entries grouped by civil-day string, computed once per render.
    private var entriesByDay: [String: [LedgerEntry]] {
        Dictionary(grouping: engine.ledger.all, by: \.day)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                monthCard
                legendCard
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 28)
        }
        .daybreakBackground()
        .toolbarBackground(.hidden, for: .navigationBar)
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(item: $pushedDay) { CalendarDayView(day: $0) }
        #if DEBUG
        .onAppear {
            // `-AirliftUIMockScreen day` deep-links straight into today's
            // detail for screenshot runs.
            if engine.isUIMock, UIMock.screen == "day" || UIMock.screen == "history-pager", pushedDay == nil {
                pushedDay = Calendar.current.startOfDay(for: Date())
            }
        }
        #endif
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Calendar")
                .font(Daybreak.titleFont)
                .foregroundStyle(Daybreak.ink)
            Text("Every day the airlift has carried data — tap one to inspect it.")
                .font(Daybreak.bodyFont)
                .foregroundStyle(Daybreak.mid)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 8)
    }

    // MARK: - Month card

    private var monthCard: some View {
        VStack(spacing: 14) {
            monthSwitcher
            weekdayHeader
            let cells = MonthGrid.cells(for: month)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 7), spacing: 8) {
                ForEach(Array(cells.enumerated()), id: \.offset) { _, day in
                    if let day {
                        dayCell(day)
                    } else {
                        Color.clear.frame(height: cellHeight)
                    }
                }
            }
        }
        .daybreakCard()
    }

    private var monthSwitcher: some View {
        HStack {
            Button {
                month = Calendar.current.date(byAdding: .month, value: -1, to: month) ?? month
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(Daybreak.plum)
                    .frame(width: 34, height: 34)
                    .background(Daybreak.plum.opacity(0.08), in: Circle())
            }
            .accessibilityLabel("Previous month")
            Spacer()
            Text(month.formatted(.dateTime.month(.wide).year()))
                .font(.system(.body, design: .rounded, weight: .bold))
                .foregroundStyle(Daybreak.ink)
            Spacer()
            Button {
                month = Calendar.current.date(byAdding: .month, value: 1, to: month) ?? month
            } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(isCurrentMonth ? Daybreak.faint : Daybreak.plum)
                    .frame(width: 34, height: 34)
                    .background(Daybreak.plum.opacity(isCurrentMonth ? 0.04 : 0.08), in: Circle())
            }
            .accessibilityLabel("Next month")
            .disabled(isCurrentMonth)
        }
    }

    private var isCurrentMonth: Bool {
        Calendar.current.isDate(month, equalTo: Date(), toGranularity: .month)
    }

    private var weekdayHeader: some View {
        HStack(spacing: 4) {
            ForEach(MonthGrid.weekdaySymbols(), id: \.self) { symbol in
                Text(symbol)
                    .font(.system(.caption2, design: .rounded, weight: .semibold))
                    .foregroundStyle(Daybreak.faint)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    private func dayCell(_ day: Date) -> some View {
        let calendar = Calendar.current
        let isToday = calendar.isDateInToday(day)
        let isFuture = day > Date()
        let entries = entriesByDay[CivilDay.string(from: day)] ?? []
        let dots = dotColors(for: entries)

        return Button {
            if !entries.isEmpty { pushedDay = calendar.startOfDay(for: day) }
        } label: {
            VStack(spacing: 4) {
                Text(day, format: .dateTime.day())
                    .font(.system(.subheadline, design: .rounded, weight: isToday ? .heavy : .medium))
                    .foregroundStyle(isFuture ? Daybreak.faint : (isToday ? Daybreak.sunDeep : Daybreak.ink))
                HStack(spacing: 2.5) {
                    ForEach(Array(dots.enumerated()), id: \.offset) { _, color in
                        Circle().fill(color).frame(width: 4.5, height: 4.5)
                    }
                }
                .frame(height: 5)
            }
            .frame(maxWidth: .infinity)
            .frame(height: cellHeight)
            .background(
                isToday
                    ? RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Daybreak.sunDeep.opacity(0.08))
                    : nil
            )
        }
        .buttonStyle(.plain)
        .disabled(entries.isEmpty)
    }

    /// Up to four dots, in stable kind order: green for landed data, amber
    /// while held for review, gray for removed/skipped days.
    private func dotColors(for entries: [LedgerEntry]) -> [Color] {
        var colors: [Color] = []
        for entry in entries.sorted(by: { $0.kind < $1.kind }) {
            switch entry.status {
            case .synced: colors.append(Daybreak.ok)
            case .pendingReview, .quarantined: colors.append(Daybreak.warn)
            case .tossed: colors.append(Daybreak.faint)
            case .noData: continue
            }
        }
        return Array(colors.prefix(4))
    }

    private var legendCard: some View {
        HStack(spacing: 16) {
            legendEntry(Daybreak.ok, "landed")
            legendEntry(Daybreak.warn, "needs review")
            legendEntry(Daybreak.faint, "removed")
            Spacer()
        }
        .padding(.horizontal, 4)
    }

    private func legendEntry(_ color: Color, _ text: String) -> some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(text)
                .font(.system(.caption2, design: .rounded, weight: .medium))
                .foregroundStyle(Daybreak.mid)
        }
    }
}
