import AppKit
import SwiftUI

struct ScratchPadTab: View {
    @Binding var content: String
    let isActive: Bool
    @Environment(\.colorScheme) private var colorScheme
    @State private var focusRequestID = UUID()

    var body: some View {
        VStack(alignment: .leading, spacing: VoceDesign.md) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: VoceDesign.xxs) {
                    Text("Scratch Pad")
                        .font(VoceDesign.font(size: 28, weight: .bold))
                        .foregroundStyle(VoceDesign.textPrimary)
                        .accessibilityAddTraits(.isHeader)

                    Text("A quick place to draft, brainstorm, or stash text.")
                        .font(VoceDesign.subheadline())
                        .foregroundStyle(VoceDesign.textSecondary)
                }

                Spacer()

                if !content.isEmpty {
                    HStack(spacing: VoceDesign.sm) {
                        wordCount

                        Button {
                            let pasteboard = NSPasteboard.general
                            pasteboard.clearContents()
                            pasteboard.setString(content, forType: .string)
                        } label: {
                            Label("Copy All", systemImage: "doc.on.doc")
                                .font(VoceDesign.captionEmphasis())
                                .foregroundStyle(VoceDesign.textSecondary)
                        }
                        .buttonStyle(.plain)

                        Button(role: .destructive) {
                            content = ""
                        } label: {
                            Label("Clear", systemImage: "trash")
                                .font(VoceDesign.captionEmphasis())
                                .foregroundStyle(VoceDesign.textSecondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            ScratchPadTextView(
                text: $content,
                focusRequestID: focusRequestID
            )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background {
                    RoundedRectangle(cornerRadius: VoceDesign.radiusMedium, style: .continuous)
                        .fill(VoceDesign.surface.opacity(0.48))
                        .overlay(
                            RoundedRectangle(cornerRadius: VoceDesign.radiusMedium, style: .continuous)
                                .fill(.ultraThinMaterial.opacity(0.24))
                        )
                }
                .overlay(
                    RoundedRectangle(cornerRadius: VoceDesign.radiusMedium, style: .continuous)
                        .stroke(VoceDesign.border, lineWidth: VoceDesign.borderThin)
                )
        }
        .padding(VoceDesign.lg)
        .onAppear {
            requestFocusIfActive()
        }
        .onChange(of: isActive) { _, newValue in
            guard newValue else { return }
            requestFocusIfActive()
        }
    }

    private var wordCount: some View {
        let count = content.split(whereSeparator: \.isWhitespace).count
        return Text("\(count) \(count == 1 ? "word" : "words")")
            .font(VoceDesign.caption())
            .foregroundStyle(VoceDesign.textSecondary)
    }

    private func requestFocusIfActive() {
        guard isActive else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(80))
            guard isActive else { return }
            focusRequestID = UUID()
        }
    }
}

private struct ScratchPadTextView: NSViewRepresentable {
    @Binding var text: String
    let focusRequestID: UUID

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true

        let textView = NSTextView()
        textView.drawsBackground = false
        textView.isRichText = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.allowsUndo = true
        textView.delegate = context.coordinator
        textView.font = NSFont.systemFont(ofSize: 15, weight: .regular)
        textView.textColor = NSColor.labelColor
        textView.insertionPointColor = NSColor.labelColor
        textView.textContainerInset = NSSize(width: VoceDesign.md, height: VoceDesign.md)
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(
            width: scrollView.contentSize.width,
            height: CGFloat.greatestFiniteMagnitude
        )

        scrollView.documentView = textView
        context.coordinator.textView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = context.coordinator.textView else { return }
        if textView.string != text {
            textView.string = text
        }
        textView.font = NSFont.systemFont(ofSize: 15, weight: .regular)
        textView.textColor = NSColor.labelColor
        textView.insertionPointColor = NSColor.labelColor

        if context.coordinator.lastFocusRequestID != focusRequestID {
            context.coordinator.lastFocusRequestID = focusRequestID
            DispatchQueue.main.async {
                focusAtEnd(textView, retriesRemaining: 2)
            }
        }
    }

    private func focusAtEnd(_ textView: NSTextView, retriesRemaining: Int) {
        guard let window = textView.window else {
            guard retriesRemaining > 0 else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                focusAtEnd(textView, retriesRemaining: retriesRemaining - 1)
            }
            return
        }
        window.makeFirstResponder(textView)
        let endLocation = textView.string.utf16.count
        textView.setSelectedRange(NSRange(location: endLocation, length: 0))
        textView.scrollRangeToVisible(NSRange(location: endLocation, length: 0))
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        @Binding var text: String
        weak var textView: NSTextView?
        var lastFocusRequestID: UUID?

        init(text: Binding<String>) {
            _text = text
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            text = textView.string
        }
    }
}
