import AppKit
import AVFoundation
import CoreGraphics
import Foundation
import PDFKit
import UniformTypeIdentifiers
import Vision

final class MacOCRService {
    func recognizeText(
        in fileURL: URL,
        interval: Double,
        language: String,
        centerCropRatio: Double = 0.7
    ) throws -> AsyncThrowingStream<MacVideoOCREvent, Error> {
        let cropRatio = min(max(centerCropRatio, 0.0), 1.0)
        let type = UTType(filenameExtension: fileURL.pathExtension)

        if type?.conforms(to: .text) == true || type?.conforms(to: .plainText) == true {
            return recognizeTextFile(fileURL)
        }

        if type?.conforms(to: .pdf) == true {
            return recognizePDF(fileURL, language: language, cropRatio: cropRatio)
        }

        if type?.conforms(to: .image) == true {
            return recognizeImage(fileURL, language: language, cropRatio: cropRatio)
        }

        return try recognizeVideo(fileURL, interval: interval, language: language, cropRatio: cropRatio)
    }

    private func recognizeTextFile(_ fileURL: URL) -> AsyncThrowingStream<MacVideoOCREvent, Error> {
        AsyncThrowingStream { continuation in
            Task.detached(priority: .userInitiated) {
                do {
                    let content = try String(contentsOf: fileURL, encoding: .utf8)
                    let textLines = content.components(separatedBy: .newlines)
                        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                        .filter { !$0.isEmpty }

                    let ocrLines = textLines.enumerated().map { index, line in
                        MacOCRTextLine(
                            text: line,
                            x: 0.05,
                            y: 1.0 - Double(index + 1) * 0.05,
                            width: 0.9,
                            height: 0.04
                        )
                    }

                    if !ocrLines.isEmpty {
                        let image = Self.createPlaceholderImage(lines: textLines)
                        let imageURL = try? Self.saveFrameImage(image, label: "\(Self.fileSlug(fileURL))-text")
                        continuation.yield(.frame(MacOCRFrameResult(
                            time: 0,
                            lines: ocrLines,
                            imageURL: imageURL,
                            customLabel: "Text File",
                            sourceName: fileURL.lastPathComponent
                        )))
                    }

                    continuation.yield(.progress(1))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    private func recognizePDF(
        _ fileURL: URL,
        language: String,
        cropRatio: Double
    ) -> AsyncThrowingStream<MacVideoOCREvent, Error> {
        AsyncThrowingStream { continuation in
            Task.detached(priority: .userInitiated) {
                do {
                    guard let document = PDFDocument(url: fileURL) else {
                        throw MacVideoOCRError.unreadableDocument
                    }
                    let pageCount = document.pageCount
                    guard pageCount > 0 else {
                        continuation.yield(.progress(1))
                        continuation.finish()
                        return
                    }

                    for index in 0..<pageCount {
                        try Task.checkCancellation()
                        guard let page = document.page(at: index),
                              var image = Self.drawPDFPage(page) else { continue }

                        if cropRatio > 0, cropRatio < 1, let cropped = Self.centerCrop(image, ratio: cropRatio) {
                            image = cropped
                        }

                        let lines = try Self.recognizeLines(in: image, language: language)
                        if !lines.isEmpty {
                            let imageURL = try? Self.saveFrameImage(image, label: "\(Self.fileSlug(fileURL))-page-\(index + 1)")
                            continuation.yield(.frame(MacOCRFrameResult(
                                time: Double(index),
                                lines: lines,
                                imageURL: imageURL,
                                customLabel: "Page \(index + 1)",
                                sourceName: fileURL.lastPathComponent
                            )))
                        }

                        continuation.yield(.progress(Double(index + 1) / Double(pageCount)))
                    }

                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    private func recognizeImage(
        _ fileURL: URL,
        language: String,
        cropRatio: Double
    ) -> AsyncThrowingStream<MacVideoOCREvent, Error> {
        AsyncThrowingStream { continuation in
            Task.detached(priority: .userInitiated) {
                do {
                    guard let image = Self.cgImage(from: fileURL) else {
                        throw MacVideoOCRError.unreadableFile
                    }

                    var frame = image
                    if cropRatio > 0, cropRatio < 1, let cropped = Self.centerCrop(frame, ratio: cropRatio) {
                        frame = cropped
                    }

                    let lines = try Self.recognizeLines(in: frame, language: language)
                    if !lines.isEmpty {
                        let imageURL = try? Self.saveFrameImage(frame, label: "\(Self.fileSlug(fileURL))-image")
                        continuation.yield(.frame(MacOCRFrameResult(
                            time: 0,
                            lines: lines,
                            imageURL: imageURL,
                            customLabel: "Image",
                            sourceName: fileURL.lastPathComponent
                        )))
                    }

                    continuation.yield(.progress(1))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    private func recognizeVideo(
        _ fileURL: URL,
        interval: Double,
        language: String,
        cropRatio: Double
    ) throws -> AsyncThrowingStream<MacVideoOCREvent, Error> {
        AsyncThrowingStream { continuation in
            Task.detached(priority: .userInitiated) {
                do {
                    let asset = AVURLAsset(url: fileURL)
                    let durationTime = try await asset.load(.duration)
                    let duration = CMTimeGetSeconds(durationTime)

                    guard duration.isFinite, duration > 0 else {
                        throw MacVideoOCRError.unreadableFile
                    }

                    let generator = AVAssetImageGenerator(asset: asset)
                    generator.appliesPreferredTrackTransform = true
                    generator.maximumSize = CGSize(width: 1600, height: 1600)
                    generator.requestedTimeToleranceBefore = CMTime(seconds: 0.25, preferredTimescale: 600)
                    generator.requestedTimeToleranceAfter = CMTime(seconds: 0.25, preferredTimescale: 600)

                    var time = 0.0
                    var lastKeptFrameText = ""
                    var decodedAnyFrame = false
                    var firstDecodeError: Error?

                    while time <= duration {
                        try Task.checkCancellation()
                        var image: CGImage
                        do {
                            image = try generator.copyCGImage(
                                at: CMTime(seconds: time, preferredTimescale: 600),
                                actualTime: nil
                            )
                        } catch {
                            // The video track often ends slightly before the container
                            // duration (screen recordings especially), and single frames
                            // can fail to decode mid-file. Skip them instead of aborting
                            // the whole video.
                            if firstDecodeError == nil { firstDecodeError = error }
                            continuation.yield(.progress(min(time / duration, 1)))
                            time += max(interval, 0.5)
                            continue
                        }
                        decodedAnyFrame = true

                        if cropRatio > 0, cropRatio < 1, let cropped = Self.centerCrop(image, ratio: cropRatio) {
                            image = cropped
                        }

                        let lines = try Self.recognizeLines(in: image, language: language)
                        if !lines.isEmpty {
                            let frameText = lines.map(\.text).joined(separator: " ")
                            let similarity = Self.jaccardSimilarity(frameText, lastKeptFrameText)
                            if similarity < 0.8 {
                                lastKeptFrameText = frameText
                                let label = "\(Self.fileSlug(fileURL))-time-\(Int((time * 10).rounded()))"
                                let imageURL = try? Self.saveFrameImage(image, label: label)
                                continuation.yield(.frame(MacOCRFrameResult(
                                    time: time,
                                    lines: lines,
                                    imageURL: imageURL,
                                    customLabel: nil,
                                    sourceName: fileURL.lastPathComponent
                                )))
                            }
                        }

                        continuation.yield(.progress(min(time / duration, 1)))
                        time += max(interval, 0.5)
                    }

                    if !decodedAnyFrame, let firstDecodeError {
                        throw firstDecodeError
                    }

                    continuation.yield(.progress(1))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    private static func cgImage(from url: URL) -> CGImage? {
        guard let image = NSImage(contentsOf: url) else { return nil }
        var proposed = CGRect(origin: .zero, size: image.size)
        return image.cgImage(forProposedRect: &proposed, context: nil, hints: nil)
    }

    private static func centerCrop(_ image: CGImage, ratio: Double) -> CGImage? {
        guard ratio > 0, ratio < 1 else { return image }
        let fullWidth = Double(image.width)
        let fullHeight = Double(image.height)
        let cropWidth = fullWidth * ratio
        let cropHeight = fullHeight * ratio
        let rect = CGRect(
            x: (fullWidth - cropWidth) / 2,
            y: (fullHeight - cropHeight) / 2,
            width: cropWidth,
            height: cropHeight
        )
        return image.cropping(to: rect)
    }

    private static func recognizeLines(in image: CGImage, language: String) throws -> [MacOCRTextLine] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        // Detect the script per image instead of forcing a Latin-only (vi-VN/en-US)
        // language model, so CJK, Arabic, Cyrillic, etc. are recognized correctly.
        request.automaticallyDetectsLanguage = true
        request.minimumTextHeight = 0.008

        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try handler.perform([request])

        let rawLines = (request.results ?? [])
            .compactMap { observation -> MacOCRTextLine? in
                guard let text = observation.topCandidates(1).first?.string else { return nil }
                let cleaned = normalize(text)
                guard !cleaned.isEmpty else { return nil }
                let box = observation.boundingBox
                return MacOCRTextLine(
                    text: cleaned,
                    x: box.minX,
                    y: box.minY,
                    width: box.width,
                    height: box.height
                )
            }

        return sortLinesByReadingOrder(rawLines)
    }

    private static func sortLinesByReadingOrder(_ lines: [MacOCRTextLine]) -> [MacOCRTextLine] {
        let sortedByY = lines.sorted { $0.y > $1.y }
        var rows: [[MacOCRTextLine]] = []

        for line in sortedByY {
            if let rowIndex = rows.firstIndex(where: { row in
                guard let first = row.first else { return false }
                let centerY1 = first.y + first.height / 2
                let centerY2 = line.y + line.height / 2
                let avgHeight = (first.height + line.height) / 2
                return abs(centerY1 - centerY2) < max(avgHeight * 1.5, 0.03)
            }) {
                rows[rowIndex].append(line)
            } else {
                rows.append([line])
            }
        }

        return rows
            .sorted {
                let y1 = $0.reduce(0.0) { $0 + ($1.y + $1.height / 2) } / Double($0.count)
                let y2 = $1.reduce(0.0) { $0 + ($1.y + $1.height / 2) } / Double($1.count)
                return y1 > y2
            }
            .flatMap { $0.sorted { $0.x < $1.x } }
    }

    private static func jaccardSimilarity(_ text1: String, _ text2: String) -> Double {
        let words1 = Set(text1.lowercased().components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty })
        let words2 = Set(text2.lowercased().components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty })
        guard !words1.isEmpty || !words2.isEmpty else { return 0 }
        return Double(words1.intersection(words2).count) / Double(words1.union(words2).count)
    }

    private static func drawPDFPage(_ page: PDFPage) -> CGImage? {
        let pageRect = page.bounds(for: .mediaBox)
        guard pageRect.width > 0, pageRect.height > 0 else { return nil }

        // Let PDFKit render the page: thumbnail(of:for:) applies the page's
        // /Rotate metadata and coordinate flip itself, so pages come out
        // upright instead of upside down.
        let scale: CGFloat = 2.0
        let rotated = page.rotation % 180 != 0
        let targetSize = rotated
            ? CGSize(width: pageRect.height * scale, height: pageRect.width * scale)
            : CGSize(width: pageRect.width * scale, height: pageRect.height * scale)

        let thumbnail = page.thumbnail(of: targetSize, for: .mediaBox)
        var proposed = CGRect(origin: .zero, size: thumbnail.size)
        guard let cgImage = thumbnail.cgImage(forProposedRect: &proposed, context: nil, hints: nil) else {
            return nil
        }

        // Flatten onto white in case the page has a transparent background.
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: cgImage.width,
            height: cgImage.height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return cgImage }

        let drawRect = CGRect(x: 0, y: 0, width: cgImage.width, height: cgImage.height)
        context.setFillColor(NSColor.white.cgColor)
        context.fill(drawRect)
        context.draw(cgImage, in: drawRect)
        return context.makeImage() ?? cgImage
    }

    private static func createPlaceholderImage(lines: [String]) -> CGImage {
        let size = CGSize(width: 900, height: 640)
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor.white.setFill()
        NSRect(origin: .zero, size: size).fill()

        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 16),
            .foregroundColor: NSColor.black
        ]

        var y = size.height - 32
        for line in lines.prefix(26) {
            line.draw(in: CGRect(x: 24, y: y, width: size.width - 48, height: 22), withAttributes: attrs)
            y -= 22
        }
        if lines.count > 26 {
            "... (\(lines.count - 26) more lines)".draw(
                in: CGRect(x: 24, y: y, width: size.width - 48, height: 22),
                withAttributes: attrs
            )
        }
        image.unlockFocus()

        var proposed = CGRect(origin: .zero, size: size)
        return image.cgImage(forProposedRect: &proposed, context: nil, hints: nil)!
    }

    private static func normalize(_ text: String) -> String {
        text
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func saveFrameImage(_ image: CGImage, label: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("VideoOCRMacFrames", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("frame-\(label).jpg")
        if FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.removeItem(at: url)
        }

        let bitmap = NSBitmapImageRep(cgImage: image)
        guard let data = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.76]) else {
            throw MacVideoOCRError.unreadableFile
        }
        try data.write(to: url, options: .atomic)
        return url
    }

    /// Filename-safe identifier for a source file so saved frame previews from
    /// different files in the same batch never collide and overwrite each other.
    private static func fileSlug(_ url: URL) -> String {
        let base = url.deletingPathExtension().lastPathComponent
        let cleaned = String(base.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
        let name = String(cleaned.prefix(24))
        let hash = String(format: "%04x", abs(url.path.hashValue) % 0x10000)
        return name.isEmpty ? hash : "\(name)-\(hash)"
    }
}
