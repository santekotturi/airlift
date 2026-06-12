import Foundation
import HealthKit
import Observation

/// Composition root: wires the concrete dependencies together and owns the
/// `SyncEngine` the UI and background task drive.
@MainActor
@Observable
final class AppModel {
    let syncEngine: SyncEngine

    /// Plain-language sync history, rendered by the History screen.
    let syncLog: SyncLogStore

    /// True until the user fills in `Config.xcconfig` — the UI shows a setup
    /// hint. Forced true under the UI mock so no setup path can appear.
    let isConfigured: Bool

    /// True when launched with `-AirliftUIMock 1` (DEBUG only) — the launch
    /// fetch and background scheduling are skipped and the engine runs on
    /// seeded fixtures.
    let isUIMock: Bool

    init() {
        #if DEBUG
        let isUIMock = UIMock.isActive
        #else
        let isUIMock = false
        #endif
        self.isUIMock = isUIMock
        self.isConfigured = isUIMock || OAuthConfig.isConfigured

        let healthStore = HKHealthStore()
        let tokens = KeychainTokenStore()
        let dedup = UserDefaultsDedupStore()
        let tossed = UserDefaultsDedupStore(key: "airlift.tossedDataPointIDs")
        let state = UserDefaultsSyncState()
        let oauth = OAuthClient()
        let api = GoogleHealthClient()
        let writer = HealthKitWriter(store: healthStore)
        let reader = HealthKitReader(store: healthStore)
        // In-memory log under the mock — fixture entries must not pollute the
        // real history (the engine's mock paths skip the other stores).
        let log = SyncLogStore(defaults: isUIMock ? nil : .standard)

        self.syncLog = log
        self.syncEngine = SyncEngine(
            oauth: oauth,
            api: api,
            writer: writer,
            reader: reader,
            tokens: tokens,
            dedup: dedup,
            tossed: tossed,
            state: state,
            settings: UserDefaultsSyncSettings(),
            ledger: FileSyncLedger(),
            log: log,
            notifier: ReconnectNotifier()
        )

        #if DEBUG
        if isUIMock {
            UIMock.apply(engine: syncEngine, log: log)
        }
        #endif
    }
}
