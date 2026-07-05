import AppKit
import SwiftUI

struct MacImagePreviewView: View {
    let result: MacOCRFrameResult
    @Environment(\.dismiss) private var dismiss
    @State private var copiedText: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(result.timestampLabel)
                    .font(.headline)
                Spacer()
                Button("Done") {
                    dismiss()
                }
                .keyboardShortcut(.escape, modifiers: [])
            }
            .padding()

            Divider()

            ZoomableMacFrameView(result: result) { text in
                copiedText = text
            }
            .overlay(alignment: .bottom) {
                if let copiedText {
                    Text("Copied: \(copiedText)")
                        .font(.callout.weight(.medium))
                        .lineLimit(1)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(.regularMaterial)
                        .clipShape(Capsule())
                        .padding(.bottom, 18)
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                        .task(id: copiedText) {
                            try? await Task.sleep(for: .seconds(1.5))
                            if self.copiedText == copiedText {
                                withAnimation(.easeOut(duration: 0.2)) {
                                    self.copiedText = nil
                                }
                            }
                        }
                }
            }
        }
        .frame(minWidth: 920, minHeight: 640)
    }
}

struct ZoomableMacFrameView: View {
    let result: MacOCRFrameResult
    let onCopied: (String) -> Void

    var body: some View {
        GeometryReader { proxy in
            if let imageURL = result.imageURL, let image = NSImage(contentsOf: imageURL) {
                let imageSize = image.size
                let scale = min(proxy.size.width / max(imageSize.width, 1), proxy.size.height / max(imageSize.height, 1))
                let displaySize = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
                let origin = CGPoint(
                    x: (proxy.size.width - displaySize.width) / 2,
                    y: (proxy.size.height - displaySize.height) / 2
                )

                ZStack(alignment: .topLeading) {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Color.black)

                    ForEach(result.lines) { line in
                        let rect = CGRect(
                            x: origin.x + line.x * displaySize.width,
                            y: origin.y + (1.0 - line.y - line.height) * displaySize.height,
                            width: line.width * displaySize.width,
                            height: line.height * displaySize.height
                        )

                        Button {
                            copy(line.text)
                            onCopied(line.text)
                        } label: {
                            Rectangle()
                                .fill(Color.accentColor.opacity(0.14))
                                .overlay(Rectangle().stroke(Color.accentColor.opacity(0.8), lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                        .frame(width: max(rect.width, 8), height: max(rect.height, 8))
                        .position(x: rect.midX, y: rect.midY)
                        .help(line.text)
                    }
                }
            } else {
                ContentUnavailableView("Image unavailable", systemImage: "photo")
            }
        }
        .background(Color.black)
    }

    private func copy(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }
}
