import AppIntents
import SwiftUI

@main
struct AirliftApp: App {
    @State private var model: AppModel
    @Environment(\.scenePhase) private var scenePhase

    init() {
        let model = AppModel()
        _model = State(initialValue: model)
        // The Shortcuts sync intent resolves the engine through the dependency
        // manager — registered unconditionally so an intent invocation never
        // crashes on a missing dependency (under the UI mock it just runs
        // against the fixtures).
        AppDependencyManager.shared.add(dependency: model.syncEngine)
        MorningReminder.shared.install()
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
                    await MorningReminder.shared.reschedule()
                }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active { MorningReminder.shared.runPendingShortcut() }
                }
        }
    }
}
