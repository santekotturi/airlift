import Foundation
import HealthKit

/// Writes everything a fetch produces to `Documents/Dumps/fetch-<timestamp>/`
/// so it can be pulled off the device (Files app → AirKit, or Xcode → Devices
/// and Simulators → Download Container) and the pre-GA Google wire schemas
/// iterated against real payloads:
///
/// - `google-<dataType>-page<N>.json` — every raw API response page, verbatim
/// - `staged-sleep-<id>.json` — decoded session + Apple sleep/HR + check results
/// - `staged-<kind>-<day>.json` — decoded samples + Apple samples + check results
///
/// A decoded file with fewer items than its raw page means the wire model is
/// dropping data — diff the two to find the field that didn't decode.
///
/// No-op in release builds: dumps contain health data and only exist to debug
/// schema bring-up.
final class DumpStore: @unchecked Sendable {
    #if DEBUG
    private static let enabled = true
    #else
    private static let enabled = false
    #endif

    private let lock = NSLock()
    private var root: URL
    private var currentFolder: URL?
    private var pageCounts: [String: Int] = [:]

    init(root: URL? = nil) {
        self.root = root ?? FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Dumps", isDirectory: true)
        guard root == nil, Self.enabled else { return }
        // Prefer the iCloud Drive container so dumps reach the user's Mac
        // without cables or AirDrop (Files → iCloud Drive → AirKit → Dumps).
        // Resolving the container can block, so it happens off-main; a fetch
        // that starts first falls back to local Documents for that run.
        Task.detached(priority: .utility) { [weak self] in
            guard let container = FileManager.default.url(forUbiquityContainerIdentifier: nil) else { return }
            let dumps = container
                .appendingPathComponent("Documents", isDirectory: true)
                .appendingPathComponent("Dumps", isDirectory: true)
            self?.adoptRoot(dumps)
        }
    }

    private func adoptRoot(_ url: URL) {
        lock.lock()
        root = url
        lock.unlock()
    }

    /// Starts a fresh per-fetch folder; all writes until the next call land in it.
    func beginFetch(now: Date = Date()) {
        guard Self.enabled else { return }
        let stamp = Self.folderStampFormatter.string(from: now)
        lock.lock()
        currentFolder = root.appendingPathComponent("fetch \(stamp)", isDirectory: true)
        pageCounts = [:]
        lock.unlock()
    }

    /// Saves one raw API response page, numbered per data type within the
    /// fetch. Capped per type — the first pages prove the schema; sixty
    /// near-identical files per metric just bloat iCloud.
    func writeRawPage(_ data: Data, dataType: String) {
        guard Self.enabled else { return }
        lock.lock()
        let page = (pageCounts[dataType] ?? 0) + 1
        pageCounts[dataType] = page
        let folder = currentFolder
        lock.unlock()
        guard page <= 5 else { return }
        write(data, name: "google-\(dataType)-page\(page).json", folder: folder)
    }

    /// Saves a discovery-probe response; the HTTP status lands in the file name
    /// so a folder listing reads as a result table
    /// (`probe heart_rate HTTP404.json`).
    func writeProbe(path: String, status: Int, body: Data) {
        guard Self.enabled else { return }
        lock.lock()
        let folder = currentFolder
        lock.unlock()
        write(body, name: "probe \(Self.fileSafe(path)) HTTP\(status).json", folder: folder)
    }

    /// Saves free-form diagnostic text (e.g. a fetch error per data type).
    func writeText(_ text: String, name: String) {
        guard Self.enabled else { return }
        lock.lock()
        let folder = currentFolder
        lock.unlock()
        write(Data(text.utf8), name: name, folder: folder)
    }

    func writeStagedSession(_ item: StagedSession) {
        guard Self.enabled else { return }
        writeJSON(SleepDump(item), name: "staged-sleep-\(Self.fileSafe(item.session.id)).json")
    }

    func writeStagedBatch(_ batch: StagedMetricBatch) {
        guard Self.enabled else { return }
        let day = Self.dayFormatter.string(from: batch.day)
        writeJSON(MetricDump(batch), name: "staged-\(batch.kind.rawValue)-\(day).json")
    }

    // MARK: - File plumbing

    private func writeJSON(_ value: some Encodable, name: String) {
        lock.lock()
        let folder = currentFolder
        lock.unlock()
        guard let data = try? Self.encoder.encode(value) else { return }
        write(data, name: name, folder: folder)
    }

    private func write(_ data: Data, name: String, folder: URL?) {
        guard let folder else { return }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try data.write(to: folder.appendingPathComponent(name), options: .atomic)
        } catch {
            Log.sync.error("Dump write failed for \(name): \(error.localizedDescription)")
        }
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    /// Human-readable, sorts chronologically, and avoids `:` (illegal in file
    /// names) — e.g. `fetch 2026-06-10 09.52.59`.
    private static let folderStampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return formatter
    }()

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private static func fileSafe(_ raw: String) -> String {
        String(raw.map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "." ? $0 : "_" })
    }
}

// MARK: - Dump DTOs (dump-only shapes; domain models stay Codable-free)

private struct CheckDump: Encodable {
    let name: String
    let severity: String
    let detail: String

    init(_ check: CheckResult) {
        name = check.name
        detail = check.detail
        switch check.severity {
        case .pass: severity = "pass"
        case .info: severity = "info"
        case .warn: severity = "warn"
        case .fail: severity = "fail"
        }
    }
}

private struct SleepDump: Encodable {
    struct Stage: Encodable {
        let stage: String
        let start: Date
        let end: Date
    }

    struct AppleSegment: Encodable {
        let stage: String
        let start: Date
        let end: Date
        let source: String
    }

    struct HeartRate: Encodable {
        let time: Date
        let bpm: Double
    }

    let googleSessionID: String
    let start: Date
    let end: Date
    let stages: [Stage]
    let appleSleep: [AppleSegment]
    let appleHeartRate: [HeartRate]
    let checks: [CheckDump]

    init(_ item: StagedSession) {
        googleSessionID = item.session.id
        start = item.session.start
        end = item.session.end
        stages = item.session.stages.map {
            Stage(stage: $0.stage.rawValue, start: $0.start, end: $0.end)
        }
        appleSleep = item.appleSleep.map {
            AppleSegment(stage: $0.value.dumpLabel, start: $0.start, end: $0.end, source: $0.sourceName)
        }
        appleHeartRate = item.heartRate.map { HeartRate(time: $0.date, bpm: $0.bpm) }
        checks = item.checks.map(CheckDump.init)
    }
}

private struct MetricDump: Encodable {
    struct Sample: Encodable {
        let id: String
        let start: Date
        let end: Date
        let value: Double
    }

    struct AppleSample: Encodable {
        let start: Date
        let end: Date
        let value: Double
    }

    let kind: String
    let day: Date
    let googleSamples: [Sample]
    let appleSamples: [AppleSample]
    let checks: [CheckDump]

    init(_ batch: StagedMetricBatch) {
        kind = batch.kind.rawValue
        day = batch.day
        googleSamples = batch.samples.map {
            Sample(id: $0.id, start: $0.start, end: $0.end, value: $0.value)
        }
        appleSamples = batch.appleSamples.map {
            AppleSample(start: $0.start, end: $0.end, value: $0.value)
        }
        checks = batch.checks.map(CheckDump.init)
    }
}

private extension HKCategoryValueSleepAnalysis {
    var dumpLabel: String {
        switch self {
        case .inBed: return "inBed"
        case .awake: return "awake"
        case .asleepCore: return "asleepCore"
        case .asleepDeep: return "asleepDeep"
        case .asleepREM: return "asleepREM"
        case .asleepUnspecified: return "asleepUnspecified"
        @unknown default: return "unknown(\(rawValue))"
        }
    }
}
