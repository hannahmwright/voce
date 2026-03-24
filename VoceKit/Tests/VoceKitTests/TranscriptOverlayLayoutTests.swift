import AppKit
import Testing
@testable import VoceKit

@Test("TranscriptOverlayLayout grows from one line to three lines before capping")
func transcriptOverlayLayoutGrows() {
    #expect(TranscriptOverlayLayout.bubbleHeight(forTextHeight: 18, previousHeight: nil) == 58)
    #expect(TranscriptOverlayLayout.bubbleHeight(forTextHeight: 37.5, previousHeight: nil) == 78)
    #expect(TranscriptOverlayLayout.bubbleHeight(forTextHeight: 57, previousHeight: nil) == 97)
    #expect(TranscriptOverlayLayout.bubbleHeight(forTextHeight: 115.5, previousHeight: nil) == 102)
}

@Test("TranscriptOverlayLayout does not shrink once the bubble has expanded")
func transcriptOverlayLayoutDoesNotShrink() {
    let expandedHeight = TranscriptOverlayLayout.bubbleHeight(forTextHeight: 57, previousHeight: nil)
    let shorterRevision = TranscriptOverlayLayout.bubbleHeight(
        forTextHeight: 18,
        previousHeight: expandedHeight
    )

    #expect(expandedHeight == 97)
    #expect(shorterRevision == expandedHeight)
}

@Test("TranscriptOverlayLayout only scrolls once the transcript exceeds the visible three-line area")
func transcriptOverlayLayoutScrollThreshold() {
    #expect(TranscriptOverlayLayout.shouldScrollToLatest(textHeight: 57, bubbleHeight: 97) == false)
    #expect(TranscriptOverlayLayout.shouldScrollToLatest(textHeight: 115.5, bubbleHeight: 102) == true)
}
