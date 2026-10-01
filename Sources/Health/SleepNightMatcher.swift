import Foundation

/// Picks out, from everything Health holds around a night, the pieces that
/// belong to it: the Watch's own night, and whether Google Health already
/// wrote Fitbit's.
///
/// Health's sleep type is shared by every app that writes it — the Watch,
/// Google Health's Fitbit sync, WHOOP, Garmin Connect, the iPhone's bedtime
/// schedule — and a query window wide enough to catch a timezone-shifted night
/// also catches naps. Summing it all is how a night read as 16 hours.
enum SleepNightMatcher {
    /// Segments further apart than this are separate sleeps (a nap, the
    /// previous night) rather than a wake-up inside one night.
    static let clusterGap: TimeInterval = 2 * 3600

    /// The Watch's night for `session`: Apple-device segments, split into
    /// separate sleeps, keeping the one that overlaps the session most. When
    /// none overlaps, the nearest — so a night shifted by a timezone bug still
    /// reaches the window-overlap check and gets flagged there.
    static func appleNight(
        _ segments: [AppleSleepSegment],
        matching session: DateInterval
    ) -> [AppleSleepSegment] {
        let groups = clusters(segments.filter(\.fromAppleDevice))
        guard !groups.isEmpty else { return [] }
        let overlapping = groups
            .map { ($0, overlap(extent($0), session)) }
            .filter { $0.1 > 0 }
        if let best = overlapping.max(by: { $0.1 < $1.1 }) { return best.0 }
        return groups.min { distance(extent($0), session) < distance(extent($1), session) } ?? []
    }

    /// The main sleep among `segments` — the cluster with the most time
    /// asleep. For reading a night back without a Fitbit session to anchor on.
    static func mainNight(_ segments: [AppleSleepSegment]) -> [AppleSleepSegment] {
        clusters(segments).max { asleep($0) < asleep($1) } ?? []
    }

    /// Whether Google Health already wrote this Fitbit session into Health.
    ///
    /// Google Health tags every sample with `HKExternalUUID` set to the Google
    /// dataPoint ID, so the match is exact. Untagged Google Health sleep falls
    /// back to overlap — at least half the session asleep — and tagged sleep
    /// from a *different* night never counts, however close it sits.
    static func googleHealthWrote(
        sessionID: String,
        session: DateInterval,
        in segments: [AppleSleepSegment],
        minOverlapFraction: Double = 0.5
    ) -> Bool {
        let google = segments.filter(\.fromGoogleHealth)
        if google.contains(where: { $0.externalID == sessionID }) { return true }
        let untagged = google.filter { $0.externalID == nil && $0.isAsleep }
        guard session.duration > 0, !untagged.isEmpty else { return false }
        let covered = union(untagged.map { DateInterval(start: $0.start, end: max($0.end, $0.start)) })
            .reduce(0) { $0 + overlap($1, session) }
        return covered / session.duration >= minOverlapFraction
    }

    // MARK: - Helpers

    static func clusters(_ segments: [AppleSleepSegment]) -> [[AppleSleepSegment]] {
        var groups: [[AppleSleepSegment]] = []
        var groupEnd = Date.distantPast
        for segment in segments.sorted(by: { $0.start < $1.start }) {
            if groups.isEmpty || segment.start.timeIntervalSince(groupEnd) > clusterGap {
                groups.append([segment])
                groupEnd = segment.end
            } else {
                groups[groups.count - 1].append(segment)
                groupEnd = max(groupEnd, segment.end)
            }
        }
        return groups
    }

    private static func extent(_ group: [AppleSleepSegment]) -> DateInterval {
        let start = group.map(\.start).min() ?? .distantPast
        return DateInterval(start: start, end: max(group.map(\.end).max() ?? start, start))
    }

    private static func asleep(_ group: [AppleSleepSegment]) -> TimeInterval {
        group.filter(\.isAsleep).reduce(0) { $0 + $1.duration }
    }

    private static func overlap(_ a: DateInterval, _ b: DateInterval) -> TimeInterval {
        max(0, min(a.end, b.end).timeIntervalSince(max(a.start, b.start)))
    }

    private static func distance(_ a: DateInterval, _ b: DateInterval) -> TimeInterval {
        if a.end < b.start { return b.start.timeIntervalSince(a.end) }
        if b.end < a.start { return a.start.timeIntervalSince(b.end) }
        return 0
    }

    private static func union(_ intervals: [DateInterval]) -> [DateInterval] {
        var merged: [DateInterval] = []
        for interval in intervals.sorted(by: { $0.start < $1.start }) {
            if let last = merged.last, interval.start <= last.end {
                merged[merged.count - 1] = DateInterval(start: last.start, end: max(last.end, interval.end))
            } else {
                merged.append(interval)
            }
        }
        return merged
    }
}
