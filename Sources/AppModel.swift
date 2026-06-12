import Foundation
import HealthKit
import Observation

/// Composition root: wires the concrete dependencies together and owns the
/// `SyncEngine` the UI and background task drive.
@MainActor
@Observable
final class AppModel {
    let syncEngine: SyncEngine

    /// True until the user fills in `Config.xcconfig` — the UI shows a setup hint.
    let isConfigured = OAuthConfig.isConfigured

    init() {
        let healthStore = HKHealthStore()
        let tokens = KeychainTokenStore()
        let dedup = UserDefaultsDedupStore()
        let tossed = UserDefaultsDedupStore(key: "airkit.tossedDataPointIDs")
        let state = UserDefaultsSyncState()
        let oauth = OAuthClient()
        let api = GoogleHealthClient()
        let writer = HealthKitWriter(store: healthStore)
        let reader = HealthKitReader(store: healthStore)

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
            ledger: FileSyncLedger()
        )
    }
}
