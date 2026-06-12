import SwiftUI

/// Branded permission priming, shown right after a successful connect and
/// before iOS's own notification prompt: exactly which notifications Airlift
/// sends (one) and why it matters. "Turn on notifications" hands off to the
/// system prompt; "Not now" defers — while permission stays undetermined the
/// sheet re-offers after the next weekly reconnect.
struct NotificationPrimerSheet: View {
    @Environment(AppModel.self) private var model

    private var engine: SyncEngine { model.syncEngine }

    var body: some View {
        VStack(spacing: 18) {
            glowBell
                .padding(.top, 30)

            Text("One notification that matters")
                .font(Daybreak.numberFont(size: 26))
                .foregroundStyle(Daybreak.ink)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            Text("You're connected — the airlift is running. There's just one thing it can't recover from on its own:")
                .font(.system(size: 13, design: .rounded))
                .foregroundStyle(Daybreak.mid)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            reconnectRow

            Text("That's the only notification Airlift sends. No streaks, no summaries, no marketing.")
                .font(.system(size: 12, design: .rounded))
                .foregroundStyle(Daybreak.mid)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)

            Button("Turn on notifications") {
                Task { await engine.acceptNotifications() }
            }
            .buttonStyle(.daybreakPrimary)

            Button("Not now") {
                engine.declineNotifications()
            }
            .buttonStyle(.daybreakGhost)

            Text("iOS will confirm with its own prompt.")
                .font(.system(size: 11, design: .rounded))
                .foregroundStyle(Daybreak.faint)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Daybreak.sky.ignoresSafeArea())
        .interactiveDismissDisabled(false)
    }

    /// Bell in a glowing sun circle — same warmth as the HeadsUpCard sun.
    private var glowBell: some View {
        Circle()
            .fill(RadialGradient(
                colors: [Color(daybreakHex: 0xFFD29A), Daybreak.sunDeep],
                center: .center, startRadius: 4, endRadius: 34
            ))
            .frame(width: 64, height: 64)
            .shadow(color: Daybreak.sunDeep.opacity(0.45), radius: 16, y: 6)
            .overlay {
                Image(systemName: "bell.fill")
                    .font(.system(size: 26))
                    .foregroundStyle(.white)
            }
    }

    private var reconnectRow: some View {
        HStack(alignment: .top, spacing: 12) {
            Circle()
                .fill(Daybreak.warnChipBackground)
                .frame(width: 34, height: 34)
                .overlay {
                    Image(systemName: "key.fill")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(Daybreak.warn)
                }
            VStack(alignment: .leading, spacing: 3) {
                Text("Reconnect reminder")
                    .font(.system(size: 14.5, weight: .bold, design: .rounded))
                    .foregroundStyle(Daybreak.ink)
                Text("Google sign-ins expire about every 7 days. When yours does, syncing stops until you reconnect — this nudge is how you find out, instead of discovering missing nights later.")
                    .font(.system(size: 12.5, design: .rounded))
                    .foregroundStyle(Daybreak.mid)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .daybreakCard(padding: 16)
    }
}
