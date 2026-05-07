import SwiftUI

struct ScratchPadTab: View {
    @Binding var content: String
    @Environment(\.colorScheme) private var colorScheme

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

            TextEditor(text: $content)
                .font(VoceDesign.body())
                .foregroundStyle(VoceDesign.textPrimary)
                .scrollContentBackground(.hidden)
                .padding(VoceDesign.md)
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
    }

    private var wordCount: some View {
        let count = content.split(whereSeparator: \.isWhitespace).count
        return Text("\(count) \(count == 1 ? "word" : "words")")
            .font(VoceDesign.caption())
            .foregroundStyle(VoceDesign.textSecondary)
    }
}
