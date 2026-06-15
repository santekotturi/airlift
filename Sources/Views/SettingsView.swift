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

    /// Disconnecting forgets the Google sign-in from the Keychain, so it
    /// asks first instead of acting on a stray tap.
    @State private var confirmingDisconnect = false

    #if DEBUG
    @State private var pushedJSONKey: String?
    #endif

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
                deviceCard
                priorityCard
                aboutCard
                #if DEBUG
                debugCard
                #endif
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 28)
        }
        .daybreakBackground()
        .toolbarBackground(.hidden, for: .navigationBar)
        .navigationBarTitleDisplayMode(.inline)
        .sensoryFeedback(.selection, trigger: engine.syncMode)
        #if DEBUG
        .navigationDestination(item: $pushedJSONKey) { key in
            RawJSONView(json: engine.lastRawJSON[key] ?? "")
                .navigationTitle(key)
        }
        #endif
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
                        .font(.system(.subheadline, design: .rounded, weight: .bold))
                        .foregroundStyle(Daybreak.ink)
                    Text(mode.blurb)
                        .font(.system(.caption, design: .rounded))
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
                        .font(.system(.subheadline, design: .rounded, weight: .bold))
                        .foregroundStyle(Daybreak.ink)
                    Text(option.detail)
                        .font(.system(.caption, design: .rounded))
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
                    .font(.system(.subheadline, design: .rounded, weight: .semibold))
                    .foregroundStyle(Daybreak.ink)
                Spacer(minLength: 0)
            }
            if engine.isConnected {
                Button("Disconnect") {
                    confirmingDisconnect = true
                }
                .buttonStyle(.daybreakDestructiveGhost)
                .confirmationDialog(
                    "Disconnect from Google Health?",
                    isPresented: $confirmingDisconnect,
                    titleVisibility: .visible
                ) {
                    Button("Disconnect", role: .destructive) {
                        engine.disconnect()
                    }
                    Button("Stay connected", role: .cancel) {}
                } message: {
                    Text("Airlift forgets your Google sign-in on this iPhone. Everything already in Apple Health stays put.")
                }
            } else {
                Button("Connect Google Health") {
                    Task { await engine.connect() }
                }
                .buttonStyle(.daybreakPrimary)
                .disabled(!model.isConfigured)
            }
            Text("While the Google Cloud project is in Testing mode, sign-ins expire weekly — reconnect when Airlift asks.")
                .font(.system(.caption, design: .rounded))
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

    // MARK: - Source priority

    /// Entry point for the "who wins in Apple Health" tutorial — the lever
    /// users actually have over overlapping data lives in the Health app.
    private var priorityCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Your data in Apple Health")
                .daybreakSectionLabel()
            Text("When the \(engine.sourceDeviceName) and your iPhone both record the same thing, Apple Health lets you choose which source wins.")
                .font(Daybreak.bodyFont)
                .foregroundStyle(Daybreak.ink)
                .fixedSize(horizontal: false, vertical: true)
            NavigationLink(value: SourcePriorityRoute()) {
                HStack(spacing: 5) {
                    Text("Learn how to set source priority")
                    Image(systemName: "arrow.right")
                        .font(.system(.caption2, weight: .bold))
                }
                .font(.system(.subheadline, design: .rounded, weight: .semibold))
                .foregroundStyle(Daybreak.plum)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .daybreakCard()
    }

    // MARK: - About

    // MARK: - Device

    /// Detected from the API when Google sends device info; editable because
    /// pre-GA payloads rarely name the hardware.
    private var deviceCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Your device")
                .daybreakSectionLabel()
            TextField(
                engine.detectedDeviceLabel ?? DeviceLabel.fallback,
                text: Binding(
                    get: { engine.deviceNameOverride ?? "" },
                    set: { engine.deviceNameOverride = $0.isEmpty ? nil : $0 }
                )
            )
            .font(Daybreak.bodyFont)
            .foregroundStyle(Daybreak.ink)
            .textFieldStyle(.plain)
            .padding(12)
            .background(Daybreak.track, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            Text(deviceCardFootnote)
                .font(.system(.caption, design: .rounded))
                .foregroundStyle(Daybreak.mid)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .daybreakCard()
    }

    private var deviceCardFootnote: String {
        if let detected = engine.detectedDeviceLabel {
            return "Detected \u{201c}\(detected)\u{201d} from Google. Set a name here to override how it appears in Airlift and on new Apple Health samples."
        }
        return "Google isn't naming your device yet (pre-release API). Set a name — like \u{201c}Fitbit Air\u{201d} — and Airlift will use it everywhere, including new Apple Health samples."
    }

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
                        .font(.system(.caption2, weight: .bold))
                }
                .font(.system(.subheadline, design: .rounded, weight: .semibold))
                .foregroundStyle(Daybreak.plum)
            }
            HeadsUpCard.forMode(engine.syncMode)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .daybreakCard()
    }

    // MARK: - Debug

    #if DEBUG
    @ViewBuilder
    private var debugCard: some View {
        if !engine.lastRawJSON.isEmpty {
            VStack(alignment: .leading, spacing: 14) {
                Text("Debug — raw payloads")
                    .daybreakSectionLabel()
                let keys = engine.lastRawJSON.keys.sorted()
                ForEach(keys, id: \.self) { key in
                    Button {
                        pushedJSONKey = key
                    } label: {
                        HStack {
                            Text(key)
                                .font(.system(.subheadline, design: .rounded, weight: .semibold))
                                .foregroundStyle(Daybreak.ink)
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(Daybreak.faint)
                        }
                    }
                    .buttonStyle(.plain)
                    if key != keys.last {
                        Divider().overlay(Daybreak.line)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .daybreakCard()
        }
    }
    #endif

    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0"
    }
}

