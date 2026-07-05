import CoreGraphics
import Foundation

enum MacVideoOCREvent {
    case progress(Double)
    case frame(MacOCRFrameResult)
}

struct MacSourceFile: Identifiable, Hashable {
    enum Kind: String, Hashable {
        case video = "Video"
        case image = "Image"
        case pdf = "PDF"
        case text = "Text"
        case file = "File"
    }

    let id = UUID()
    let url: URL
    let kind: Kind
    let durationSeconds: Double?

    var displayName: String {
        url.lastPathComponent
    }
}

struct MacOCRFrameResult: Identifiable, Hashable {
    let id = UUID()
    let time: Double
    let lines: [MacOCRTextLine]
    let imageURL: URL?
    let customLabel: String?
    var sourceName: String? = nil

    var text: String {
        lines.map(\.text).joined(separator: "\n")
    }

    var timestampLabel: String {
        let base: String
        if let customLabel {
            base = customLabel
        } else {
            let totalSeconds = Int(time.rounded())
            let minutes = totalSeconds / 60
            let seconds = totalSeconds % 60
            base = String(format: "%02d:%02d", minutes, seconds)
        }
        if let sourceName, !sourceName.isEmpty {
            return "\(sourceName) · \(base)"
        }
        return base
    }
}

struct MacOCRTextLine: Identifiable, Hashable {
    let id = UUID()
    let text: String
    let x: Double
    let y: Double
    let width: Double
    let height: Double

    var boundingBox: CGRect {
        CGRect(x: x, y: y, width: width, height: height)
    }
}

enum MacVideoOCRError: LocalizedError {
    case unreadableFile
    case unreadableDocument

    var errorDescription: String? {
        switch self {
        case .unreadableFile:
            return "The selected file could not be read."
        case .unreadableDocument:
            return "The selected document could not be read."
        }
    }
}
