import SwiftUI

@main
struct AirKitApp: App {
    @State private var model: AppModel

    init() {
        let model = AppModel()
        _model = State(initialValue: model)
        // BGTaskScheduler requires handler registration *before* the app
        // finishes launching — doing this in a view's .task is too late and
        // the task would never fire. Skipped under the UI mock so no real
        // sync can run against the fixtures.
        if !model.isUIMock {
            BackgroundScheduler.shared.register(syncEngine: model.syncEngine)
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(model)
                .task {
                    guard !model.isUIMock else { return }
                    BackgroundScheduler.shared.scheduleNextRefresh()
                    // On-launch sync is the real freshness guarantee —
                    // BGAppRefreshTask is best-effort. The engine gates writes
                    // by the configured sync mode (review-everything stages
                    // and writes nothing, matching the old launch behavior);
                    // the sweep then clears clean leftovers staged under a
                    // previous review-everything session.
                    if model.isConfigured, model.syncEngine.isConnected {
                        await model.syncEngine.syncNow()
                        if model.syncEngine.syncMode == .automatic {
                            await model.syncEngine.autoImportClean()
                        }
                    }
                }
        }
    }
}
