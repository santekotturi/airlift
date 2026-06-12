import SwiftUI

/// Navigation token for the History ("What crossed over") screen.
struct HistoryRoute: Hashable {}

/// Navigation token for the Settings screen.
struct SettingsRoute: Hashable {}

/// Navigation token for the source-priority tutorial.
struct SourcePriorityRoute: Hashable {}

/// Navigation token for the review-all pager.
struct PagerRoute: Hashable {}

/// Daybreak shell: two tabs — Home (the bridge) and Calendar (history) — each
/// a `NavigationStack` with typed destinations, on the system tab bar (Liquid
/// Glass on modern iOS, exactly like Health's Summary/Sharing bar). Every
/// token has a Daybreak (light) and Nightfall (dark) face; the user can
/// follow the system or pin either via Settings.
struct ContentView: View {
    enum Tab: Hashable {
        case home, calendar
    }

    @Environment(AppModel.self) private var model

    @AppStorage(DaybreakAppearance.storageKey)
    private var appearanceRaw = DaybreakAppearance.system.rawValue

    @State private var tab = Tab.home
    @State private var path = NavigationPath()
    @State private var appliedMockRoute = false

    var body: some View {
        // Both stacks stay in the hierarchy so each tab keeps its navigation
        // state; the bar is a custom bottom-leading glass pill (Health-style)
        // rather than the system's centered one.
        ZStack(alignment: .bottomLeading) {
            homeStack
                .contentMargins(.bottom, 80, for: .scrollContent)
                .opacity(tab == .home ? 1 : 0)
                .allowsHitTesting(tab == .home)
            calendarStack
                .contentMargins(.bottom, 80, for: .scrollContent)
                .opacity(tab == .calendar ? 1 : 0)
                .allowsHitTesting(tab == .calendar)
            glassTabPill
        }
        .tint(Daybreak.sunDeep)
        .preferredColorScheme(
            (DaybreakAppearance(rawValue: appearanceRaw) ?? .system).colorScheme
        )
        .sheet(isPresented: Binding(
            get: { model.syncEngine.needsNotificationPriming },
            set: { if !$0 { model.syncEngine.declineNotifications() } } // swipe-down = "Not now"
        )) {
            NotificationPrimerSheet()
                .presentationDetents([.fraction(0.75), .large])
                .presentationCornerRadius(32)
        }
        .onAppear(perform: applyMockRouteIfNeeded)
    }

    private var homeStack: some View {
        NavigationStack(path: $path) {
            HomeView()
                .navigationDestination(for: StagedSession.self) { SessionCompareView(staged: $0) }
                .navigationDestination(for: StagedMetricBatch.self) { MetricCompareView(batch: $0) }
                .navigationDestination(for: HistoryRoute.self) { _ in HistoryView() }
                .navigationDestination(for: SettingsRoute.self) { _ in SettingsView() }
                .navigationDestination(for: SourcePriorityRoute.self) { _ in SourcePriorityView() }
                .navigationDestination(for: PagerRoute.self) { _ in ReviewPagerView() }
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
    }

    private var calendarStack: some View {
        NavigationStack {
            CalendarView()
                .navigationDestination(for: StagedSession.self) { SessionCompareView(staged: $0) }
                .navigationDestination(for: StagedMetricBatch.self) { MetricCompareView(batch: $0) }
        }
        .daybreakBackground()
    }

    // MARK: - Glass tab pill

    /// Bottom-leading floating tab switcher — Liquid Glass on iOS 26, frosted
    /// material before that — mirroring the Health app's mini toolbar.
    private var glassTabPill: some View {
        HStack(spacing: 2) {
            pillItem(.home, icon: "sun.horizon.fill", label: "Home")
            pillItem(.calendar, icon: "calendar", label: "Calendar")
        }
        .padding(5)
        .modifier(GlassPillBackground())
        .padding(.leading, 18)
        .padding(.bottom, 6)
    }

    private func pillItem(_ target: Tab, icon: String, label: String) -> some View {
        Button {
            withAnimation(.snappy(duration: 0.2)) { tab = target }
        } label: {
            VStack(spacing: 3) {
                Image(systemName: icon)
                    .font(.system(size: 20, weight: .semibold))
                Text(label)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
            }
            .foregroundStyle(tab == target ? Daybreak.sunDeep : Daybreak.mid)
            .frame(width: 78, height: 60)
            .background {
                if tab == target {
                    Capsule().fill(Daybreak.sunDeep.opacity(0.14))
                }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityAddTraits(tab == target ? [.isSelected] : [])
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
        case "priming":
            model.syncEngine.primeNotificationsForUIMock()
        case "pager":
            path.append(PagerRoute())
        case "priority":
            path.append(SourcePriorityRoute())
        case "calendar", "day", "history-pager":
            tab = .calendar
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


/// Liquid Glass where available, frosted material as the fallback.
private struct GlassPillBackground: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.glassEffect(.regular.interactive(), in: Capsule())
        } else {
            content
                .background(.ultraThinMaterial, in: Capsule())
                .overlay(Capsule().stroke(Color.white.opacity(0.35), lineWidth: 0.5))
                .shadow(color: Color.black.opacity(0.12), radius: 14, y: 6)
        }
    }
}
