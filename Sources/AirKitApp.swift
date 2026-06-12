import SwiftUI

@main
struct AirKitApp: App {
    @State private var model: AppModel

    init() {
        let model = AppModel()
        _model = State(initialValue: model)
        // BGTaskScheduler requires handler registration *before* the app
        // finishes launching — doing this in a view's .task is too late and
        // the task would never fire.
        BackgroundScheduler.shared.register(syncEngine: model.syncEngine)
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(model)
                .task {
                    BackgroundScheduler.shared.scheduleNextRefresh()
                    // On-launch sync is the real freshness guarantee —
                    // BGAppRefreshTask is best-effort. The engine gates writes
                    // by the configured sync mode (review-everything stages
                    // and writes nothing, matching the old launch behavior).
                    if model.isConfigured, model.syncEngine.isConnected {
                        await model.syncEngine.syncNow()
                    }
                }
        }
    }
}
