import SwiftUI

/// First-launch walkthrough: what Airlift does, how the review model works, and
/// the on-device privacy promise — ending in a "Get started" hand-off to the
/// Home connect card. Shown once (gated by `@AppStorage` in `ContentView`).
struct OnboardingView: View {
    /// Called when the user finishes or skips — the caller persists the flag.
    let onComplete: () -> Void

    @State private var page = 0

    private struct Page: Identifiable {
        let id = UUID()
        let symbol: String
        let tint: Color
        let title: String
        let body: String
        /// Optional feature rows shown under the body.
        var bullets: [(symbol: String, text: String)] = []
    }

    private let pages: [Page] = [
        Page(
            symbol: "shippingbox.fill",
            tint: Daybreak.sunDeep,
            title: "Welcome to Airlift",
            body: "Your Fitbit sleep and health data, carried into Apple Health — so everything you track lives in one place."
        ),
        Page(
            symbol: "moon.zzz.fill",
            tint: Daybreak.plum,
            title: "What crosses the bridge",
            body: "Last night's sleep, with full stages, plus the metrics your band records:",
            bullets: [
                ("bed.double.fill", "Sleep stages — wake, light, deep, REM"),
                ("heart.fill", "Heart rate, resting HR, HRV"),
                ("lungs.fill", "SpO₂ and respiratory rate"),
                ("figure.walk", "Steps and distance"),
            ]
        ),
        Page(
            symbol: "checkmark.seal.fill",
            tint: Daybreak.ok,
            title: "Checked, then yours",
            body: "Every reading is compared against what Apple Health already has and run through sanity checks before anything is written.",
            bullets: [
                ("wand.and.stars", "Automatic: clean data lands on its own"),
                ("hand.raised.fill", "Review everything: nothing without your OK"),
                ("arrow.uturn.backward", "Remove anything Airlift wrote, anytime"),
            ]
        ),
        Page(
            symbol: "lock.fill",
            tint: Daybreak.plum,
            title: "Private by design",
            body: "Airlift runs entirely on your iPhone. Your Google sign-in stays in the Keychain and never leaves the device — there's no server, and no account with us."
        ),
    ]

    private var isLastPage: Bool { page == pages.count - 1 }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                Button("Skip") { onComplete() }
                    .font(.system(.subheadline, design: .rounded, weight: .semibold))
                    .foregroundStyle(Daybreak.mid)
                    .opacity(isLastPage ? 0 : 1)
                    .disabled(isLastPage)
                    .accessibilityHidden(isLastPage)
            }
            .padding(.horizontal, 22)
            .padding(.top, 12)

            TabView(selection: $page) {
                ForEach(Array(pages.enumerated()), id: \.element.id) { index, page in
                    pageView(page).tag(index)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .animation(.easeInOut, value: page)

            pageDots
                .padding(.bottom, 18)

            Button(isLastPage ? "Get started" : "Continue") {
                if isLastPage {
                    onComplete()
                } else {
                    withAnimation { page += 1 }
                }
            }
            .buttonStyle(.daybreakPrimary)
            .padding(.horizontal, 22)
            .padding(.bottom, 16)
        }
        .daybreakBackground()
    }

    private func pageView(_ page: Page) -> some View {
        VStack(spacing: 22) {
            Spacer(minLength: 12)
            ZStack {
                Circle()
                    .fill(page.tint.opacity(0.14))
                    .frame(width: 116, height: 116)
                Image(systemName: page.symbol)
                    .font(.system(size: 48, weight: .semibold))
                    .foregroundStyle(page.tint)
            }
            .accessibilityHidden(true)
            VStack(spacing: 12) {
                Text(page.title)
                    .font(.system(.title, design: .rounded, weight: .bold))
                    .foregroundStyle(Daybreak.ink)
                    .multilineTextAlignment(.center)
                Text(page.body)
                    .font(.system(.body, design: .rounded))
                    .foregroundStyle(Daybreak.mid)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !page.bullets.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(page.bullets, id: \.text) { bullet in
                        HStack(spacing: 12) {
                            Image(systemName: bullet.symbol)
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(page.tint)
                                .frame(width: 26)
                            Text(bullet.text)
                                .font(.system(.subheadline, design: .rounded, weight: .medium))
                                .foregroundStyle(Daybreak.ink)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 0)
                        }
                    }
                }
                .padding(18)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Daybreak.card.opacity(0.7), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            }
            Spacer(minLength: 12)
        }
        .padding(.horizontal, 30)
    }

    private var pageDots: some View {
        HStack(spacing: 8) {
            ForEach(0..<pages.count, id: \.self) { index in
                Capsule()
                    .fill(index == page ? Daybreak.sunDeep : Daybreak.faint.opacity(0.4))
                    .frame(width: index == page ? 22 : 8, height: 8)
                    .animation(.snappy(duration: 0.25), value: page)
            }
        }
        .accessibilityHidden(true)
    }
}

#Preview {
    OnboardingView(onComplete: {})
}
