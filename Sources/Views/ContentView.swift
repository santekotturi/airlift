import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var model

    private var engine: SyncEngine { model.syncEngine }

    var body: some View {
        NavigationStack {
            List {
                if !model.isConfigured {
                    setupHintSection
                }
                statusSection
                pipelineSection
                actionsSection
                reviewSection
                metricReviewSection
                #if DEBUG
                debugSection
                #endif
            }
            .navigationTitle("AirKit")
        }
    }

    // MARK: - Sections

    private var statusSection: some View {
        Section("Status") {
            HStack(spacing: 12) {
                statusIcon
                VStack(alignment: .leading, spacing: 2) {
                    Text(statusTitle)
                        .font(.headline)
                        .contentTransition(.opacity)
                    if let detail = statusDetail {
                        Text(detail).font(.subheadline).foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.vertical, 4)
            .animation(.easeInOut(duration: 0.2), value: statusTitle)
        }
    }

    // MARK: - Fetch pipeline

    /// Live per-data-type progress while a fetch runs: queued → fetching
    /// (page n) → comparing vs Apple Health → ✓ staged.
    @ViewBuilder
    private var pipelineSection: some View {
        if isSyncing && !engine.pipeline.isEmpty {
            Section("Progress") {
                ForEach(engine.pipeline) { item in
                    HStack(spacing: 10) {
                        pipelineIcon(item.step)
                            .frame(width: 22)
                        Text(item.name).font(.subheadline)
                        Spacer()
                        Text(pipelineLabel(item.step))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .contentTransition(.opacity)
                    }
                }
            }
            .animation(.easeInOut(duration: 0.2), value: engine.pipeline)
        }
    }

    @ViewBuilder
    private func pipelineIcon(_ step: PipelineItem.Step) -> some View {
        switch step {
        case .waiting:
            Image(systemName: "circle.dotted").foregroundStyle(.tertiary)
        case .fetching:
            Image(systemName: "arrow.down.circle")
                .foregroundStyle(.blue)
                .symbolEffect(.pulse)
        case .comparing:
            Image(systemName: "chart.bar.xaxis")
                .foregroundStyle(.orange)
                .symbolEffect(.pulse)
        case .done:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed:
            Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
        }
    }

    private func pipelineLabel(_ step: PipelineItem.Step) -> String {
        switch step {
        case .waiting: return "queued"
        case .fetching(let page): return page > 1 ? "fetching · page \(page)" : "fetching…"
        case .comparing: return "comparing vs Apple…"
        case .done(let staged): return staged == 0 ? "nothing new" : "\(staged) staged ✓"
        case .failed: return "failed — see Debug"
        }
    }

    private var actionsSection: some View {
        Section {
            if engine.isConnected {
                Menu {
                    ForEach([7, 14, 30], id: \.self) { days in
                        Button("Last \(days) days") {
                            Task { await engine.fetchForReview(days: days) }
                        }
                    }
                } label: {
                    Label("Fetch from Google", systemImage: "arrow.down.circle")
                } primaryAction: {
                    Task { await engine.fetchForReview() }
                }
                .disabled(isSyncing || !model.isConfigured)

                Button(role: .destructive) {
                    engine.disconnect()
                } label: {
                    Label("Disconnect", systemImage: "xmark.circle")
                }
            } else {
                Button {
                    Task { await engine.connect() }
                } label: {
                    Label("Connect Google Health", systemImage: "link")
                }
                .disabled(!model.isConfigured)
            }
        } footer: {
            if engine.isConnected {
                Text("Fetching stages sessions for review — nothing is written to Apple Health until you import it.")
            }
        }
    }

    // MARK: - Review queue

    /// Staged sessions grouped by wake-up day, newest first.
    private var groupedStaged: [(day: Date, items: [StagedSession])] {
        let groups = Dictionary(grouping: engine.staged) {
            Calendar.current.startOfDay(for: $0.session.end)
        }
        return groups.keys.sorted(by: >).map { (day: $0, items: groups[$0]!) }
    }

    @ViewBuilder
    private var reviewSection: some View {
        if engine.staged.isEmpty {
            Section("Review queue") {
                Text(engine.isConnected
                     ? "No sessions waiting for review. Fetch to check for new nights."
                     : "Connect, then fetch to stage sessions for review.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        } else {
            ForEach(groupedStaged, id: \.day) { group in
                Section(group.day.formatted(date: .complete, time: .omitted)) {
                    ForEach(group.items) { item in
                        NavigationLink {
                            SessionCompareView(staged: item)
                        } label: {
                            stagedRow(item)
                        }
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                engine.toss(item.id)
                            } label: {
                                Label("Toss", systemImage: "trash")
                            }
                        }
                    }
                }
            }
        }
    }

    private func stagedRow(_ item: StagedSession) -> some View {
        HStack(spacing: 12) {
            Image(systemName: item.worstSeverity.iconName)
                .foregroundStyle(item.worstSeverity.iconColor)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(item.session.start.formatted(date: .omitted, time: .shortened)) – \(item.session.end.formatted(date: .omitted, time: .shortened))")
                    .font(.subheadline.weight(.medium))
                HStack(spacing: 6) {
                    let hours = item.session.end.timeIntervalSince(item.session.start) / 3600
                    Text(String(format: "%.1f h", hours))
                    if item.appleSleep.isEmpty {
                        Text("· no Apple data")
                    } else {
                        Text("· Apple ✓")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Metric review queue

    @ViewBuilder
    private var metricReviewSection: some View {
        if !engine.stagedMetrics.isEmpty {
            Section("Metrics to review") {
                ForEach(engine.stagedMetrics) { batch in
                    NavigationLink {
                        MetricCompareView(batch: batch)
                    } label: {
                        metricRow(batch)
                    }
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) {
                            engine.tossMetricBatch(batch.id)
                        } label: {
                            Label("Toss", systemImage: "trash")
                        }
                    }
                }
            }
        }
    }

    private func metricRow(_ batch: StagedMetricBatch) -> some View {
        HStack(spacing: 12) {
            Image(systemName: batch.worstSeverity.iconName)
                .foregroundStyle(batch.worstSeverity.iconColor)
            Image(systemName: batch.kind.systemImage)
                .foregroundStyle(.secondary)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(batch.kind.displayName)
                    .font(.subheadline.weight(.medium))
                HStack(spacing: 6) {
                    Text(batch.day.formatted(date: .abbreviated, time: .omitted))
                    Text("· \(batch.samples.count) pts · \(batch.aggregateDescription)")
                    if batch.appleSamples.isEmpty {
                        Text("· no Apple data")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
    }

    private var setupHintSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                Label("Not configured", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.headline)
                Text("Copy Config.example.xcconfig to Config.xcconfig and add your Google Cloud iOS OAuth client ID, then rebuild. See the README.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)
        }
    }

    #if DEBUG
    @ViewBuilder
    private var debugSection: some View {
        Section {
            if engine.lastRawJSON.isEmpty {
                Text("Run a fetch to capture raw API payloads here.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(engine.lastRawJSON.keys.sorted(), id: \.self) { key in
                    NavigationLink(key) {
                        RawJSONView(json: engine.lastRawJSON[key] ?? "")
                            .navigationTitle(key)
                    }
                }
            }
        } header: {
            Text("Debug — raw API payloads")
        } footer: {
            Text("Every fetch also writes raw pages + staged data to Files → On My iPhone → AirKit → Dumps (or pull the app container via Xcode → Devices and Simulators).")
        }
    }
    #endif

    // MARK: - Status presentation

    private var isSyncing: Bool {
        if case .syncing = engine.status { return true }
        return false
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch engine.status {
        case .syncing:
            ProgressView()
        case .fetched:
            Image(systemName: "tray.full.fill").foregroundStyle(.blue).font(.title2)
        case .success:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).font(.title2)
        case .failed:
            Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.red).font(.title2)
        case .needsConnection:
            Image(systemName: "link.badge.plus").foregroundStyle(.orange).font(.title2)
        case .idle:
            Image(systemName: "moon.zzz.fill").foregroundStyle(.indigo).font(.title2)
        }
    }

    private var statusTitle: String {
        switch engine.status {
        case .idle: return engine.isConnected ? "Ready" : "Not connected"
        case .syncing(let phase): return phase
        case .fetched(let sessions, let metrics, _):
            return (sessions + metrics) == 0 ? "Nothing new" : "\(sessions) night(s) + \(metrics) metric batch(es) to review"
        case .success: return "Imported"
        case .failed: return "Fetch failed"
        case .needsConnection: return "Reconnect needed"
        }
    }

    private var statusDetail: String? {
        switch engine.status {
        case .fetched(_, _, let date):
            return "Fetched \(date.formatted(date: .abbreviated, time: .shortened))"
        case .success(let date, let written):
            return "Wrote \(written) item(s) · \(date.formatted(date: .abbreviated, time: .shortened))"
        case .failed(let message):
            return message
        case .needsConnection:
            return "Your Google sign-in expired or was revoked."
        case .idle where !engine.isConnected:
            return "Connect your Google account to begin."
        case .idle:
            if let last = engine.lastSyncedDate {
                return "Last synced \(last.formatted(date: .abbreviated, time: .shortened))"
            }
            return nil
        default:
            return nil
        }
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
