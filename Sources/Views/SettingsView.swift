import SwiftUI

/// Settings: how syncing works (the two mode option cards), appearance
/// (Daybreak/Nightfall), the Google connection, and the about block with the
/// pre-GA heads-up.
struct SettingsView: View {
    @Environment(AppModel.self) private var model

    @AppStorage(DaybreakAppearance.storageKey)
    private var appearanceRaw = DaybreakAppearance.system.rawValue

    private var engine: SyncEngine { model.syncEngine }

    private var appearance: DaybreakAppearance {
        DaybreakAppearance(rawValue: appearanceRaw) ?? .system
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Settings")
                    .font(Daybreak.titleFont)
                    .foregroundStyle(Daybreak.ink)
                    .padding(.top, 8)
                modeCard
                appearanceCard
                connectionCard
                aboutCard
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 28)
        }
        .daybreakBackground()
        .toolbarBackground(.hidden, for: .navigationBar)
        .navigationBarTitleDisplayMode(.inline)
        .sensoryFeedback(.selection, trigger: engine.syncMode)
    }

    // MARK: - Sync mode

    private var modeCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("How syncing works")
                .daybreakSectionLabel()
            ForEach(SyncMode.allCases) { mode in
                modeOption(mode)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .daybreakCard()
        .animation(.easeInOut(duration: 0.2), value: engine.syncMode)
    }

    private func modeOption(_ mode: SyncMode) -> some View {
        let isActive = engine.syncMode == mode
        return Button {
            select(mode)
        } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: isActive ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 22))
                    .foregroundStyle(isActive ? Daybreak.ok : Daybreak.faint.opacity(0.7))
                    .padding(.top, 1)
                VStack(alignment: .leading, spacing: 3) {
                    Text(mode.displayName)
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                        .foregroundStyle(Daybreak.ink)
                    Text(mode.blurb)
                        .font(.system(size: 12.5, design: .rounded))
                        .foregroundStyle(Daybreak.mid)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(14)
            .background(
                isActive ? Daybreak.okChipBackground.opacity(0.55) : Daybreak.card,
                in: RoundedRectangle(cornerRadius: 18, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(isActive ? Daybreak.ok.opacity(0.45) : Daybreak.line, lineWidth: 1.5)
            )
            .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isActive ? .isSelected : [])
    }

    private func select(_ mode: SyncMode) {
        guard engine.syncMode != mode else { return }
        engine.syncMode = mode
        // Items staged before the switch deserve the same treatment as a
        // fresh automatic pass — sweep the queue for clean ones.
        if mode == .automatic {
            Task { await engine.autoImportClean() }
        }
    }

    // MARK: - Appearance

    private var appearanceCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Appearance")
                .daybreakSectionLabel()
            ForEach(DaybreakAppearance.allCases) { option in
                appearanceOption(option)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .daybreakCard()
        .animation(.easeInOut(duration: 0.2), value: appearanceRaw)
    }

    private func appearanceOption(_ option: DaybreakAppearance) -> some View {
        let isActive = appearance == option
        return Button {
            appearanceRaw = option.rawValue
        } label: {
            HStack(spacing: 12) {
                Image(systemName: option.symbol)
                    .font(.system(size: 17))
                    .foregroundStyle(isActive ? Daybreak.sunDeep : Daybreak.faint)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text(option.displayName)
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                        .foregroundStyle(Daybreak.ink)
                    Text(option.detail)
                        .font(.system(size: 12.5, design: .rounded))
                        .foregroundStyle(Daybreak.mid)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Image(systemName: isActive ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 20))
                    .foregroundStyle(isActive ? Daybreak.ok : Daybreak.faint.opacity(0.7))
            }
            .padding(12)
            .background(
                isActive ? Daybreak.okChipBackground.opacity(0.55) : Daybreak.card,
                in: RoundedRectangle(cornerRadius: 18, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(isActive ? Daybreak.ok.opacity(0.45) : Daybreak.line, lineWidth: 1.5)
            )
            .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isActive ? .isSelected : [])
    }

    // MARK: - Connection

    private var connectionCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Connection")
                .daybreakSectionLabel()
            HStack(spacing: 10) {
                Circle()
                    .fill(connectionTint)
                    .frame(width: 9, height: 9)
                Text(connectionText)
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundStyle(Daybreak.ink)
                Spacer(minLength: 0)
            }
            if engine.isConnected {
                Button("Disconnect") {
                    engine.disconnect()
                }
                .buttonStyle(DestructiveGhostButtonStyle())
            } else {
                Button("Connect Google Health") {
                    Task { await engine.connect() }
                }
                .buttonStyle(.daybreakPrimary)
                .disabled(!model.isConfigured)
            }
            Text("While the Google Cloud project is in Testing mode, sign-ins expire weekly — reconnect when Airlift asks.")
                .font(.system(size: 12, design: .rounded))
                .foregroundStyle(Daybreak.mid)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .daybreakCard()
    }

    private var connectionTint: Color {
        if engine.isConnected { return Daybreak.ok }
        if case .needsConnection = engine.status { return Daybreak.warn }
        return Daybreak.faint
    }

    private var connectionText: String {
        if engine.isConnected { return "Connected to Google Health" }
        if case .needsConnection = engine.status {
            return "Sign-in expired — reconnect to keep the bridge open"
        }
        return "Not connected"
    }

    // MARK: - About

    private var aboutCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("About")
                .daybreakSectionLabel()
            HStack {
                Text("Version")
                    .font(Daybreak.bodyFont)
                    .foregroundStyle(Daybreak.ink)
                Spacer()
                Text(version)
                    .font(Daybreak.bodyFont)
                    .foregroundStyle(Daybreak.mid)
            }
            Divider()
                .overlay(Daybreak.line)
            HStack(spacing: 10) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(Daybreak.plum)
                Text("On-device only — your data never touches a server.")
                    .font(Daybreak.bodyFont)
                    .foregroundStyle(Daybreak.ink)
            }
            Link(destination: URL(string: "https://github.com/santekotturi/airlift")!) {
                HStack(spacing: 5) {
                    Text("README & source")
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 11, weight: .bold))
                }
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .foregroundStyle(Daybreak.plum)
            }
            HeadsUpCard.forMode(engine.syncMode)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .daybreakCard()
    }

    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0"
    }
}

/// Ghost button in the failure tint — destructive but quiet (Disconnect).
private struct DestructiveGhostButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 15, weight: .semibold, design: .rounded))
            .foregroundStyle(Daybreak.fail)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 13)
            .background(Daybreak.fail.opacity(0.08), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .opacity(configuration.isPressed ? 0.8 : 1)
    }
}
