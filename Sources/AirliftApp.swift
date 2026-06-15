import SwiftUI

@main
struct AirliftApp: App {
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
                    // Opening the app no longer pulls from Google on its own —
                    // a launch fetch surprised users with network/battery use
                    // and writes they didn't ask for. Fetching is now always
                    // user-initiated from the home screen, which surfaces the
                    // last-checked time so the choice is informed. Background
                    // refresh stays scheduled (best-effort) and is the path
                    // we'll revisit when we design unattended sync.
                    BackgroundScheduler.shared.scheduleNextRefresh()
                }
        }
    }
}
