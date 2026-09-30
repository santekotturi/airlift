import SwiftUI

/// Navigation token for the History ("What crossed over") screen.
struct HistoryRoute: Hashable {}

/// Navigation token for the Settings screen.
struct SettingsRoute: Hashable {}

/// Navigation token for the source-priority tutorial.
struct SourcePriorityRoute: Hashable {}

/// Navigation token for the review-all pager.
struct PagerRoute: Hashable {}

/// Daybreak shell: four tabs — Today (last night), Compare (the analyses),
/// Journal (the calendar record) and Sync (the bridge) — each a
/// `NavigationStack` with typed destinations. Every token has a Daybreak
/// (light) and Nightfall (dark) face; the user can follow the system or pin
/// either via Settings.
struct ContentView: View {
    enum Tab: Hashable {
        case today, compare, journal, sync
    }

    @Environment(AppModel.self) private var model

    @AppStorage(DaybreakAppearance.storageKey)
    private var appearanceRaw = DaybreakAppearance.system.rawValue

    @AppStorage("airlift.hasCompletedOnboarding")
    private var hasCompletedOnboarding = false

    @State private var tab = Tab.today
    @State private var comparePath = NavigationPath()
    @State private var syncPath = NavigationPath()
    @State private var appliedMockRoute = false

    // The pill is a tight fixed-proportion layout, so its icon and label
    // scale by metric — text styles alone would break the stack's balance.
    @ScaledMetric(relativeTo: .title3) private var pillIconSize: CGFloat = 20
    @ScaledMetric(relativeTo: .caption2) private var pillLabelSize: CGFloat = 11

    var body: some View {
        // Both stacks stay in the hierarchy so each tab keeps its navigation
        // state; the bar is a custom bottom-leading glass pill (Health-style)
        // rather than the system's centered one.
        ZStack(alignment: .bottomLeading) {
            ForEach([Tab.today, .compare, .journal, .sync], id: \.self) { item in
                stack(for: item)
                    .contentMargins(.bottom, 80, for: .scrollContent)
                    .opacity(tab == item ? 1 : 0)
                    .allowsHitTesting(tab == item)
            }
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
        .fullScreenCover(isPresented: Binding(
            get: { showOnboarding },
            set: { if !$0 { hasCompletedOnboarding = true } }
        )) {
            OnboardingView { hasCompletedOnboarding = true }
        }
    }

    /// First launch shows the walkthrough; under the UI mock it's only shown
    /// when explicitly requested with `-AirliftUIMockScreen onboarding`.
    private var showOnboarding: Bool {
        #if DEBUG
        if model.syncEngine.isUIMock { return UIMock.screen == "onboarding" }
        #endif
        return !hasCompletedOnboarding
    }

    @ViewBuilder
    private func stack(for tab: Tab) -> some View {
        switch tab {
        case .today: todayStack
        case .compare: compareStack
        case .journal: journalStack
        case .sync: syncStack
        }
    }

    private var todayStack: some View {
        NavigationStack {
            TodayView(
                openCompare: { select(.compare) },
                openSync: { select(.sync) }
            )
            .navigationDestination(for: SettingsRoute.self) { _ in SettingsView() }
            .navigationDestination(for: SourcePriorityRoute.self) { _ in SourcePriorityView() }
            .toolbar { settingsButton }
            .toolbarBackground(.hidden, for: .navigationBar)
        }
        .daybreakBackground()
    }

    private var compareStack: some View {
        NavigationStack(path: $comparePath) {
            CompareView()
                .navigationDestination(for: SleepRoute.self) { _ in SleepCompareView() }
                .navigationDestination(for: HRVRoute.self) { _ in HRVView() }
                .navigationDestination(for: RecoveryRoute.self) { _ in RecoveryView() }
        }
        .daybreakBackground()
    }

    private var journalStack: some View {
        NavigationStack {
            CalendarView()
                .navigationDestination(for: StagedSession.self) { SessionCompareView(staged: $0) }
                .navigationDestination(for: StagedMetricBatch.self) { MetricCompareView(batch: $0) }
        }
        .daybreakBackground()
    }

    private var syncStack: some View {
        NavigationStack(path: $syncPath) {
            SyncView()
                .navigationDestination(for: StagedSession.self) { SessionCompareView(staged: $0) }
                .navigationDestination(for: StagedMetricBatch.self) { MetricCompareView(batch: $0) }
                .navigationDestination(for: HistoryRoute.self) { _ in HistoryView() }
                .navigationDestination(for: SettingsRoute.self) { _ in SettingsView() }
                .navigationDestination(for: SourcePriorityRoute.self) { _ in SourcePriorityView() }
                .navigationDestination(for: PagerRoute.self) { _ in ReviewPagerView() }
                .toolbar { settingsButton }
                .toolbarBackground(.hidden, for: .navigationBar)
        }
        .daybreakBackground()
    }

    /// Settings opens in whichever tab asked for it.
    private var settingsButton: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            NavigationLink(value: SettingsRoute()) {
                Image(systemName: "gearshape.fill")
                    .foregroundStyle(Daybreak.mid)
            }
            .accessibilityLabel("Settings")
        }
    }

    private func select(_ target: Tab) {
        withAnimation(.snappy(duration: 0.2)) { tab = target }
    }

    // MARK: - Glass tab pill

    /// Bottom-leading floating tab switcher — Liquid Glass on iOS 26, frosted
    /// material before that — mirroring the Health app's mini toolbar.
    private var glassTabPill: some View {
        HStack(spacing: 2) {
            pillItem(.today, icon: "sun.horizon.fill", label: "Today")
            pillItem(.compare, icon: "chart.bar.xaxis", label: "Compare")
            pillItem(.journal, icon: "book.closed.fill", label: "Journal")
            pillItem(.sync, icon: "arrow.triangle.2.circlepath", label: "Sync")
        }
        .padding(5)
        .modifier(GlassPillBackground())
        .padding(.leading, 18)
        .padding(.bottom, 6)
    }

    private func pillItem(_ target: Tab, icon: String, label: String) -> some View {
        Button {
            select(target)
        } label: {
            VStack(spacing: 3) {
                Image(systemName: icon)
                    .font(.system(size: pillIconSize, weight: .semibold))
                Text(label)
                    .font(.system(size: pillLabelSize, weight: .semibold, design: .rounded))
            }
            .foregroundStyle(tab == target ? Daybreak.sunDeep : Daybreak.mid)
            .frame(width: 70, height: 58)
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
            tab = .sync
            if let held = model.syncEngine.staged.first(where: { $0.worstSeverity != .pass })
                ?? model.syncEngine.staged.first {
                syncPath.append(held)
            }
        case "metric":
            tab = .sync
            if let heartRate = model.syncEngine.stagedMetrics.first(where: { $0.kind == .heartRate }) {
                syncPath.append(heartRate)
            }
        case "sync", "home":
            tab = .sync
        case "history":
            tab = .sync
            syncPath.append(HistoryRoute())
        case "settings":
            tab = .sync
            syncPath.append(SettingsRoute())
        case "priming":
            model.syncEngine.primeNotificationsForUIMock()
        case "pager":
            tab = .sync
            syncPath.append(PagerRoute())
        case "priority":
            tab = .sync
            syncPath.append(SourcePriorityRoute())
        case "compare":
            tab = .compare
        case "recovery":
            tab = .compare
            comparePath.append(RecoveryRoute())
        case "hrv":
            tab = .compare
            comparePath.append(HRVRoute())
        case "sleep":
            tab = .compare
            comparePath.append(SleepRoute())
        case "calendar", "journal", "day", "history-pager":
            tab = .journal
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
