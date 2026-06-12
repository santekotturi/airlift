import SwiftUI

/// Navigation token for the History ("What crossed over") screen.
struct HistoryRoute: Hashable {}

/// Navigation token for the Settings screen.
struct SettingsRoute: Hashable {}

/// Daybreak shell: the sky gradient behind a `NavigationStack` over Home,
/// with typed destinations so any screen can push by value. Every token has a
/// Daybreak (light) and Nightfall (dark) face; the user can follow the system
/// or pin either via Settings.
struct ContentView: View {
    @Environment(AppModel.self) private var model

    @AppStorage(DaybreakAppearance.storageKey)
    private var appearanceRaw = DaybreakAppearance.system.rawValue

    @State private var path = NavigationPath()
    @State private var appliedMockRoute = false

    var body: some View {
        NavigationStack(path: $path) {
            HomeView()
                .navigationDestination(for: StagedSession.self) { SessionCompareView(staged: $0) }
                .navigationDestination(for: StagedMetricBatch.self) { MetricCompareView(batch: $0) }
                .navigationDestination(for: HistoryRoute.self) { _ in HistoryView() }
                .navigationDestination(for: SettingsRoute.self) { _ in SettingsView() }
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            path.append(SettingsRoute())
                        } label: {
                            Image(systemName: "gearshape.fill")
                                .foregroundStyle(Daybreak.mid)
                        }
                    }
                }
                .toolbarBackground(.hidden, for: .navigationBar)
        }
        .daybreakBackground()
        .preferredColorScheme(
            (DaybreakAppearance(rawValue: appearanceRaw) ?? .system).colorScheme
        )
        .onAppear(perform: applyMockRouteIfNeeded)
    }

    /// `-AirliftUIMockScreen <name>` pre-populates the path on first appear:
    /// `session` opens the held 11.2 h night (the richer, warn-state screen),
    /// `metric` the heart-rate batch.
    private func applyMockRouteIfNeeded() {
        #if DEBUG
        guard model.syncEngine.isUIMock, !appliedMockRoute else { return }
        appliedMockRoute = true
        switch UIMock.screen {
        case "session":
            if let held = model.syncEngine.staged.first(where: { $0.worstSeverity != .pass })
                ?? model.syncEngine.staged.first {
                path.append(held)
            }
        case "metric":
            if let heartRate = model.syncEngine.stagedMetrics.first(where: { $0.kind == .heartRate }) {
                path.append(heartRate)
            }
        case "history":
            path.append(HistoryRoute())
        case "settings":
            path.append(SettingsRoute())
        default:
            break
        }
        #endif
    }
}

#if DEBUG
/// Scrollable, shareable view of a raw API payload — used to verify/fix the
/// pre-GA Google Health sleep schema against real data during bring-up.
struct RawJSONView: View {
    let json: String

    var body: some View {
        ScrollView([.vertical, .horizontal]) {
            Text(json)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle("Raw response")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ShareLink(item: json)
        }
    }
}
#endif

#Preview {
    ContentView()
        .environment(AppModel())
}
