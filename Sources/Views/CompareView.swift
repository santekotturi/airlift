import SwiftUI

/// The Compare tab: every Watch-vs-Fitbit analysis, one row each, with the
/// headline number when the nights are already read. All three screens share
/// one read of Health (the Recovery engine), so opening any of them warms the
/// others.
struct CompareView: View {
    @Environment(AppModel.self) private var model

    private var recovery: RecoveryEngine { model.recovery }
    private var fitbitName: String { model.syncEngine.sourceDeviceName }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Compare")
                        .font(Daybreak.titleFont)
                        .foregroundStyle(Daybreak.ink)
                    Text("Your Watch against \(fitbitName), read straight from Apple Health.")
                        .font(Daybreak.bodyFont)
                        .foregroundStyle(Daybreak.mid)
                }
                .padding(.top, 8)
                VStack(alignment: .leading, spacing: 14) {
                    NavigationLink(value: SleepRoute()) {
                        row(icon: "moon.zzz.fill", title: "Sleep",
                            detail: "Total sleep and every stage, night by night.",
                            footnote: sleepHeadline)
                    }
                    Divider().overlay(Daybreak.line)
                    NavigationLink(value: HRVRoute()) {
                        row(icon: "waveform.path.ecg", title: "HRV",
                            detail: "Apple's number, your own recomputation, and Fitbit — reading by reading.",
                            footnote: hrvHeadline)
                    }
                    Divider().overlay(Daybreak.line)
                    NavigationLink(value: RecoveryRoute()) {
                        row(icon: "bed.double.fill", title: "Recovery",
                            detail: "Every metric together, restricted to the stages that carry recovery.",
                            footnote: nil)
                    }
                }
                .buttonStyle(.plain)
                .daybreakCard(padding: 16)
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 28)
        }
        .daybreakBackground()
        .toolbarBackground(.hidden, for: .navigationBar)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            if case .idle = recovery.state { await recovery.load() }
        }
    }

    /// `DaybreakNavRow`'s look without its button — the row sits inside a
    /// `NavigationLink`, which owns the tap.
    private func row(icon: String, title: String, detail: String, footnote: String?) -> some View {
        DaybreakNavRow(icon: icon, title: title, detail: detail, footnote: footnote) {}
            .allowsHitTesting(false)
    }

    private var sleepHeadline: String? {
        guard let deep = recovery.sleep.summary(.deep) else { return nil }
        return "Deep: Fitbit \(SleepCompareView.signed(deep.meanDifference)) vs Watch, across \(deep.nights) nights"
    }

    private var hrvHeadline: String? {
        guard let hrv = recovery.state.report?.hrv else { return nil }
        let summary = hrv.hasNative ? hrv.nativeOverall : hrv.publishedOverall
        guard let rho = summary.spearman else { return nil }
        return String(format: "Agreement with Fitbit ρ %.2f over %d readings", rho, summary.n)
    }
}
