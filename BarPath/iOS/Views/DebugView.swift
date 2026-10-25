import SwiftUI
import BarPathKit

/// Data collection hub: full-session CSVs (with marks + watch detector events inside),
/// lift files, connection state and the read-only detector/analyzer configuration.
struct DebugView: View {
    @EnvironmentObject private var store: LiftStore
    @EnvironmentObject private var link: PhoneLink
    @State private var fileToDelete: DebugFile?

    private var confirmBinding: Binding<Bool> {
        return Binding<Bool>(
            get: { fileToDelete != nil },
            set: { newValue in
                if !newValue { fileToDelete = nil }
            }
        )
    }

    var body: some View {
        NavigationStack {
            List {
                recordingsSection
                liftFilesSection
                connectionSection
                if !store.problems.isEmpty {
                    Section("Unreadable files") {
                        ForEach(Array(store.problems.enumerated()), id: \.offset) { item in
                            Text(item.element)
                                .font(.caption)
                        }
                    }
                }
                Section {
                    ConfigRows(value: DetectorConfig.default)
                } header: {
                    Text("Watch detector config (read-only)")
                } footer: {
                    Text("Seconds, m/s, m, rad/s and g. Same defaults as tools/barpath/detector.py.")
                }
                Section("Phone analyzer config (read-only)") {
                    ConfigRows(value: AnalyzerConfig.default)
                }
                Section("Known limitations") {
                    ForEach(Labels.knownLimitations, id: \.self) { text in
                        Text(text)
                            .font(.footnote)
                    }
                }
                Section("Storage") {
                    Text(LiftFiles.documentsURL.path)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                    Text("Also visible in the Files app: On My iPhone › BarPath.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Debug")
            .refreshable {
                store.reloadDebugFiles()
            }
            .onAppear {
                store.reloadDebugFiles()
            }
            .navigationDestination(for: DebugFile.self) { file in
                DebugFileDetailView(file: file)
            }
            .confirmationDialog("Delete this file?",
                                isPresented: confirmBinding,
                                titleVisibility: .visible,
                                presenting: fileToDelete) { file in
                Button("Delete \(file.name)", role: .destructive) {
                    store.deleteDebugFile(file)
                    fileToDelete = nil
                }
                Button("Cancel", role: .cancel) {
                    fileToDelete = nil
                }
            }
        }
    }

    // MARK: - Sections

    private var recordingsSection: some View {
        Section {
            if store.debugFiles.isEmpty {
                Text("No full-session recordings yet. On the watch, turn on “Record full session (debug)” before Start. The CSV arrives a few seconds after you tap End, while this app is open.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                ShareLink(items: store.debugFiles.map { $0.url }) {
                    Label("Share all recordings (\(store.debugFiles.count))", systemImage: "square.and.arrow.up.on.square")
                        .font(.subheadline.weight(.semibold))
                }
                ForEach(store.debugFiles) { file in
                    HStack(spacing: 10) {
                        NavigationLink(value: file) {
                            DebugFileRow(file: file)
                        }
                        ShareLink(item: file.url) {
                            Image(systemName: "square.and.arrow.up")
                                .font(.body.weight(.semibold))
                        }
                        .buttonStyle(.borderless)
                    }
                    .swipeActions(edge: .trailing) {
                        Button {
                            fileToDelete = file
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                        .tint(Color.red)
                    }
                }
            }
        } header: {
            Text("Full-session recordings")
        } footer: {
            Text("Each CSV holds every 200 Hz motion sample of a session, plus your Mark taps and the watch detector's events as # comment lines. AirDrop or save them to Files and send them over for tuning.")
        }
    }

    private var liftFilesSection: some View {
        Section {
            LabeledContent("Lifts stored", value: "\(store.liftCount)")
            LabeledContent("Sessions", value: "\(store.sessions.count)")
            if !store.allLiftFileURLs.isEmpty {
                ShareLink(items: store.allLiftFileURLs) {
                    Label("Share all lift files (\(store.allLiftFileURLs.count))", systemImage: "square.and.arrow.up.on.square")
                }
            }
        } header: {
            Text("Lift files")
        } footer: {
            Text("One JSON per lift (raw 200 Hz motion + 800 Hz accelerometer). Share a single lift from its detail screen, or a whole session from History.")
        }
    }

    private var connectionSection: some View {
        Section("Watch connection") {
            LabeledContent("Session", value: link.activationDescription)
            LabeledContent("Paired", value: link.isPaired ? "Yes" : "No")
            LabeledContent("Watch app installed", value: link.isWatchAppInstalled ? "Yes" : "No")
            LabeledContent("Reachable now", value: link.isReachable ? "Yes" : "No")
            if let date = link.lastFileReceivedAt {
                LabeledContent("Last file received", value: date.formatted(date: .omitted, time: .standard))
            }
            if let status = link.lastStatusText {
                Text(status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let error = link.lastError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(Color.red)
            }
        }
    }
}

extension DebugFile: Hashable {
    func hash(into hasher: inout Hasher) {
        hasher.combine(url)
    }
}

struct DebugFileRow: View {
    let file: DebugFile

    private var title: String {
        if let start = file.recordingStart {
            return start.formatted(date: .abbreviated, time: .shortened)
        }
        return file.modified.formatted(date: .abbreviated, time: .shortened)
    }

    private var details: String {
        var parts: [String] = []
        switch file.kind {
        case .session: parts.append("Session")
        case .marks: parts.append("Marks")
        case .other: parts.append("File")
        }
        if let name = Labels.liftTypeName(raw: file.liftTypeRaw) {
            parts.append(name)
        }
        if let duration = file.duration {
            parts.append(Fmt.duration(duration))
        }
        parts.append(Fmt.bytes(file.size))
        return parts.joined(separator: " · ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.subheadline.weight(.semibold))
            Text(details)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(file.name)
                .font(.caption2.monospaced())
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }
}

// MARK: - Inspecting a session CSV on the phone

struct DetectedLift: Identifiable, Sendable {
    let id: Int
    let homingTime: Double
    let endTime: Double
    let reason: String
}

struct SessionInspection: Sendable {
    let sampleCount: Int
    let duration: Double
    let marks: [Double]              // t of "# mark" lines
    let watchLiftEvents: Int         // "# event ... name=liftEnded" lines written by the watch
    let detected: [DetectedLift]     // OnlineLiftDetector re-run on the phone
    let error: String?
}

enum SessionInspector {
    static func inspect(_ url: URL) -> SessionInspection {
        guard let data = try? Data(contentsOf: url) else {
            return SessionInspection(sampleCount: 0, duration: 0, marks: [], watchLiftEvents: 0,
                                     detected: [], error: "Could not read the file.")
        }
        let text = String(decoding: data, as: UTF8.self)

        var marks: [Double] = []
        var watchLiftEvents = 0
        text.enumerateLines { line, _ in
            if line.hasPrefix("# mark") {
                if let t = SessionInspector.value(of: "t", in: line) {
                    marks.append(t)
                }
            } else if line.hasPrefix("# event") && line.contains("name=liftEnded") {
                watchLiftEvents += 1
            }
        }

        let samples: [MotionSample]
        do {
            samples = try SessionCSV.parse(text).samples
        } catch {
            return SessionInspection(sampleCount: 0, duration: 0, marks: marks, watchLiftEvents: watchLiftEvents,
                                     detected: [], error: "Could not parse CSV: \(error)")
        }

        let detector = OnlineLiftDetector()
        var detected: [DetectedLift] = []
        for s in samples {
            if let event = detector.process(s) {
                if case .liftEnded(let homing, let end, let reason) = event {
                    detected.append(DetectedLift(id: detected.count + 1,
                                                 homingTime: homing,
                                                 endTime: end,
                                                 reason: Labels.endReason(reason)))
                }
            }
        }
        let duration = samples.last.map { $0.t } ?? 0
        return SessionInspection(sampleCount: samples.count, duration: duration, marks: marks,
                                 watchLiftEvents: watchLiftEvents, detected: detected, error: nil)
    }

    /// Parses `key=<number>` out of a comment line.
    private static func value(of key: String, in line: String) -> Double? {
        for part in line.split(separator: " ") {
            if part.hasPrefix(key + "=") {
                return Double(part.dropFirst(key.count + 1))
            }
        }
        return nil
    }
}

struct DebugFileDetailView: View {
    let file: DebugFile
    @State private var inspection: SessionInspection?
    @State private var isRunning = false

    var body: some View {
        List {
            Section {
                LabeledContent("File", value: file.name)
                LabeledContent("Size", value: Fmt.bytes(file.size))
                if let start = file.recordingStart {
                    LabeledContent("Started", value: start.formatted(date: .abbreviated, time: .standard))
                }
                if let duration = file.duration {
                    LabeledContent("Duration", value: Fmt.duration(duration))
                }
                if let name = Labels.liftTypeName(raw: file.liftTypeRaw) {
                    LabeledContent("Lift type", value: name)
                }
                ShareLink(item: file.url) {
                    Label("Share this file", systemImage: "square.and.arrow.up")
                }
            }

            if file.kind == .session {
                Section {
                    if let result = inspection {
                        inspectionRows(result)
                    } else if isRunning {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text("Reading samples…")
                        }
                    } else {
                        Button {
                            runInspection()
                        } label: {
                            Label("Count marks & re-run detector", systemImage: "play.circle")
                        }
                    }
                } header: {
                    Text("Inspect")
                } footer: {
                    Text("Re-runs the watch's lift detector (default config) over this recording on the phone and compares it with your Mark taps.")
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Recording")
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private func inspectionRows(_ result: SessionInspection) -> some View {
        if let error = result.error {
            Text(error)
                .font(.footnote)
                .foregroundStyle(Color.red)
        }
        LabeledContent("Samples", value: "\(result.sampleCount)")
        LabeledContent("Marks tapped", value: "\(result.marks.count)")
        LabeledContent("Lifts (watch, live)", value: "\(result.watchLiftEvents)")
        LabeledContent("Lifts (detector re-run)", value: "\(result.detected.count)")
        ForEach(result.detected) { lift in
            Text("Lift \(lift.id): \(String(format: "%.1f", lift.homingTime)) – \(String(format: "%.1f", lift.endTime)) s · \(lift.reason)")
                .font(.caption.monospaced())
        }
        if !result.marks.isEmpty {
            Text("Marks at: " + result.marks.map { String(format: "%.1f", $0) }.joined(separator: ", ") + " s")
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
        }
    }

    private func runInspection() {
        isRunning = true
        let url = file.url
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                return SessionInspector.inspect(url)
            }.value
            inspection = result
            isRunning = false
        }
    }
}

/// Lists the stored properties of a config struct via reflection, so the UI does not
/// depend on the exact field list.
struct ConfigRows: View {
    private struct Row: Identifiable {
        let id: String
        let value: String
    }

    private let rows: [Row]

    init(value: Any) {
        var out: [Row] = []
        for child in Mirror(reflecting: value).children {
            guard let label = child.label else { continue }
            out.append(Row(id: label, value: ConfigRows.format(child.value)))
        }
        rows = out
    }

    private static func format(_ value: Any) -> String {
        if let d = value as? Double {
            var s = String(format: "%.3f", d)
            while s.hasSuffix("0") { s.removeLast() }
            if s.hasSuffix(".") { s.removeLast() }
            return s
        }
        return String(describing: value)
    }

    var body: some View {
        ForEach(rows) { row in
            LabeledContent(row.id) {
                Text(row.value)
                    .monospacedDigit()
            }
            .font(.subheadline)
        }
    }
}
