import SwiftUI

/// Settings tutorial: Apple Health ranks data sources, and the user — not
/// Airlift — controls that ranking. Teaches the real Health-app path
/// (data type → Data Sources & Access → Change Order) so overlapping data
/// (Fitbit steps vs iPhone steps) counts the way the user wants.
struct SourcePriorityView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL

    private var deviceName: String { model.syncEngine.sourceDeviceName }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                whyCard
                stepsCard
                airliftAngleCard
                Button("Open the Health app") {
                    if let url = URL(string: "x-apple-health://") {
                        openURL(url)
                    }
                }
                .buttonStyle(.daybreakPrimary)
                Text("Priority is a Health feature, set per data type — Airlift can't change it for you, which is exactly the point: your data, your order.")
                    .font(.system(size: 11.5, design: .rounded))
                    .foregroundStyle(Daybreak.faint)
                    .frame(maxWidth: .infinity)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 28)
        }
        .daybreakBackground()
        .toolbarBackground(.hidden, for: .navigationBar)
        .navigationBarTitleDisplayMode(.inline)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Who wins in Apple Health")
                .font(Daybreak.titleFont)
                .foregroundStyle(Daybreak.ink)
            Text("When two sources record the same thing, you decide which one counts.")
                .font(Daybreak.bodyFont)
                .foregroundStyle(Daybreak.mid)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 8)
    }

    private var whyCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Why this matters")
                .daybreakSectionLabel()
            Text("Your \(deviceName) counts steps — and so does the iPhone in your pocket. Apple Health keeps both, but for totals and charts it only counts the source highest in its priority list. Out of the box that's manual entries first, then your iPhone and Apple Watch, then apps like Airlift.")
                .font(Daybreak.bodyFont)
                .foregroundStyle(Daybreak.ink)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .daybreakCard()
    }

    private var stepsCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Change the order")
                .daybreakSectionLabel()
            step(1, "Open the Health app and search for a data type — Steps is the one most worth checking.")
            step(2, "Scroll down and tap Data Sources & Access.")
            step(3, "The list looks view-only at first — tap Edit in the top corner to unlock it.")
            step(4, "Drag handles (≡) appear next to each source that has written this data type. Touch, hold and drag Airlift where you want it.")
            step(5, "Done — the source at the top now wins whenever data overlaps. No handle next to a source just means it has no data here yet.")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .daybreakCard()
    }

    private func step(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Circle()
                .fill(Daybreak.newChipBackground)
                .frame(width: 28, height: 28)
                .overlay {
                    Text("\(number)")
                        .font(.system(size: 13, weight: .heavy, design: .rounded))
                        .foregroundStyle(Daybreak.plum)
                }
            Text(text)
                .font(.system(size: 13, design: .rounded))
                .foregroundStyle(Daybreak.ink)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }

    private var airliftAngleCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("What we'd suggest")
                .daybreakSectionLabel()
            suggestion(
                symbol: "figure.walk",
                text: "Wear only the \(deviceName)? Put Airlift at the top for Steps and Distance so the band's full day counts."
            )
            suggestion(
                symbol: "iphone",
                text: "Carry your iPhone all day too? Pick whichever you trust more — Health will quietly ignore the other when they overlap, so totals never double-count."
            )
            suggestion(
                symbol: "moon.zzz.fill",
                text: "Sleep, SpO₂ and HRV usually have no competition without an Apple Watch — priority barely matters there."
            )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .daybreakCard()
    }

    private func suggestion(symbol: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Circle()
                .fill(Daybreak.okChipBackground)
                .frame(width: 28, height: 28)
                .overlay {
                    Image(systemName: symbol)
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(Daybreak.ok)
                }
            Text(text)
                .font(.system(size: 13, design: .rounded))
                .foregroundStyle(Daybreak.ink)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }
}
