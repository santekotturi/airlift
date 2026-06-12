import Foundation
import BackgroundTasks

/// Schedules and handles the daily background sync via `BGAppRefreshTask`.
///
/// BGAppRefreshTask timing is best-effort — iOS may not fire it daily. The real
/// guarantees are the on-launch sync and the manual "Sync now" button (PRD §9);
/// this is the nice-to-have automatic path.
@MainActor
final class BackgroundScheduler {
    static let shared = BackgroundScheduler()

    /// Must match `BGTaskSchedulerPermittedIdentifiers` in Info.plist.
    static let taskIdentifier = "com.santekotturi.airkit.sync"

    private weak var syncEngine: SyncEngine?
    private var didRegister = false

    private init() {}

    /// Registers the launch handler. Call once, early in app startup, before the
    /// app finishes launching.
    func register(syncEngine: SyncEngine) {
        self.syncEngine = syncEngine
        guard !didRegister else { return }
        didRegister = true

        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: Self.taskIdentifier,
            using: nil
        ) { [weak self] task in
            guard let refreshTask = task as? BGAppRefreshTask else { return }
            self?.handle(refreshTask)
        }
    }

    /// Schedules the next refresh for the early morning, after a night's sleep has
    /// finalized and synced from the band.
    func scheduleNextRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: Self.taskIdentifier)
        request.earliestBeginDate = Self.nextEarlyMorning()
        do {
            try BGTaskScheduler.shared.submit(request)
            Log.background.info("Scheduled next background refresh")
        } catch {
            // Common in the Simulator / when disabled in Settings — not fatal.
            Log.background.notice("Could not schedule background refresh: \(error.localizedDescription)")
        }
    }

    private func handle(_ task: BGAppRefreshTask) {
        // Always schedule the following day's run first.
        scheduleNextRefresh()

        // setTaskCompleted must be called exactly once, but both the work task
        // and the expiration handler are completion paths — gate with a flag.
        let completion = TaskCompletionGuard(task)

        let work = Task { @MainActor in
            // Gated by the configured sync mode: review-everything only stages,
            // automatic imports what the sanity checks trust. The sweep then
            // clears clean items left over from review-everything sessions —
            // same pairing as the on-launch path.
            await syncEngine?.syncNow()
            if syncEngine?.syncMode == .automatic {
                await syncEngine?.autoImportClean()
            }
            let success: Bool
            if case .failed = syncEngine?.status { success = false } else { success = true }
            completion.complete(success: success)
        }

        // If the OS reclaims our time, cancel and report incomplete so it retries.
        task.expirationHandler = {
            work.cancel()
            completion.complete(success: false)
        }
    }

    /// Ensures `setTaskCompleted` is called exactly once even when multiple
    /// completion paths race. The expiration handler runs off the main queue,
    /// so this is lock-guarded rather than actor-isolated.
    private final class TaskCompletionGuard: @unchecked Sendable {
        private let task: BGAppRefreshTask
        private let lock = NSLock()
        private var completed = false

        init(_ task: BGAppRefreshTask) {
            self.task = task
        }

        func complete(success: Bool) {
            lock.withLock {
                guard !completed else { return }
                completed = true
                task.setTaskCompleted(success: success)
            }
        }
    }

    private static func nextEarlyMorning(hour: Int = 7) -> Date {
        let calendar = Calendar.current
        let now = Date()
        let next = calendar.nextDate(
            after: now,
            matching: DateComponents(hour: hour, minute: 0),
            matchingPolicy: .nextTime
        )
        // Fall back to ~24h out if the matcher can't resolve.
        return next ?? now.addingTimeInterval(24 * 3600)
    }
}
