import Foundation
import CryptoKit

/// Remembers what each imported sleep session *looked like* when it was
/// written to HealthKit, so the re-pull window can detect upstream edits.
///
/// The dedup store alone can't: it only remembers IDs, and Google keeps the
/// dataPoint ID when a session is edited (re-staged sleep, corrected stages).
/// Comparing the stored fingerprint against the re-fetched session's content
/// is what makes the delete-then-rewrite path in `HealthKitWriter.write`
/// reachable — without it, an imported ID is filtered out before staging and
/// edits never propagate.
protocol SessionFingerprintStoring: Sendable {
    func fingerprint(for id: String) -> String?
    func record(_ fingerprint: String, for id: String)
}

extension SleepSession {
    /// Deterministic digest of everything that affects what gets written to
    /// HealthKit. Stable across launches (unlike `Hashable`, which is
    /// randomly seeded per process).
    var contentFingerprint: String {
        var text = "\(start.timeIntervalSinceReferenceDate)|\(end.timeIntervalSinceReferenceDate)"
        for segment in stages.sorted(by: { ($0.start, $0.stage.rawValue) < ($1.start, $1.stage.rawValue) }) {
            text += "|\(segment.stage.rawValue),\(segment.start.timeIntervalSinceReferenceDate),\(segment.end.timeIntervalSinceReferenceDate)"
        }
        let digest = SHA256.hash(data: Data(text.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

final class UserDefaultsSessionFingerprintStore: SessionFingerprintStoring, @unchecked Sendable {
    private let defaults: UserDefaults
    private let key: String
    private let lock = NSLock()

    init(defaults: UserDefaults = .standard, key: String = "airlift.sessionFingerprints") {
        self.defaults = defaults
        self.key = key
    }

    func fingerprint(for id: String) -> String? {
        lock.withLock {
            (defaults.dictionary(forKey: key) as? [String: String])?[id]
        }
    }

    func record(_ fingerprint: String, for id: String) {
        lock.withLock {
            var map = defaults.dictionary(forKey: key) as? [String: String] ?? [:]
            map[id] = fingerprint
            defaults.set(map, forKey: key)
        }
    }
}

/// Non-persisting store — UI-mock runs and tests.
final class InMemorySessionFingerprintStore: SessionFingerprintStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var map: [String: String] = [:]

    init() {}

    func fingerprint(for id: String) -> String? {
        lock.withLock { map[id] }
    }

    func record(_ fingerprint: String, for id: String) {
        lock.withLock { map[id] = fingerprint }
    }
}
