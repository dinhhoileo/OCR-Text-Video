import AppKit
import AVFoundation
import Foundation
import UniformTypeIdentifiers

@MainActor
final class MacOCRViewModel: ObservableObject {
    @Published var sourceFiles: [MacSourceFile] = []
    @Published var usesAutomaticSettings = true {
        didSet {
            guard usesAutomaticSettings else { return }
            applyRecommendedSettings()
        }
    }
    @Published var interval = 1.0
    @Published var language = "en-US"
    let centerCropRatio = 1.0
    @Published var progress = 0.0
    @Published var results: [MacOCRFrameResult] = []
    @Published var isProcessing = false
    @Published var message: String?
    @Published var messageIsError = false
    
    @Published var formattedText: String? = nil
    @Published var isFormatting = false
    @Published var formattedFileURL: URL? = nil
    
    private let service = MacOCRService()
    private let aiService = AIFormatterService()
    private var processingTask: Task<Void, Never>?

    var canStart: Bool {
        !sourceFiles.isEmpty && !isProcessing
    }

    var statusTitle: String {
        if isProcessing { return "Processing..." }
        if results.isEmpty { return "Ready" }
        return "OCR Done"
    }

    var progressText: String {
        "\(Int((progress * 100).rounded()))%"
    }

    var resultSummary: String? {
        guard !results.isEmpty else { return nil }
        let totalLines = results.reduce(0) { $0 + $1.lines.count }
        return "\(results.count) frames, \(totalLines) raw lines"
    }

    var estimatedWorkText: String? {
        guard !sourceFiles.isEmpty else { return nil }
        let frames = sourceFiles.reduce(0) { total, file in
            switch file.kind {
            case .video:
                let duration = file.durationSeconds ?? 0
                return total + max(1, Int(ceil(duration / max(interval, 0.5))) + 1)
            case .image, .pdf, .text, .file:
                return total + 1
            }
        }
        let mode = usesAutomaticSettings ? "Auto" : "Manual"
        return "\(mode) | about \(frames) frame\(frames == 1 ? "" : "s") to scan"
    }

    var markdownOutput: String {
        var output = "# Video OCR Output\n\n"
        if !sourceFiles.isEmpty {
            output += "- Source: \(sourceFiles.map(\.displayName).joined(separator: ", "))\n"
        }
        output += "- Interval: \(String(format: "%.1f", interval))s\n\n"

        for result in results {
            output += "## \(result.timestampLabel)\n\n"
            if let imageURL = result.imageURL {
                output += "![Frame \(result.timestampLabel)](\(imageURL.path))\n\n"
            }
            output += result.text
                .split(separator: "\n")
                .map { "- \($0)" }
                .joined(separator: "\n")
            output += "\n\n"
        }

        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func chooseFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.movie, .video, .image, .pdf, .text, .plainText, .item]
        panel.prompt = "Choose"

        if panel.runModal() == .OK {
            addURLs(panel.urls)
        }
    }

    func addURLs(_ urls: [URL]) {
        Task {
            for url in urls {
                await addSource(url)
            }
        }
    }

    func removeSource(_ file: MacSourceFile) {
        sourceFiles.removeAll { $0.id == file.id }
        if sourceFiles.isEmpty {
            clearResults()
            message = nil
        } else {
            applyRecommendedSettingsIfNeeded()
            setReadyMessage()
        }
    }

    func clearAll() {
        cancelOCR()
        sourceFiles.removeAll()
        clearResults()
        message = nil
    }

    func startOCR() async {
        guard !sourceFiles.isEmpty, !isProcessing else { return }
        removeResultImages()
        results.removeAll()
        progress = 0
        setMessage("Starting OCR...", isError: false)
        isProcessing = true

        let filesToProcess = sourceFiles
        let totalFiles = filesToProcess.count
        processingTask = Task { [service, interval, language, centerCropRatio] in
            // Each file gets its own do/catch: a failure on one file (unreadable
            // image, corrupt video, etc.) must not abort the rest of the batch.
            var failedFiles: [String] = []

            for (index, file) in filesToProcess.enumerated() {
                guard !Task.isCancelled else { break }
                let baseProgress = Double(index) / Double(totalFiles)
                let fileWeight = 1.0 / Double(totalFiles)

                await MainActor.run {
                    self.setMessage("Processing \(file.displayName) (\(index + 1)/\(totalFiles))...", isError: false)
                }

                do {
                    let cropRatio = file.kind == .video ? centerCropRatio : 1.0
                    let stream = try service.recognizeText(
                        in: file.url,
                        interval: interval,
                        language: language,
                        centerCropRatio: cropRatio
                    )

                    for try await event in stream {
                        guard !Task.isCancelled else { break }
                        await MainActor.run {
                            switch event {
                            case .progress(let value):
                                self.progress = baseProgress + value * fileWeight
                            case .frame(let result):
                                let last = self.results.last
                                let isDuplicateOfSameSource = last?.text == result.text
                                    && last?.sourceName == result.sourceName
                                if !isDuplicateOfSameSource {
                                    self.results.append(result)
                                }
                            }
                        }
                    }
                } catch is CancellationError {
                    break
                } catch {
                    failedFiles.append("\(file.displayName): \(error.localizedDescription)")
                }
            }

            await MainActor.run {
                self.isProcessing = false
                if Task.isCancelled {
                    self.setMessage("Stopped.", isError: false)
                    return
                }
                self.progress = 1
                let totalLines = self.results.reduce(0) { $0 + $1.lines.count }
                if failedFiles.isEmpty {
                    self.setMessage("Done. \(self.results.count) frames, \(totalLines) lines found.", isError: false)
                } else {
                    self.setMessage(
                        "Done with \(failedFiles.count) error(s). \(self.results.count) frames, \(totalLines) lines found. Skipped: \(failedFiles.joined(separator: "; "))",
                        isError: true
                    )
                }
            }
        }

        await processingTask?.value
    }

    func cancelOCR() {
        processingTask?.cancel()
        processingTask = nil
        isProcessing = false
        setMessage("Stopped.", isError: false)
    }

    func clearResults() {
        removeResultImages()
        results.removeAll()
        progress = 0
        formattedText = nil
        formattedFileURL = nil
    }

    func copyRaw() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(markdownOutput, forType: .string)
        setMessage("Copied raw OCR text.", isError: false)
    }

    func formatWithAI() {
        let allRawText = results.map(\.text).joined(separator: "\n\n")
        guard !allRawText.isEmpty else {
            setMessage("No raw text available to format.", isError: true)
            return
        }
        
        isFormatting = true
        setMessage("Formatting with AI...", isError: false)
        
        Task {
            do {
                let formatted = try await aiService.formatText(allRawText) { attemptedModel in
                    Task { @MainActor in
                        self.setMessage("Formatting with AI (\(attemptedModel))...", isError: false)
                    }
                }
                await MainActor.run {
                    self.formattedText = formatted
                    self.isFormatting = false
                    let savedURL = self.exportAndOpenMarkdown(formatted)
                    if let savedURL {
                        self.formattedFileURL = savedURL
                        self.setMessage("Formatting complete! Saved to \(savedURL.lastPathComponent) and opened.", isError: false)
                    } else {
                        self.setMessage("Formatting complete! (could not auto-save .md file)", isError: false)
                    }
                }
            } catch {
                await MainActor.run {
                    self.isFormatting = false
                    self.setMessage("AI Error: \(error.localizedDescription)", isError: true)
                }
            }
        }
    }

    func copyFormatted() {
        guard let text = formattedText else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        setMessage("Copied formatted AI text.", isError: false)
    }

    func revealFormattedFile() {
        guard let url = formattedFileURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    /// Writes the formatted markdown next to the source file (or to the Desktop as a
    /// fallback) and opens it in the user's default Markdown app, so there's no manual
    /// copy/paste/save step after the AI finishes formatting.
    @discardableResult
    private func exportAndOpenMarkdown(_ text: String) -> URL? {
        let baseName = sourceFiles.first?.url.deletingPathExtension().lastPathComponent ?? "VideoOCR-Output"
        let preferredDir = sourceFiles.first?.url.deletingLastPathComponent()
        let fallbackDir = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first

        for directory in [preferredDir, fallbackDir].compactMap({ $0 }) {
            var candidate = directory.appendingPathComponent("\(baseName)-formatted.md")
            var attempt = 2
            while FileManager.default.fileExists(atPath: candidate.path) {
                candidate = directory.appendingPathComponent("\(baseName)-formatted-\(attempt).md")
                attempt += 1
            }
            do {
                try text.write(to: candidate, atomically: true, encoding: .utf8)
                NSWorkspace.shared.open(candidate)
                return candidate
            } catch {
                continue
            }
        }
        return nil
    }

    private func addSource(_ url: URL) async {
        guard !sourceFiles.contains(where: { $0.url == url }) else { return }
        let metadata = await sourceMetadata(for: url)
        sourceFiles.append(MacSourceFile(url: url, kind: metadata.kind, durationSeconds: metadata.duration))
        applyRecommendedSettingsIfNeeded()
        setReadyMessage()
    }

    private func applyRecommendedSettingsIfNeeded() {
        if usesAutomaticSettings {
            applyRecommendedSettings()
        }
    }

    private func applyRecommendedSettings() {
        let durations = sourceFiles.compactMap(\.durationSeconds)
        guard let longestVideo = durations.max() else {
            interval = 1.0
            return
        }

        switch longestVideo {
        case ...60:
            interval = 0.5
        case ...180:
            interval = 1.0
        case ...600:
            interval = 1.5
        default:
            interval = 2.0
        }
        // Center crop ratio removed
    }

    private func sourceMetadata(for url: URL) async -> (kind: MacSourceFile.Kind, duration: Double?) {
        let type = UTType(filenameExtension: url.pathExtension)

        if type?.conforms(to: .movie) == true || type?.conforms(to: .audiovisualContent) == true {
            let durationTime = try? await AVURLAsset(url: url).load(.duration)
            let duration = durationTime.map(CMTimeGetSeconds) ?? 0
            return (.video, duration.isFinite && duration > 0 ? duration : nil)
        }
        if type?.conforms(to: .image) == true {
            return (.image, nil)
        }
        if type?.conforms(to: .pdf) == true {
            return (.pdf, nil)
        }
        if type?.conforms(to: .text) == true || type?.conforms(to: .plainText) == true {
            return (.text, nil)
        }
        return (.file, nil)
    }

    private func setReadyMessage() {
        let fileLabel = sourceFiles.count == 1 ? "file" : "files"
        setMessage(
            "\(sourceFiles.count) \(fileLabel) ready. \(usesAutomaticSettings ? "Auto" : "Manual"): \(String(format: "%.1f", interval))s interval.",
            isError: false
        )
    }

    private func setMessage(_ value: String?, isError: Bool) {
        message = value
        messageIsError = isError
    }

    private func removeResultImages() {
        let urls = Set(results.compactMap(\.imageURL))
        for url in urls {
            try? FileManager.default.removeItem(at: url)
        }
    }
}
