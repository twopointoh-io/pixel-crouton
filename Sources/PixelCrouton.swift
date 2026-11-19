import AppKit
import SwiftUI
import UniformTypeIdentifiers

#if !DOCS_PREVIEW
@main
struct PixelCroutonApp: App {
    var body: some Scene {
        Window("Pixel Crouton", id: "primary") {
            BatchView()
                .frame(minWidth: 720, idealWidth: 860, minHeight: 600, idealHeight: 730)
        }
        .defaultSize(width: 860, height: 730)
        .windowResizability(.contentMinSize)
    }
}

#endif

@MainActor
final class BatchState: ObservableObject {
    @Published var inputs: [URL] = []
    @Published var importIssues: [InputIssue] = []
    @Published var ignored = 0
    @Published var scanCount = 0
    @Published var dropTargeted = false
    @Published var job: Task<BatchOutcome, Never>?
    @Published var busy = false
    @Published var cancelling = false
    @Published var tried = 0
    @Published var currentFailures = 0
    @Published var outcome: BatchOutcome?
    @Published var lastFolder: URL?
    @Published var showingIssues = false
    @Published var namingExpanded = false
    @Published var naming = ExportNaming()

}

@MainActor
struct BatchView: View {
    @AppStorage("format") private var format = ExportFormat.jpeg
    @AppStorage("maxEdgeText") private var maxEdgeText = "2000"
    @AppStorage("quality") private var quality = 0.85
    @AppStorage("matteHex") private var matteHex = "FFFFFF"
    @AppStorage("exportPath") private var exportPath = ""

    @StateObject private var state: BatchState

    init(state: @autoclosure @escaping () -> BatchState = BatchState()) {
        _state = StateObject(wrappedValue: state())
    }

    private let paper = Color(nsColor: .windowBackgroundColor)
    private let card = Color(nsColor: .controlBackgroundColor)
    private let rule = Color(nsColor: .separatorColor)
    private let muted = Color.secondary

    private var maxEdge: Int? {
        guard let value = Int(maxEdgeText.trimmingCharacters(in: .whitespaces)),
            (1...ExportSettings.maxAllowedEdge).contains(value) else { return nil }
        return value
    }
    private var output: URL? { exportPath.isEmpty ? nil : URL(fileURLWithPath: exportPath, isDirectory: true) }
    private var ready: Bool { !state.inputs.isEmpty && maxEdge != nil && output != nil && state.scanCount == 0 && !state.busy && state.naming.validationMessage == nil }
    private var allIssues: [InputIssue] { state.importIssues + (state.outcome?.failures ?? []) }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HStack(alignment: .top, spacing: 22) {
                VStack(alignment: .leading, spacing: 9) {
                    HStack {
                        section("01", "Images in")
                        Spacer()
                        if state.scanCount > 0 { ProgressView().controlSize(.small).accessibilityLabel("Finding images") }
                        else if !state.inputs.isEmpty {
                            Button("Clear", action: clear).buttonStyle(.plain).foregroundStyle(muted)
                                .accessibilityLabel("Clear image queue").disabled(state.busy)
                        }
                    }
                    queue
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                VStack(alignment: .leading, spacing: 9) {
                    section("02", "Export settings")
                    ScrollViewReader { scroll in
                        ScrollView {
                            VStack(alignment: .leading, spacing: 9) {
                                VStack(alignment: .leading, spacing: 14) {
                                    formats
                                    Divider()
                                    sizeControls
                                    if format == .jpeg {
                                        qualityControls
                                        matteControls
                                    }
                                    Divider()
                                    folderControls
                                }
                                .padding(16)
                                .background(card, in: RoundedRectangle(cornerRadius: 15))
                                .overlay { RoundedRectangle(cornerRadius: 15).strokeBorder(rule) }
                                namingControls
                                    .padding(.bottom, 2)
                                    .id("naming")
                            }
                        }
                        .onChange(of: state.namingExpanded) { _, expanded in
                            guard expanded else { return }
                            Task { @MainActor in
                                // DisclosureGroup animates its own layout; use the expanded geometry.
                                try? await Task.sleep(for: .milliseconds(240))
                                guard state.namingExpanded else { return }
                                withAnimation(.easeOut(duration: 0.18)) {
                                    scroll.scrollTo("naming", anchor: .bottom)
                                }
                            }
                        }
                    }
                    .disabled(state.busy)
                }
                .frame(width: 302)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 21)
            .frame(maxHeight: .infinity)
            Divider()
            footer
        }
        .background(paper)
        .sheet(isPresented: $state.showingIssues) { issueSheet }
    }

    private var header: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 12).fill(card).frame(width: 44, height: 44)
                Image(systemName: "square.dashed.inset.filled").font(.system(size: 23, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("Pixel Crouton").font(.system(size: 26, weight: .bold)).accessibilityAddTraits(.isHeader)
                Text("Batch image prep for the web").font(.system(size: 12)).foregroundStyle(muted)
            }
            Spacer()
            Label("On this Mac", systemImage: "lock.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(muted)
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(card, in: Capsule()).overlay { Capsule().strokeBorder(rule) }
                .accessibilityLabel("On this Mac. Files never leave this device.")
        }
        .padding(.horizontal, 24).padding(.vertical, 19)
    }

    private func section(_ number: String, _ label: String) -> some View {
        HStack(spacing: 7) {
            Text(number).font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundStyle(muted).accessibilityHidden(true)
            Text(label).font(.system(size: 13, weight: .bold)).accessibilityAddTraits(.isHeader)
        }
        .frame(height: 19)
    }

    private var queue: some View {
        VStack(spacing: 0) {
            if state.inputs.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "photo.on.rectangle.angled")
                        .font(.system(size: 27, weight: .medium)).symbolRenderingMode(.hierarchical)
                        .frame(width: 61, height: 61)
                        .background(Color(nsColor: .quaternaryLabelColor).opacity(0.30), in: RoundedRectangle(cornerRadius: 17))
                        .accessibilityHidden(true)
                    Text(state.dropTargeted ? "Drop to add" : "Drop images or folders")
                        .font(.system(size: 20, weight: .bold)).accessibilityAddTraits(.isHeader)
                    Text("Folders are scanned for images, including subfolders.")
                        .font(.system(size: 12)).foregroundStyle(muted).multilineTextAlignment(.center)
                    Button("Choose Images or Folders…", action: chooseInputs)
                        .keyboardShortcut("o", modifiers: .command)
                        .padding(.top, 4)
                }
                .padding(16)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay {
                    RoundedRectangle(cornerRadius: 15).strokeBorder(state.dropTargeted ? Color.accentColor : rule,
                        style: StrokeStyle(lineWidth: state.dropTargeted ? 2 : 1.5, dash: [5, 5]))
                }
            } else {
                HStack {
                    Text(state.inputs.count == 1 ? "1 image queued" : "\(state.inputs.count) images queued").font(.system(size: 12, weight: .semibold))
                    Spacer()
                    Button(action: chooseInputs) { Label("Add more…", systemImage: "plus") }
                        .keyboardShortcut("o", modifiers: .command).disabled(state.busy)
                }
                .padding(.horizontal, 12).padding(.vertical, 10)
                Divider()
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(state.inputs, id: \.self) { file in inputRow(file) }
                    }
                }
                .frame(maxHeight: .infinity)
                if state.ignored > 0 {
                    Divider()
                    Text("\(state.ignored) other \(state.ignored == 1 ? "file" : "files") skipped in folders")
                        .font(.system(size: 11)).foregroundStyle(muted)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(10)
                }
            }
        }
        .background(state.dropTargeted ? Color.accentColor.opacity(0.10) : card, in: RoundedRectangle(cornerRadius: 15))
        .overlay { if !state.inputs.isEmpty { RoundedRectangle(cornerRadius: 15).strokeBorder(state.dropTargeted ? Color.accentColor : rule) } }
        .clipShape(RoundedRectangle(cornerRadius: 15))
        .dropDestination(for: URL.self) { urls, _ in
            let files = urls.filter(\.isFileURL)
            guard !state.busy, !files.isEmpty else { return false }
            add(files)
            return true
        } isTargeted: { state.dropTargeted = $0 && !state.busy }
    }

    private func inputRow(_ file: URL) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "photo").foregroundStyle(muted)
                    .frame(width: 29, height: 29)
                    .background(Color(nsColor: .quaternaryLabelColor).opacity(0.28), in: RoundedRectangle(cornerRadius: 7))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(file.lastPathComponent).font(.system(size: 12, weight: .medium))
                        .lineLimit(1).truncationMode(.middle)
                    Text(file.deletingLastPathComponent().lastPathComponent).font(.system(size: 10))
                        .foregroundStyle(muted).lineLimit(1).truncationMode(.middle)
                }
                .help(file.path)
                Spacer()
                Button {
                    state.inputs.removeAll { $0 == file }
                    resetResult()
                } label: { Image(systemName: "xmark").font(.system(size: 10, weight: .semibold)).padding(6) }
                .buttonStyle(.plain).foregroundStyle(muted).disabled(state.busy)
                .accessibilityLabel("Remove \(file.lastPathComponent)")
            }
            .padding(.horizontal, 11).padding(.vertical, 7)
            Divider().padding(.leading, 48)
        }
    }

    private var formats: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("File type").font(.system(size: 12, weight: .semibold))
            Picker("File type", selection: $format) {
                ForEach(ExportFormat.allCases) { Text($0.rawValue).tag($0) }
            }
            .labelsHidden().pickerStyle(.segmented)
            Text(format.subtitle).font(.system(size: 11)).foregroundStyle(muted)
        }
    }

    private var sizeControls: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text("Maximum long edge").font(.system(size: 12, weight: .semibold))
                Spacer(minLength: 8)
                TextField("Pixels", text: $maxEdgeText).labelsHidden()
                    .textFieldStyle(.roundedBorder).multilineTextAlignment(.trailing).frame(width: 69)
                    .accessibilityLabel("Maximum long edge in pixels")
                Text("px").font(.system(size: 11)).foregroundStyle(muted)
            }
            if maxEdge == nil {
                Text("Enter 1–12,000 px.").font(.system(size: 11)).foregroundStyle(Color(nsColor: .systemRed))
            } else {
                Text("Keeps proportions. Never enlarges originals.").font(.system(size: 11)).foregroundStyle(muted)
            }
        }
    }

    private var qualityControls: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text("JPEG quality").font(.system(size: 12, weight: .semibold))
                Spacer()
                Text("\(Int((quality * 100).rounded()))%").font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(muted)
            }
            Slider(value: $quality, in: 0.01...1, step: 0.01) { Text("JPEG quality") }
                .labelsHidden().accessibilityValue("\(Int((quality * 100).rounded())) percent")
        }
    }

    private var matteControls: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text("Background color").font(.system(size: 12, weight: .semibold))
                Text("Fills transparent areas in JPEGs.").font(.system(size: 11)).foregroundStyle(muted)
            }
            Spacer()
            ColorPicker("JPEG background color", selection: Binding(get: {
                let (r, g, b) = ExportSettings.hexComponents(matteHex)
                return Color(.sRGB, red: r, green: g, blue: b)
            }, set: { color in
                guard let rgb = NSColor(color).usingColorSpace(.sRGB) else { return }
                func channel(_ amount: CGFloat) -> Int { Int((min(1, max(0, amount)) * 255).rounded()) }
                matteHex = String(format: "%02X%02X%02X", channel(rgb.redComponent), channel(rgb.greenComponent), channel(rgb.blueComponent))
            }), supportsOpacity: false).labelsHidden()
        }
    }

    private var folderControls: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Export folder").font(.system(size: 12, weight: .semibold))
            HStack(spacing: 7) {
                Image(systemName: "folder").foregroundStyle(muted)
                Text(output.map { $0.lastPathComponent.isEmpty ? "/" : $0.lastPathComponent } ?? "No folder selected")
                    .lineLimit(1).truncationMode(.middle).font(.system(size: 11)).foregroundStyle(muted)
                    .help(output?.path ?? "Choose where exported images should go.")
                Spacer(minLength: 2)
                Button("Choose…", action: chooseOutput).accessibilityLabel("Choose export folder")
            }
        }
    }

    private var namingControls: some View {
        DisclosureGroup(isExpanded: $state.namingExpanded) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Prefix").font(.system(size: 11, weight: .semibold))
                        TextField("Prefix", text: $state.naming.prefix, prompt: Text("e.g. studio_"))
                            .labelsHidden().textFieldStyle(.roundedBorder)
                            .disableAutocorrection(true).accessibilityLabel("Filename prefix")
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Suffix").font(.system(size: 11, weight: .semibold))
                        TextField("Suffix", text: $state.naming.suffix, prompt: Text("e.g. -1600w"))
                            .labelsHidden().textFieldStyle(.roundedBorder)
                            .disableAutocorrection(true).accessibilityLabel("Filename suffix")
                    }
                }
                if let message = state.naming.validationMessage {
                    Text(message).font(.system(size: 11)).foregroundStyle(Color(nsColor: .systemRed))
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    let source = state.inputs.first ?? URL(fileURLWithPath: "/hero.png")
                    Text(verbatim: "\(source.lastPathComponent) → \(state.naming.filename(for: source, format: format))")
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .lineLimit(2).truncationMode(.middle)
                    Text("If a filename exists, a number is added.")
                        .font(.system(size: 11)).foregroundStyle(muted)
                }
            }
            .padding(.top, 7)
        } label: {
            HStack(spacing: 6) {
                Text("Naming").font(.system(size: 12, weight: .semibold))
                Text(state.naming.validationMessage != nil ? "Needs attention" :
                    (state.naming.prefix.isEmpty && state.naming.suffix.isEmpty ? "Optional" : "Custom"))
                    .font(.system(size: 11)).foregroundStyle(muted)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(card, in: RoundedRectangle(cornerRadius: 12))
        .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(rule).allowsHitTesting(false) }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                if state.busy {
                    Text(state.cancelling ? "Stopping after the current image…" :
                        (state.tried == 0 ? "Preparing export…" : "\(state.tried) of \(state.inputs.count) processed"))
                        .font(.system(size: 12, weight: .semibold))
                    ProgressView(value: Double(state.tried), total: Double(max(state.inputs.count, 1)))
                        .frame(maxWidth: 260).accessibilityLabel("Export progress")
                    if state.currentFailures > 0 {
                        Text("\(state.currentFailures) couldn’t be exported").font(.system(size: 11)).foregroundStyle(muted)
                    }
                } else if let outcome = state.outcome {
                    Text(outcome.setupError ?? resultTitle(outcome)).font(.system(size: 12, weight: .semibold))
                    Text(outcome.setupError == nil ? "Originals are unchanged." : "No images were exported.")
                        .font(.system(size: 11)).foregroundStyle(muted)
                } else {
                    Text(state.scanCount > 0 ? "Finding images…" : readinessTitle).font(.system(size: 12, weight: .semibold))
                    Text("Originals are never changed or overwritten.").font(.system(size: 11)).foregroundStyle(muted)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if !state.busy && !allIssues.isEmpty {
                Button("View issues (\(allIssues.count))") { state.showingIssues = true }
            }
            if !state.busy, let lastFolder = state.lastFolder, (state.outcome?.completed ?? 0) > 0 {
                Button("Show in Finder") { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: lastFolder.path) }
            }
            if state.busy {
                Button(state.cancelling ? "Stopping…" : "Cancel") { state.cancelling = true; state.job?.cancel() }.disabled(state.cancelling)
            } else {
                Button(action: export) {
                    Label(state.inputs.isEmpty ? "Export Images" : "Export \(state.inputs.count) \(state.inputs.count == 1 ? "Image" : "Images")",
                        systemImage: "arrow.down.to.line").fontWeight(.semibold)
                }
                .buttonStyle(.borderedProminent).controlSize(.large).keyboardShortcut(.defaultAction)
                .disabled(!ready)
            }
        }
        .padding(.horizontal, 24).padding(.vertical, 14)
    }

    private var readinessTitle: String {
        if state.inputs.isEmpty { return "Add images to get started." }
        if output == nil { return "Choose an export folder." }
        if maxEdge == nil { return "Set a valid maximum long edge." }
        if state.naming.validationMessage != nil { return "Fix the naming options to export." }
        return "Ready to export."
    }

    private func resultTitle(_ result: BatchOutcome) -> String {
        let success = "Exported \(result.completed) \(result.completed == 1 ? "image" : "images")"
        let failures = result.failures.isEmpty ? "" : " • \(result.failures.count) failed"
        return result.cancelled ? "Stopped. " + success + failures : success + failures
    }

    private var issueSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Files that need attention").font(.title2.bold())
            Text("Other images can still export. The originals are unchanged.").font(.callout).foregroundStyle(muted)
            List(allIssues) { issue in
                VStack(alignment: .leading, spacing: 4) {
                    Text(issue.url.lastPathComponent).font(.headline).textSelection(.enabled)
                    Text(issue.message).font(.callout).fixedSize(horizontal: false, vertical: true)
                    Text(issue.url.path).font(.caption).foregroundStyle(muted).textSelection(.enabled)
                }
                .padding(.vertical, 4)
            }
            HStack {
                Button("Copy Details") {
                    let paste = NSPasteboard.general
                    paste.clearContents()
                    paste.setString(allIssues.map { "\($0.url.path)\n\($0.message)" }.joined(separator: "\n\n"), forType: .string)
                }
                Spacer()
                Button("Done") { state.showingIssues = false }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20).frame(width: 570, height: 370)
    }

    private func resetResult() {
        state.outcome = nil
        state.lastFolder = nil
    }

    private func clear() {
        state.inputs.removeAll()
        state.importIssues.removeAll()
        state.ignored = 0
        resetResult()
    }

    private func chooseInputs() {
        guard !state.busy else { return }
        let panel = NSOpenPanel()
        panel.title = "Choose images or folders"
        panel.prompt = "Add to Queue"
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        if panel.runModal() == .OK { add(panel.urls) }
    }

    private func chooseOutput() {
        let panel = NSOpenPanel()
        panel.title = "Choose a folder for exported images"
        panel.prompt = "Use Folder"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.directoryURL = output
        if panel.runModal() == .OK, let url = panel.url { exportPath = url.path }
    }

    private func add(_ urls: [URL]) {
        state.scanCount += 1
        resetResult()
        let scan = Task.detached(priority: .userInitiated) { InputDiscovery.scan(urls) }
        Task {
            let result = await scan.value
            var existing = Set(state.inputs)
            state.inputs.append(contentsOf: result.urls.filter { existing.insert($0).inserted })
            state.importIssues.append(contentsOf: result.issues)
            state.ignored += result.ignored
            state.scanCount -= 1
        }
    }

    private func export() {
        guard ready, let maxEdge, let folder = output else { return }
        let queue = state.inputs
        let settings = ExportSettings(format: format, maxEdge: maxEdge, quality: quality, matteHex: matteHex, naming: state.naming)
        state.tried = 0
        state.currentFailures = 0
        state.busy = true
        state.cancelling = false
        resetResult()
        let task = Task.detached(priority: .userInitiated) {
            await BatchRunner.run(queue, folder: folder, settings: settings) { count, issue in
                state.tried = count
                if issue != nil { state.currentFailures += 1 }
            }
        }
        state.job = task
        Task {
            state.outcome = await task.value
            state.lastFolder = folder
            state.busy = false
            state.cancelling = false
            state.job = nil
        }
    }
}
