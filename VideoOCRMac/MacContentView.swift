import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct MacContentView: View {
    @StateObject private var model = MacOCRViewModel()
    @State private var selectedPreview: MacOCRFrameResult?
    @State private var isShowingAdvanced = false
    @State private var isShowingSettings = false
    @State private var selectedTab = 0 // 0: Raw OCR, 1: AI Formatted

    var body: some View {
        VStack(spacing: 0) {
            toolbar

            Divider()

            HSplitView {
                sidebar
                    .frame(minWidth: 290, idealWidth: 330, maxWidth: 420)

                resultArea
                    .frame(minWidth: 620)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .sheet(item: $selectedPreview) { result in
            MacImagePreviewView(result: result)
        }
        .sheet(isPresented: $isShowingSettings) {
            AISettingsView()
        }
        .onDrop(of: [.fileURL, .image], isTargeted: nil) { providers in
            let group = DispatchGroup()
            var urls: [URL] = []
            
            for provider in providers {
                group.enter()
                if provider.canLoadObject(ofClass: URL.self) {
                    _ = provider.loadObject(ofClass: URL.self) { url, error in
                        if let url = url {
                            urls.append(url)
                        }
                        group.leave()
                    }
                } else if provider.canLoadObject(ofClass: NSImage.self) {
                    _ = provider.loadObject(ofClass: NSImage.self) { image, error in
                        if let nsImage = image as? NSImage, let tempURL = saveTempImage(nsImage) {
                            urls.append(tempURL)
                        }
                        group.leave()
                    }
                } else {
                    group.leave()
                }
            }
            
            group.notify(queue: .main) {
                guard !urls.isEmpty else { return }
                model.addURLs(urls)
            }
            return true
        }
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            Button {
                model.chooseFiles()
            } label: {
                Label("Choose Files", systemImage: "plus")
            }
            .keyboardShortcut("o", modifiers: [.command])
            .disabled(model.isProcessing)

            Button {
                model.clearAll()
            } label: {
                Label("Clear", systemImage: "trash")
            }
            .disabled(model.isProcessing && model.sourceFiles.isEmpty)

            Divider()
                .frame(height: 24)

            Toggle("Auto", isOn: $model.usesAutomaticSettings)
                .toggleStyle(.switch)
                .disabled(model.isProcessing)

            Button {
                Task { await model.startOCR() }
            } label: {
                Label("Start OCR", systemImage: "text.viewfinder")
            }
            .keyboardShortcut(.return, modifiers: [.command])
            .disabled(!model.canStart)

            Button {
                model.cancelOCR()
            } label: {
                Label("Stop", systemImage: "stop.fill")
            }
            .disabled(!model.isProcessing)

            Spacer()

            Button {
                isShowingSettings = true
            } label: {
                Image(systemName: "gearshape")
            }
            .disabled(model.isProcessing)
            .help("AI Settings")

            Button {
                model.formatWithAI()
            } label: {
                if model.isFormatting {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Label("Format AI", systemImage: "sparkles")
                }
            }
            .disabled(model.isProcessing || model.isFormatting || model.results.isEmpty)
            .help("Format raw text using AI")

            Button {
                if selectedTab == 0 {
                    model.copyRaw()
                } else {
                    model.copyFormatted()
                }
            } label: {
                Label("Copy", systemImage: "doc.on.doc")
            }
            .keyboardShortcut("c", modifiers: [.command, .shift])
            .disabled(model.results.isEmpty || (selectedTab == 1 && model.formattedText == nil))

            if model.formattedFileURL != nil {
                Button {
                    model.revealFormattedFile()
                } label: {
                    Label("Reveal .md", systemImage: "folder")
                }
                .help("Show the saved Markdown file in Finder")
            }
        }
        .padding(12)
    }

    private var sidebar: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                sectionHeader("Source")

                if model.sourceFiles.isEmpty {
                    ContentUnavailableView(
                        "No files selected",
                        systemImage: "doc.badge.plus",
                        description: Text("Choose videos, images, PDFs, or text files.")
                    )
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 28)
                } else {
                    VStack(spacing: 6) {
                        ForEach(model.sourceFiles) { file in
                            sourceRow(file)
                        }
                    }
                }

                Divider()

                sectionHeader("OCR")

                if let estimated = model.estimatedWorkText {
                    Label(estimated, systemImage: "speedometer")
                        .foregroundStyle(.secondary)
                }

                DisclosureGroup(isExpanded: $isShowingAdvanced) {
                    VStack(alignment: .leading, spacing: 14) {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text("Frame interval")
                                Spacer()
                                Text("\(model.interval, specifier: "%.1f")s")
                                    .foregroundStyle(.secondary)
                            }
                            Slider(value: $model.interval, in: 0.5...5.0, step: 0.5)
                                .disabled(model.isProcessing || model.usesAutomaticSettings)
                        }

                        // Removed Center focus section

                        // Language Picker removed (now auto-detects both English & Vietnamese)
                    }
                    .padding(.top, 8)
                } label: {
                    Label("Advanced", systemImage: "slider.horizontal.3")
                }

                Divider()

                sectionHeader("Status")
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(model.statusTitle)
                            .font(.headline)
                        Spacer()
                        Text(model.progressText)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    ProgressView(value: model.progress)
                    if let summary = model.resultSummary {
                        Label(summary, systemImage: "checkmark.seal.fill")
                            .foregroundStyle(.green)
                    }
                    if let message = model.message {
                        Text(message)
                            .font(.callout)
                            .foregroundStyle(model.messageIsError ? .red : .secondary)
                    }
                }
            }
            .padding(16)
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private var resultArea: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Picker("", selection: $selectedTab) {
                    Text("Raw OCR").tag(0)
                    Text("AI Formatted").tag(1)
                }
                .pickerStyle(.segmented)
                .frame(width: 240)
                
                Spacer()
                
                if !model.results.isEmpty {
                    if selectedTab == 0 {
                        Text("\(model.results.count) frame\(model.results.count == 1 ? "" : "s")")
                            .foregroundStyle(.secondary)
                    } else if model.formattedText != nil {
                        Text("AI Format Ready")
                            .foregroundStyle(.green)
                    }
                }
            }
            .padding(16)

            Divider()

            if model.results.isEmpty {
                ContentUnavailableView(
                    "No OCR yet",
                    systemImage: "text.magnifyingglass",
                    description: Text("Choose files and start OCR to extract raw visible text.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if selectedTab == 0 {
                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach(model.results) { result in
                            resultCard(result)
                        }
                    }
                    .padding(16)
                }
            } else {
                if let formatted = model.formattedText {
                    ScrollView {
                        Text(renderedMarkdown(formatted))
                            .padding(16)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .background(Color(nsColor: .textBackgroundColor))
                } else if model.isFormatting {
                    VStack(spacing: 16) {
                        ProgressView()
                        Text("AI is formatting document structure...")
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ContentUnavailableView(
                        "Not formatted yet",
                        systemImage: "sparkles",
                        description: Text("Click the 'Format AI' (✨) button in the toolbar to reconstruct the document layout.")
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
    }

    private func sourceRow(_ file: MacSourceFile) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon(for: file.kind))
                .foregroundStyle(.blue)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 2) {
                Text(file.displayName)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(detail(for: file))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                model.removeSource(file)
            } label: {
                Image(systemName: "xmark.circle.fill")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .disabled(model.isProcessing)
        }
        .padding(8)
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
    }

    private func resultCard(_ result: MacOCRFrameResult) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Button {
                selectedPreview = result
            } label: {
                if let imageURL = result.imageURL, let image = NSImage(contentsOf: imageURL) {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 220, height: 150)
                        .background(Color.black)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .overlay(alignment: .bottomTrailing) {
                            Image(systemName: "arrow.up.left.and.arrow.down.right")
                                .font(.caption.weight(.semibold))
                                .padding(7)
                                .background(.regularMaterial)
                                .clipShape(Circle())
                                .padding(8)
                        }
                } else {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.secondary.opacity(0.12))
                        .frame(width: 220, height: 150)
                        .overlay(Image(systemName: "photo"))
                }
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(result.timestampLabel)
                        .font(.headline.monospacedDigit())
                    Text("\(result.lines.count) line\(result.lines.count == 1 ? "" : "s")")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        copy(result.text)
                    } label: {
                        Label("Copy Frame", systemImage: "doc.on.doc")
                    }
                }

                Text(result.text)
                    .font(.body)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(12)
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
    }

    private func sectionHeader(_ text: String) -> some View {
        Text(text)
            .font(.headline)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func icon(for kind: MacSourceFile.Kind) -> String {
        switch kind {
        case .video:
            return "video.fill"
        case .image:
            return "photo.fill"
        case .pdf:
            return "doc.richtext.fill"
        case .text:
            return "doc.text.fill"
        case .file:
            return "doc.fill"
        }
    }

    private func detail(for file: MacSourceFile) -> String {
        if let duration = file.durationSeconds {
            return "\(file.kind.rawValue) - \(formatDuration(duration))"
        }
        return file.kind.rawValue
    }

    private func formatDuration(_ duration: Double) -> String {
        let seconds = max(0, Int(duration.rounded()))
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        let remaining = seconds % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, remaining)
        }
        return String(format: "%02d:%02d", minutes, remaining)
    }

    private func copy(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    private func renderedMarkdown(_ text: String) -> AttributedString {
        guard var attributed = try? AttributedString(
            markdown: text,
            options: AttributedString.MarkdownParsingOptions(interpretedSyntax: .full)
        ) else {
            return AttributedString(text)
        }

        for run in attributed.runs {
            guard let intent = run.presentationIntent else { continue }
            for component in intent.components {
                switch component.kind {
                case .header(let level):
                    let size: CGFloat = [24, 20, 17, 15, 14, 13][min(level - 1, 5)]
                    attributed[run.range].font = .system(size: size, weight: .bold)
                case .codeBlock:
                    attributed[run.range].font = .system(.body, design: .monospaced)
                    attributed[run.range].backgroundColor = .secondary.opacity(0.12)
                default:
                    break
                }
            }
        }
        return attributed
    }

    private func saveTempImage(_ image: NSImage) -> URL? {
        guard let tiffData = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData),
              let pngData = bitmap.representation(using: .png, properties: [:]) else {
            return nil
        }
        let tempDir = FileManager.default.temporaryDirectory
        let fileURL = tempDir.appendingPathComponent("screenshot_\(UUID().uuidString).png")
        do {
            try pngData.write(to: fileURL)
            return fileURL
        } catch {
            return nil
        }
    }
}
