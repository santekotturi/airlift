import SwiftUI

/// In-app bug reporting that opens a prefilled GitHub issue on the public repo.
/// No token, no server: the report is composed locally and handed to GitHub in
/// the browser, where the user reviews and submits it. Only versions and the
/// device model are attached — never health data or the Google sign-in.
struct BugReportView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    @State private var summary = ""
    @State private var whatHappened = ""
    @State private var steps = ""

    private var canSubmit: Bool {
        !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text("Tell us what went wrong. This opens a prefilled issue on GitHub for you to review and post — you'll need a free GitHub account.")
                        .font(.system(.subheadline, design: .rounded))
                        .foregroundStyle(Daybreak.mid)
                        .fixedSize(horizontal: false, vertical: true)

                    field(
                        label: "Summary",
                        hint: "A short title — e.g. \u{201c}Sleep didn't sync after travel\u{201d}",
                        text: $summary,
                        minHeight: 44
                    )
                    field(
                        label: "What happened",
                        hint: "What did you see? What did you expect?",
                        text: $whatHappened,
                        minHeight: 100
                    )
                    field(
                        label: "Steps to reproduce (optional)",
                        hint: "1. \u{2026}\n2. \u{2026}",
                        text: $steps,
                        minHeight: 80
                    )

                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "lock.fill")
                            .font(.system(size: 13))
                            .foregroundStyle(Daybreak.plum)
                            .padding(.top, 1)
                        Text("Attached: app version and your device model (\(AppInfo.deviceModelIdentifier), iOS \(UIDevice.current.systemVersion)). No health data or sign-in is included.")
                            .font(.system(.caption, design: .rounded))
                            .foregroundStyle(Daybreak.mid)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Button("Continue to GitHub") { submit() }
                        .buttonStyle(.daybreakPrimary)
                        .disabled(!canSubmit)
                        .opacity(canSubmit ? 1 : 0.5)
                }
                .padding(20)
            }
            .daybreakBackground()
            .navigationTitle("Report a bug")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }

    private func field(label: String, hint: String, text: Binding<String>, minHeight: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(label)
                .daybreakSectionLabel()
            ZStack(alignment: .topLeading) {
                if text.wrappedValue.isEmpty {
                    Text(hint)
                        .font(.system(.subheadline, design: .rounded))
                        .foregroundStyle(Daybreak.faint)
                        .padding(.horizontal, 13)
                        .padding(.vertical, 12)
                        .allowsHitTesting(false)
                }
                TextEditor(text: text)
                    .font(.system(.subheadline, design: .rounded))
                    .foregroundStyle(Daybreak.ink)
                    .scrollContentBackground(.hidden)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .frame(minHeight: minHeight)
            }
            .background(Daybreak.track, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
    }

    private func submit() {
        let title = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        var body = ""
        let happened = whatHappened.trimmingCharacters(in: .whitespacesAndNewlines)
        if !happened.isEmpty {
            body += "**What happened**\n\(happened)\n\n"
        }
        let repro = steps.trimmingCharacters(in: .whitespacesAndNewlines)
        if !repro.isEmpty {
            body += "**Steps to reproduce**\n\(repro)\n\n"
        }
        body += AppInfo.diagnosticsBlock

        guard let url = AppInfo.newIssueURL(title: title, body: body) else { return }
        openURL(url)
        dismiss()
    }
}

#Preview {
    BugReportView()
}
