#if os(macOS)
import AppKit

enum TranscriptOverlayLayout {
    static let compactSize = NSSize(width: 100, height: 50)
    static let maximumTranscriptSize = NSSize(width: 372, height: 102)
    static let minimumTranscriptHeight: CGFloat = 58
    static let transcriptTextInset: CGFloat = 4

    private static let transcriptHorizontalPadding: CGFloat = 24
    private static let transcriptVerticalPadding: CGFloat = 20
    private static let textWidth = maximumTranscriptSize.width - (transcriptHorizontalPadding * 2)

    static func attributedText(_ text: String, shadow: NSShadow) -> NSAttributedString {
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.alignment = .center
        paragraphStyle.lineBreakMode = .byWordWrapping
        paragraphStyle.lineSpacing = 1.5

        return NSAttributedString(
            string: text,
            attributes: [
                .font: NSFont.systemFont(ofSize: 15, weight: .semibold),
                .foregroundColor: NSColor(calibratedWhite: 0.18, alpha: 0.88),
                .paragraphStyle: paragraphStyle,
                .shadow: shadow
            ]
        )
    }

    static func measuredTextHeight(for attributedText: NSAttributedString) -> CGFloat {
        let storage = NSTextStorage(attributedString: attributedText)
        let layoutManager = NSLayoutManager()
        let textContainer = NSTextContainer(size: NSSize(width: textWidth, height: .greatestFiniteMagnitude))
        textContainer.lineFragmentPadding = 0
        textContainer.widthTracksTextView = false
        textContainer.heightTracksTextView = false
        layoutManager.addTextContainer(textContainer)
        storage.addLayoutManager(layoutManager)
        _ = layoutManager.glyphRange(for: textContainer)
        return ceil(layoutManager.usedRect(for: textContainer).height)
    }

    static func bubbleSize(forTextHeight textHeight: CGFloat, previousHeight: CGFloat?) -> NSSize {
        NSSize(
            width: maximumTranscriptSize.width,
            height: bubbleHeight(forTextHeight: textHeight, previousHeight: previousHeight)
        )
    }

    static func bubbleHeight(forTextHeight textHeight: CGFloat, previousHeight: CGFloat?) -> CGFloat {
        let requestedHeight = min(
            maximumTranscriptSize.height,
            max(minimumTranscriptHeight, ceil(textHeight + (transcriptVerticalPadding * 2)))
        )

        guard let previousHeight else { return requestedHeight }
        return max(previousHeight, requestedHeight)
    }

    static func shouldScrollToLatest(textHeight: CGFloat, bubbleHeight: CGFloat) -> Bool {
        contentHeight(forTextHeight: textHeight) > visibleTextHeight(forBubbleHeight: bubbleHeight)
    }

    private static func contentHeight(forTextHeight textHeight: CGFloat) -> CGFloat {
        ceil(textHeight)
    }

    private static func visibleTextHeight(forBubbleHeight bubbleHeight: CGFloat) -> CGFloat {
        bubbleHeight - (transcriptVerticalPadding * 2)
    }
}
#endif
