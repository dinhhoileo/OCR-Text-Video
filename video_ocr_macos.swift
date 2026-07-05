import Foundation
import AVFoundation
import Vision
import AppKit

struct Config {
    var videoPath: String?
    var outputPath = "video_ocr_output.md"
    var jsonlPath: String?
    var framesDir: String?
    var interval = 1.0
    var maxSize = 1600.0
    var language = "en-US"
    var minimumTextHeight = 0.008
    var centerCropRatio = 0.7
}

func printUsageAndExit() -> Never {
    print("""
    Usage:
      swift video_ocr_macos.swift <video-path> [options]

    Options:
      --output <path>        Markdown output path. Default: video_ocr_output.md
      --jsonl <path>         Optional raw JSONL output path
      --frames-dir <path>    Optional directory to save OCR frame images
      --interval <seconds>   Sample interval. Default: 1
      --max-size <pixels>    Max frame size for OCR. Default: 1600
      --language <tag>       OCR language. Default: en-US
      --center-crop <ratio>  Center crop ratio (0.0–1.0). Default: 0.7
                             1.0 = full frame, 0.7 = center 70%

    Example:
      swift video_ocr_macos.swift /Users/huynhdinhhoi/Desktop/IMG_4849.MOV --interval 1 --center-crop 0.7 --output IMG_4849_OCR.md
    """)
    exit(2)
}

var config = Config()
var args = Array(CommandLine.arguments.dropFirst())
while !args.isEmpty {
    let arg = args.removeFirst()
    switch arg {
    case "--output":
        guard let value = args.first else { printUsageAndExit() }
        config.outputPath = value
        args.removeFirst()
    case "--jsonl":
        guard let value = args.first else { printUsageAndExit() }
        config.jsonlPath = value
        args.removeFirst()
    case "--frames-dir":
        guard let value = args.first else { printUsageAndExit() }
        config.framesDir = value
        args.removeFirst()
    case "--interval":
        guard let value = args.first, let interval = Double(value), interval > 0 else { printUsageAndExit() }
        config.interval = interval
        args.removeFirst()
    case "--max-size":
        guard let value = args.first, let maxSize = Double(value), maxSize > 0 else { printUsageAndExit() }
        config.maxSize = maxSize
        args.removeFirst()
    case "--language":
        guard let value = args.first else { printUsageAndExit() }
        config.language = value
        args.removeFirst()
    case "--center-crop":
        guard let value = args.first, let ratio = Double(value), ratio >= 0.0, ratio <= 1.0 else { printUsageAndExit() }
        config.centerCropRatio = ratio
        args.removeFirst()
    case "--help", "-h":
        printUsageAndExit()
    default:
        if config.videoPath == nil {
            config.videoPath = arg
        } else {
            printUsageAndExit()
        }
    }
}

guard let videoPath = config.videoPath else { printUsageAndExit() }

let videoURL = URL(fileURLWithPath: videoPath)
if let framesDir = config.framesDir {
    try FileManager.default.createDirectory(
        at: URL(fileURLWithPath: framesDir),
        withIntermediateDirectories: true
    )
}

let asset = AVAsset(url: videoURL)
let durationSeconds = CMTimeGetSeconds(asset.duration)
guard durationSeconds.isFinite, durationSeconds > 0 else {
    fputs("Cannot read video duration: \(videoPath)\n", stderr)
    exit(1)
}

let generator = AVAssetImageGenerator(asset: asset)
generator.appliesPreferredTrackTransform = true
generator.maximumSize = CGSize(width: config.maxSize, height: config.maxSize)
generator.requestedTimeToleranceBefore = CMTime(seconds: 0.25, preferredTimescale: 600)
generator.requestedTimeToleranceAfter = CMTime(seconds: 0.25, preferredTimescale: 600)

let request = VNRecognizeTextRequest()
request.recognitionLevel = .accurate
request.usesLanguageCorrection = true
request.recognitionLanguages = [config.language]
request.minimumTextHeight = Float(config.minimumTextHeight)

func normalize(_ text: String) -> String {
    text
        .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        .trimmingCharacters(in: .whitespacesAndNewlines)
}

func normalizeForComparison(_ text: String) -> String {
    text.lowercased()
        .components(separatedBy: CharacterSet.alphanumerics.inverted)
        .joined()
}

/// Crop the center region of an image by keeping a `ratio` portion of width and height.
func centerCrop(_ image: CGImage, ratio: Double) -> CGImage? {
    let cropRatio = max(0.01, ratio)
    guard cropRatio < 1.0 else { return nil }
    let fullWidth = Double(image.width)
    let fullHeight = Double(image.height)
    let cropWidth = fullWidth * cropRatio
    let cropHeight = fullHeight * cropRatio
    let originX = (fullWidth - cropWidth) / 2.0
    let originY = (fullHeight - cropHeight) / 2.0
    let rect = CGRect(x: originX, y: originY, width: cropWidth, height: cropHeight)
    return image.cropping(to: rect)
}

func saveFrame(_ image: CGImage, time: Double) throws -> String? {
    guard let framesDir = config.framesDir else { return nil }
    let fileName = "frame-\(Int((time * 10).rounded())).jpg"
    let url = URL(fileURLWithPath: framesDir).appendingPathComponent(fileName)
    let rep = NSBitmapImageRep(cgImage: image)
    guard let data = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.76]) else {
        return nil
    }
    try data.write(to: url, options: .atomic)
    return url.path
}

fputs("Center crop: \(Int((config.centerCropRatio * 100).rounded()))%\n", stderr)

var markdown = "# Video OCR Output\n\n"
markdown += "- Source: `\(videoPath)`\n"
markdown += "- Interval: \(config.interval)s\n"
markdown += "- Center crop: \(Int((config.centerCropRatio * 100).rounded()))%\n\n"

var jsonl = ""
var t = 0.0
var recognizedLinesSet = Set<String>()

while t <= durationSeconds {
    autoreleasepool {
        do {
            let cmTime = CMTime(seconds: t, preferredTimescale: 600)
            var cgImage = try generator.copyCGImage(at: cmTime, actualTime: nil)

            // Apply center-focus cropping
            if config.centerCropRatio < 1.0, let cropped = centerCrop(cgImage, ratio: config.centerCropRatio) {
                cgImage = cropped
            }

            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            try handler.perform([request])

            let lines = (request.results ?? [])
                .compactMap { observation -> (String, CGRect)? in
                    guard let text = observation.topCandidates(1).first?.string else { return nil }
                    let cleaned = normalize(text)
                    guard !cleaned.isEmpty else { return nil }
                    return (cleaned, observation.boundingBox)
                }
                .sorted {
                    let yDelta = abs($0.1.midY - $1.1.midY)
                    if yDelta > 0.015 { return $0.1.midY > $1.1.midY }
                    return $0.1.minX < $1.1.minX
                }

            // Filter lines
            let newLines = lines.filter { line in
                let key = normalizeForComparison(line.0)
                return !recognizedLinesSet.contains(key)
            }

            if !newLines.isEmpty {
                for line in newLines {
                    recognizedLinesSet.insert(normalizeForComparison(line.0))
                }

                let displayLines = newLines.map { $0.0 }
                markdown += "## \(String(format: "%.1f", t))s\n\n"
                if let framePath = try saveFrame(cgImage, time: t) {
                    markdown += "![Frame \(String(format: "%.1f", t))s](\(framePath))\n\n"
                }
                markdown += displayLines
                    .map { "- \($0)" }
                    .joined(separator: "\n")
                markdown += "\n\n"

                let record: [String: Any] = [
                    "time": (t * 10).rounded() / 10,
                    "lines": displayLines
                ]
                let data = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
                jsonl += String(data: data, encoding: .utf8)! + "\n"
            }

            fputs("OCR \(String(format: "%.1f", t)) / \(String(format: "%.1f", durationSeconds))\n", stderr)
        } catch {
            fputs("Frame \(String(format: "%.1f", t)) failed: \(error)\n", stderr)
        }
    }
    t += config.interval
}

try markdown.write(toFile: config.outputPath, atomically: true, encoding: .utf8)
if let jsonlPath = config.jsonlPath {
    try jsonl.write(toFile: jsonlPath, atomically: true, encoding: .utf8)
}

print("Done: \(config.outputPath)")
if let jsonlPath = config.jsonlPath {
    print("Raw JSONL: \(jsonlPath)")
}
