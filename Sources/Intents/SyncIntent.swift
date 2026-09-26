import AppIntents

/// The same gated sync pass as the "Fetch now" button, exposed to Shortcuts so
/// a personal automation (wake-up alarm stopped, a time of day, charger
/// unplugged) can sync every morning without opening the app.
///
/// `openAppWhenRun` stays false: the system runs `perform()` in a background
/// launch of the app, no UI. HealthKit accepts writes while the phone is
/// locked, but reads — the Apple-data comparison checks — do not, so the
/// automation should fire at a moment the phone is in hand (alarm dismissed,
/// charger unplugged) rather than the middle of the night.
struct SyncNowIntent: AppIntent {
    static let title: LocalizedStringResource = "Sync New Data"
    static let description = IntentDescription(
        "Fetches new Google Health data and imports or stages it without opening Airlift."
    )
    static let openAppWhenRun = false

    @Parameter(title: "Notify with HRV summary", default: true)
    var notifyHRV: Bool

    static var parameterSummary: some ParameterSummary {
        Summary("Sync new data") {
            \.$notifyHRV
        }
    }

    @Dependency private var syncEngine: SyncEngine

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard syncEngine.isConnected else {
            return .result(dialog: "Airlift isn't connected — open the app and connect to Google first.")
        }
        if case .syncing = syncEngine.status {
            return .result(dialog: "A sync is already running in Airlift.")
        }

        await syncEngine.syncNow()
        // Captured before importing: a batch that imports leaves the queue, and
        // what is left afterwards is what was held back.
        let hrvNight = syncEngine.stagedMetrics
            .filter { $0.kind == .heartRateVariability }
            .max { $0.day < $1.day }
        if syncEngine.syncMode == .automatic {
            await syncEngine.autoImportClean()
        }
        if notifyHRV, syncEngine.enabledKinds.contains(.heartRateVariability) {
            await notify(hrvNight)
        }
        // The app is awake anyway — keep tomorrow's best-effort refresh booked.
        BackgroundScheduler.shared.scheduleNextRefresh()

        return .result(dialog: dialog())
    }

    @MainActor
    private func dialog() -> IntentDialog {
        switch syncEngine.status {
        case .autoSynced(let written, let held, _) where written == 0 && held == 0:
            return "Checked — nothing new."
        case .autoSynced(let written, let held, _) where held == 0:
            return "Imported \(written) item(s) into Apple Health."
        case .autoSynced(let written, let held, _):
            return "Imported \(written) item(s); \(held) held for review in Airlift."
        case .fetched(let sessions, let batches, _) where sessions == 0 && batches == 0:
            return "Checked — nothing new."
        case .fetched(let sessions, let batches, _):
            return "Fetched \(sessions) night(s) and \(batches) metric day(s) — ready for review in Airlift."
        case .needsConnection:
            return "Google sign-in expired — open Airlift to reconnect."
        case .failed(let message):
            return "Sync failed: \(message)"
        case .idle, .syncing, .success:
            return "Done."
        }
    }
}

extension SyncNowIntent {
    /// Last night's HRV, as it landed. Sign-in expiry is left to the reconnect
    /// notification, which already covers it.
    @MainActor
    fileprivate func notify(_ night: StagedMetricBatch?) async {
        let outcome: HRVSyncSummary.Outcome
        switch syncEngine.status {
        case .needsConnection:
            return
        case .failed(let message):
            outcome = .failed(message)
        default:
            if syncEngine.syncMode == .reviewEverything {
                outcome = .awaitingReview
            } else if let night, syncEngine.stagedMetrics.contains(where: { $0.id == night.id }) {
                outcome = .held
            } else {
                outcome = .imported
            }
        }
        await HRVSyncSummary.post(
            HRVSyncSummary.make(batch: night, outcome: outcome, fitbitName: syncEngine.sourceDeviceName)
        )
    }
}

/// Publishes the intent as an App Shortcut so it shows up in the Shortcuts app
/// (and Siri) without the user building anything by hand.
struct AirliftAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: SyncNowIntent(),
            phrases: [
                "Sync \(.applicationName)",
                "Sync new data with \(.applicationName)"
            ],
            shortTitle: "Sync New Data",
            systemImageName: "arrow.triangle.2.circlepath"
        )
    }
}
