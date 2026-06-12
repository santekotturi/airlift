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
                    // Review-first mode: fetch and stage on launch, write nothing.
                    // Automated write-on-sync returns once the data is trusted.
                    if model.isConfigured, model.syncEngine.isConnected {
                        await model.syncEngine.fetchForReview()
                    }
                }
        }
    }
}
