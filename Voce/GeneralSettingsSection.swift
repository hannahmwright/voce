import AppKit
import SwiftUI
import VoceKit

struct GeneralSettingsSection: View {
    @Binding var preferences: AppPreferences
    let launchAtLoginWarning: String
    @EnvironmentObject private var updaterController: UpdaterController
    @State private var isTypingSpeedTestVisible = false
    @State private var typingTestMeasuredWPM: Double = 0

    var body: some View {
        Group {
            settingsCard("Profile") {
                VStack(alignment: .leading, spacing: VoceDesign.xs) {
                    settingInlineLabel(
                        "Name",
                        help: "Shown in the Home greeting. Defaults to your Mac name."
                    )

                    TextField("Your name", text: displayNameBinding)
                        .textFieldStyle(.plain)
                        .settingsInputChrome()
                }
            }

            settingsCard("App") {
                VStack(alignment: .leading, spacing: VoceDesign.xs) {
                    settingInlineLabel(
                        "Appearance",
                        help: "Choose whether Voce follows macOS or stays in a fixed light or dark appearance."
                    )

                    Picker("Appearance", selection: $preferences.general.appearancePreference) {
                        ForEach(AppAppearancePreference.allCases, id: \.self) { option in
                            Text(option.title).tag(option)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }

                VStack(alignment: .leading, spacing: VoceDesign.xs) {
                    settingInlineLabel(
                        "Bubble",
                        help: "Choose how the floating dictation bubble looks while Voce is listening or processing."
                    )

                    Picker("Bubble", selection: $preferences.general.bubbleAppearance) {
                        ForEach(OverlayBubbleAppearance.allCases, id: \.self) { option in
                            Text(option.title).tag(option)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }

                Toggle(isOn: $preferences.general.launchAtLoginEnabled) {
                    settingInlineLabel(
                        "Launch on login",
                        help: "Open Voce automatically when you sign in."
                    )
                }

                if !launchAtLoginWarning.isEmpty {
                    Text(launchAtLoginWarning)
                        .font(VoceDesign.caption())
                        .foregroundStyle(VoceDesign.error)
                        .padding(.horizontal, VoceDesign.md)
                        .padding(.vertical, VoceDesign.sm)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(VoceDesign.errorBackground)
                        .overlay(
                            RoundedRectangle(cornerRadius: VoceDesign.radiusSmall, style: .continuous)
                                .stroke(VoceDesign.errorBorder, lineWidth: VoceDesign.borderThin)
                        )
                        .clipShape(RoundedRectangle(cornerRadius: VoceDesign.radiusSmall, style: .continuous))
                }

                Toggle(isOn: $preferences.general.showDockIcon) {
                    settingInlineLabel(
                        "Show in Dock",
                        help: "Keep Voce visible in the Dock."
                    )
                }

                Button {
                    preferences.general.showOnboarding = true
                } label: {
                    HStack(spacing: VoceDesign.xs) {
                        Image(systemName: "play.circle.fill")
                            .font(.system(size: 15, weight: .semibold))

                        Text("Show welcome")
                            .font(VoceDesign.callout())
                    }
                    .foregroundStyle(VoceDesign.warmAccentText)
                    .padding(.horizontal, VoceDesign.lg)
                    .padding(.vertical, VoceDesign.sm + 1)
                    .background(
                        Capsule()
                            .fill(VoceDesign.warmAccentFill)
                    )
                }
                .buttonStyle(.plain)
            }

            settingsCard("Typing speed") {
                VStack(alignment: .leading, spacing: VoceDesign.md) {
                    if isTypingSpeedTestVisible {
                        TypingSpeedTestView(
                            bestWordsPerMinute: $preferences.metricsBestTypingWordsPerMinute,
                            measuredWordsPerMinute: $typingTestMeasuredWPM,
                            autofocus: true,
                            onDone: {
                                isTypingSpeedTestVisible = false
                            }
                        )
                    } else {
                        HStack(alignment: .center, spacing: VoceDesign.md) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text("Measure typing speed")
                                    .font(VoceDesign.callout())
                                    .foregroundStyle(VoceDesign.textPrimary)

                                Text("Retake the 30-second baseline anytime. Voce uses your best score for time-saved estimates.")
                                    .font(VoceDesign.caption())
                                    .foregroundStyle(VoceDesign.textSecondary)
                            }

                            Spacer(minLength: 0)

                            VStack(alignment: .trailing, spacing: 2) {
                                Text("\(formattedWordsPerMinute(preferences.metricsBestTypingWordsPerMinute)) WPM")
                                    .font(VoceDesign.heading3())
                                    .foregroundStyle(VoceDesign.textPrimary)
                                    .monospacedDigit()

                                Text("Best")
                                    .font(VoceDesign.caption())
                                    .foregroundStyle(VoceDesign.textSecondary)
                            }

                            Button {
                                typingTestMeasuredWPM = 0
                                isTypingSpeedTestVisible = true
                            } label: {
                                Label("Start test", systemImage: "keyboard")
                                    .font(VoceDesign.captionEmphasis())
                            }
                            .buttonStyle(.borderedProminent)
                        }
                    }
                }
            }

            settingsCard("Updates") {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Check for updates")
                            .font(VoceDesign.callout())
                            .foregroundStyle(VoceDesign.textPrimary)

                        Text("Get the latest version of Voce.")
                            .font(VoceDesign.caption())
                            .foregroundStyle(VoceDesign.textSecondary)
                    }

                    Spacer()

                    Button("Check now") {
                        updaterController.checkForUpdates()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!updaterController.canCheckForUpdates)
                }
            }

            settingsCard("Licenses") {
                VStack(alignment: .leading, spacing: VoceDesign.sm) {
                    Text("Portions of this software are based on steno by Ankit Cherian.")
                        .font(VoceDesign.callout())
                        .foregroundStyle(VoceDesign.textPrimary)

                    Text("MIT License. Copyright (c) 2026 Ankit Cherian.")
                        .font(VoceDesign.caption())
                        .foregroundStyle(VoceDesign.textSecondary)

                    DisclosureGroup("View license notice") {
                        Text(Self.stenoMITLicense)
                            .font(VoceDesign.font(size: 11))
                            .foregroundStyle(VoceDesign.textSecondary)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.top, VoceDesign.sm)
                    }
                    .font(VoceDesign.captionEmphasis())
                    .foregroundStyle(VoceDesign.textPrimary)
                }
            }
        }
    }

    private var displayNameBinding: Binding<String> {
        Binding(
            get: {
                let current = preferences.general.userName.trimmingCharacters(in: .whitespacesAndNewlines)
                return current.isEmpty ? macOSFirstName : current
            },
            set: { newValue in
                preferences.general.userName = newValue
            }
        )
    }

    private var macOSFirstName: String {
        let fullName = NSFullUserName().trimmingCharacters(in: .whitespacesAndNewlines)
        let firstName = fullName.components(separatedBy: " ").first ?? fullName
        return firstName.isEmpty ? "" : firstName
    }

    private func formattedWordsPerMinute(_ value: Double) -> String {
        guard value.isFinite, value > 0 else { return "0" }
        return "\(Int(value.rounded()))"
    }

    private static let stenoMITLicense = """
    MIT License

    Copyright (c) 2026 Ankit Cherian

    Permission is hereby granted, free of charge, to any person obtaining a copy
    of this software and associated documentation files (the "Software"), to deal
    in the Software without restriction, including without limitation the rights
    to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
    copies of the Software, and to permit persons to whom the Software is
    furnished to do so, subject to the following conditions:

    The above copyright notice and this permission notice shall be included in all
    copies or substantial portions of the Software.

    THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
    IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
    FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
    AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
    LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
    OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
    SOFTWARE.
    """
}

struct TypingSpeedTestView: View {
    @Binding var bestWordsPerMinute: Double
    @Binding var measuredWordsPerMinute: Double
    var autofocus: Bool = false
    var onBestUpdated: (Double) -> Void = { _ in }
    var onDone: (() -> Void)?

    @FocusState private var isTypingFocused: Bool
    @State private var typedText = ""
    @State private var startedAt: Date?
    @State private var finishedAt: Date?
    @State private var now = Date()
    @State private var finalAccuracy: Double = 1
    @State private var focusIndicatorVisible = true

    private static let durationSeconds: TimeInterval = 30
    private static let prompt = """
    Alice was beginning to get very tired of sitting by her sister on the bank, and of having nothing to do. Once or twice she had peeped into the book her sister was reading, but it had no pictures or conversations in it. What is the use of a book, thought Alice, without pictures or conversation? So she was considering in her own mind whether the pleasure of making a daisy chain would be worth the trouble of getting up and picking the daisies, when suddenly a white rabbit with pink eyes ran close by her.
    """

    private var elapsedSeconds: TimeInterval {
        guard let startedAt else { return 0 }
        return max(0, (finishedAt ?? now).timeIntervalSince(startedAt))
    }

    private var remainingSeconds: Int {
        guard startedAt != nil else { return Int(Self.durationSeconds) }
        return max(0, Int(ceil(Self.durationSeconds - elapsedSeconds)))
    }

    private var isRunning: Bool {
        startedAt != nil && finishedAt == nil
    }

    private var hasFinished: Bool {
        finishedAt != nil
    }

    private var currentStats: TypingSpeedStats {
        typingStats(for: typedText)
    }

    private var displayedWordsPerMinute: Double {
        if hasFinished {
            return measuredWordsPerMinute
        }
        return wordsPerMinute(correctCharacterCount: currentStats.correctCharacterCount, elapsedSeconds: elapsedSeconds)
    }

    private var displayedAccuracy: Double {
        hasFinished ? finalAccuracy : currentStats.accuracy
    }

    private var targetWords: [String] {
        Self.prompt.split(separator: " ").map(String.init)
    }

    private var typedWords: [String] {
        let normalized = typedText.replacingOccurrences(of: "\n", with: " ")
        guard !normalized.isEmpty else { return [] }
        return normalized.components(separatedBy: " ")
    }

    private var typedTextBinding: Binding<String> {
        Binding(
            get: { typedText },
            set: { newValue in
                guard !hasFinished else { return }
                typedText = newValue
            }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: VoceDesign.md) {
            HStack(alignment: .top, spacing: VoceDesign.md) {
                typingSpeedStat(
                    title: hasFinished ? "Result" : "Speed",
                    value: formattedWordsPerMinute(displayedWordsPerMinute),
                    unit: "WPM"
                )

                typingSpeedStat(
                    title: "Accuracy",
                    value: "\(Int((displayedAccuracy * 100).rounded()))",
                    unit: "%"
                )

                typingSpeedStat(
                    title: "Time",
                    value: "\(remainingSeconds)",
                    unit: "sec"
                )
            }

            VStack(alignment: .leading, spacing: VoceDesign.xs) {
                ZStack(alignment: .topLeading) {
                    VStack(alignment: .leading, spacing: VoceDesign.md) {
                        HStack(alignment: .center) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Typing test")
                                    .font(VoceDesign.bodyEmphasis())
                                    .foregroundStyle(VoceDesign.textPrimary)

                                Text("Type each word directly underneath it.")
                                    .font(VoceDesign.caption())
                                    .foregroundStyle(VoceDesign.textSecondary)
                            }

                            Spacer(minLength: 0)

                            Text(statusText)
                                .font(VoceDesign.captionEmphasis())
                                .foregroundStyle(statusColor)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(
                                Capsule()
                                    .fill(statusColor.opacity(isRunning || hasFinished ? 0.12 : 0.08))
                            )
                        }

                        TypingWordFlowLayout(horizontalSpacing: 2, verticalSpacing: 8) {
                            ForEach(Array(targetWords.enumerated()), id: \.offset) { index, word in
                                TypingWordTile(
                                    target: word,
                                    typed: typedWords.indices.contains(index) ? typedWords[index] : "",
                                    hasStarted: startedAt != nil,
                                    showsFocusIndicator: !hasFinished && !isRunning && typedText.isEmpty && index == 0,
                                    focusIndicatorVisible: focusIndicatorVisible
                                )
                            }

                            if typedWords.count > targetWords.count {
                                ForEach(Array(typedWords[targetWords.count...].enumerated()), id: \.offset) { _, word in
                                    TypingWordTile(
                                        target: "",
                                        typed: word,
                                        hasStarted: true,
                                        showsFocusIndicator: false,
                                        focusIndicatorVisible: false
                                    )
                                }
                            }
                        }
                    }
                    .padding(VoceDesign.md)
                    .frame(maxWidth: .infinity, alignment: .topLeading)

                    TextEditor(text: typedTextBinding)
                        .focused($isTypingFocused)
                        .font(VoceDesign.font(size: 16, weight: .semibold).monospaced())
                        .foregroundStyle(Color.clear)
                        .tint(VoceDesign.warmAccentText)
                        .scrollContentBackground(.hidden)
                        .padding(VoceDesign.sm)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .opacity(hasFinished ? 0 : 0.02)
                        .disabled(hasFinished)
                        .allowsHitTesting(!hasFinished)
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .background {
                    RoundedRectangle(cornerRadius: VoceDesign.radiusMedium, style: .continuous)
                        .fill(VoceDesign.surfaceSecondary.opacity(0.78))
                }
                .overlay(
                    RoundedRectangle(cornerRadius: VoceDesign.radiusMedium, style: .continuous)
                        .stroke(
                            isTypingFocused ? VoceDesign.warmAccentText.opacity(0.24) : Color.white.opacity(0.38),
                            lineWidth: isTypingFocused ? 1.2 : VoceDesign.borderThin
                        )
                )
                .contentShape(Rectangle())
                .onTapGesture {
                    guard !hasFinished else { return }
                    isTypingFocused = true
                }
            }

            HStack {
                if startedAt != nil || hasFinished {
                    Button {
                        resetTest()
                    } label: {
                        Label(hasFinished ? "Try again" : "Restart", systemImage: "arrow.counterclockwise")
                            .font(VoceDesign.captionEmphasis())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(VoceDesign.textPrimary)
                }

                if hasFinished, let onDone {
                    Button {
                        onDone()
                    } label: {
                        Label("Done", systemImage: "checkmark")
                            .font(VoceDesign.captionEmphasis())
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                }

                Spacer(minLength: 0)

                Text("Best: \(formattedWordsPerMinute(bestWordsPerMinute)) WPM")
                    .font(VoceDesign.caption())
                    .foregroundStyle(VoceDesign.textSecondary)
            }
        }
        .onAppear {
            startFocusIndicatorAnimation()
            guard autofocus else { return }
            focusSoon()
        }
        .onChange(of: typedText) { _, newValue in
            handleTextChange(newValue)
        }
        .onChange(of: isTypingFocused) { _, _ in
            startFocusIndicatorAnimation()
        }
        .onReceive(Timer.publish(every: 0.1, on: .main, in: .common).autoconnect()) { tick in
            guard isRunning else { return }
            now = tick
            if elapsedSeconds >= Self.durationSeconds {
                finishTest(at: tick)
            }
        }
        .onReceive(Timer.publish(every: 0.6, on: .main, in: .common).autoconnect()) { _ in
            guard !isRunning, !hasFinished else {
                focusIndicatorVisible = true
                return
            }
            focusIndicatorVisible.toggle()
        }
    }

    private var statusText: String {
        if hasFinished {
            return "\(formattedWordsPerMinute(measuredWordsPerMinute)) WPM saved"
        }
        if isRunning {
            return "Keep typing"
        }
        return "30-second test"
    }

    private var statusColor: Color {
        if hasFinished {
            return VoceDesign.success
        }
        if isRunning {
            return VoceDesign.warmAccentText
        }
        return VoceDesign.textSecondary
    }

    private func handleTextChange(_ newValue: String) {
        guard !hasFinished else { return }
        measuredWordsPerMinute = 0
        guard !newValue.isEmpty else {
            startedAt = nil
            now = Date()
            finalAccuracy = 1
            return
        }

        if startedAt == nil {
            let started = Date()
            startedAt = started
            now = started
        }
    }

    private func finishTest(at finishTime: Date) {
        guard finishedAt == nil else { return }
        finishedAt = finishTime
        now = finishTime
        isTypingFocused = false

        let stats = typingStats(for: typedText)
        let result = wordsPerMinute(
            correctCharacterCount: stats.correctCharacterCount,
            elapsedSeconds: Self.durationSeconds
        )
        measuredWordsPerMinute = result
        finalAccuracy = stats.accuracy

        if result > bestWordsPerMinute {
            bestWordsPerMinute = result
            onBestUpdated(result)
        }
    }

    private func resetTest() {
        typedText = ""
        startedAt = nil
        finishedAt = nil
        measuredWordsPerMinute = 0
        finalAccuracy = 1
        now = Date()
        focusSoon()
    }

    private func focusSoon() {
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 120_000_000)
            isTypingFocused = true
        }
    }

    private func startFocusIndicatorAnimation() {
        focusIndicatorVisible = true
    }

    private func typingStats(for text: String) -> TypingSpeedStats {
        let targets = targetWords
        let attempts = text
            .replacingOccurrences(of: "\n", with: " ")
            .components(separatedBy: " ")
            .filter { !$0.isEmpty }
        guard !attempts.isEmpty else {
            return TypingSpeedStats(correctCharacterCount: 0, typedCharacterCount: 0, accuracy: 1)
        }

        var correctWords = 0
        var correctCharacters = 0
        for (index, attempt) in attempts.enumerated() {
            guard index < targets.count, attempt == targets[index] else { continue }
            correctWords += 1
            correctCharacters += targets[index].count
        }

        let accuracy = Double(correctWords) / Double(attempts.count)
        return TypingSpeedStats(
            correctCharacterCount: correctCharacters,
            typedCharacterCount: attempts.joined().count,
            accuracy: accuracy
        )
    }

    private func wordsPerMinute(correctCharacterCount: Int, elapsedSeconds: TimeInterval) -> Double {
        guard correctCharacterCount > 0, elapsedSeconds > 0.5 else { return 0 }
        return (Double(correctCharacterCount) / 5.0) / (elapsedSeconds / 60.0)
    }

    private func formattedWordsPerMinute(_ value: Double) -> String {
        guard value.isFinite, value > 0 else { return "0" }
        return "\(Int(value.rounded()))"
    }

    private func typingSpeedStat(title: String, value: String, unit: String) -> some View {
        VStack(alignment: .leading, spacing: VoceDesign.xxs) {
            Text(title)
                .font(VoceDesign.caption())
                .foregroundStyle(VoceDesign.textSecondary)

            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(value)
                    .font(VoceDesign.heading3())
                    .foregroundStyle(VoceDesign.textPrimary)
                    .monospacedDigit()

                Text(unit)
                    .font(VoceDesign.captionEmphasis())
                    .foregroundStyle(VoceDesign.textSecondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(VoceDesign.md)
        .background {
            RoundedRectangle(cornerRadius: VoceDesign.radiusMedium, style: .continuous)
                .fill(VoceDesign.surface.opacity(0.44))
        }
        .overlay(
            RoundedRectangle(cornerRadius: VoceDesign.radiusMedium, style: .continuous)
                .stroke(VoceDesign.border, lineWidth: VoceDesign.borderThin)
        )
    }
}

private struct TypingSpeedStats {
    var correctCharacterCount: Int
    var typedCharacterCount: Int
    var accuracy: Double
}

private struct TypingWordTile: View {
    let target: String
    let typed: String
    let hasStarted: Bool
    let showsFocusIndicator: Bool
    let focusIndicatorVisible: Bool

    private let correctTextColor = Color(red: 0.30, green: 0.78, blue: 0.42)
    private let errorTextColor = Color(red: 1.00, green: 0.42, blue: 0.36)

    private var typedFeedback: AttributedString {
        var output = AttributedString()
        let targetCharacters = Array(target)
        let typedCharacters = Array(typed)

        for index in typedCharacters.indices {
            var character = AttributedString(String(typedCharacters[index]))
            character.foregroundColor = index < targetCharacters.count && typedCharacters[index] == targetCharacters[index]
                ? correctTextColor
                : errorTextColor
            output.append(character)
        }

        if output.characters.isEmpty {
            var placeholder = AttributedString(" ")
            placeholder.foregroundColor = VoceDesign.textSecondary.opacity(0.36)
            output.append(placeholder)
        }

        return output
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(target.isEmpty ? " " : target)
                .font(VoceDesign.font(size: 14, weight: .bold).monospaced())
                .foregroundStyle(VoceDesign.textPrimary)
                .lineLimit(1)

            HStack(spacing: 2) {
                if showsFocusIndicator {
                    RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                        .fill(VoceDesign.warmAccentText)
                        .frame(width: 3, height: 15)
                        .opacity(focusIndicatorVisible ? 1 : 0.15)
                }

                Text(typedFeedback)
                    .font(VoceDesign.font(size: 14, weight: .bold).monospaced())
                    .lineLimit(1)
            }
            .frame(minHeight: 18, alignment: .leading)
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 3)
    }
}

private struct TypingWordFlowLayout: Layout {
    var horizontalSpacing: CGFloat = 8
    var verticalSpacing: CGFloat = 12

    struct Cache {
        var rows: [FlowRow] = []
        var size: CGSize = .zero
        var width: CGFloat = 0
    }

    func makeCache(subviews: Subviews) -> Cache {
        Cache()
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) -> CGSize {
        let maxWidth = proposal.width ?? subviews.reduce(0) { width, subview in
            width + subview.sizeThatFits(.unspecified).width + horizontalSpacing
        }
        cache = layout(subviews: subviews, maxWidth: maxWidth)
        return cache.size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) {
        if cache.rows.isEmpty || abs(cache.width - bounds.width) > 0.5 {
            cache = layout(subviews: subviews, maxWidth: bounds.width)
        }

        for row in cache.rows {
            for item in row.items {
                subviews[item.index].place(
                    at: CGPoint(x: bounds.minX + item.x, y: bounds.minY + row.y),
                    proposal: ProposedViewSize(item.size)
                )
            }
        }
    }

    private func layout(subviews: Subviews, maxWidth: CGFloat) -> Cache {
        var rows: [FlowRow] = []
        var currentItems: [FlowItem] = []
        var currentWidth: CGFloat = 0
        var currentHeight: CGFloat = 0
        var y: CGFloat = 0
        let availableWidth = max(maxWidth, 1)

        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let itemWidth = min(size.width, availableWidth)
            let spacing = currentItems.isEmpty ? 0 : horizontalSpacing

            if !currentItems.isEmpty, currentWidth + spacing + itemWidth > availableWidth {
                rows.append(FlowRow(y: y, height: currentHeight, items: currentItems))
                y += currentHeight + verticalSpacing
                currentItems = []
                currentWidth = 0
                currentHeight = 0
            }

            let x = currentItems.isEmpty ? 0 : currentWidth + horizontalSpacing
            currentItems.append(FlowItem(index: index, x: x, size: CGSize(width: itemWidth, height: size.height)))
            currentWidth = x + itemWidth
            currentHeight = max(currentHeight, size.height)
        }

        if !currentItems.isEmpty {
            rows.append(FlowRow(y: y, height: currentHeight, items: currentItems))
            y += currentHeight
        }

        return Cache(rows: rows, size: CGSize(width: availableWidth, height: y), width: availableWidth)
    }
}

private struct FlowRow {
    var y: CGFloat
    var height: CGFloat
    var items: [FlowItem]
}

private struct FlowItem {
    var index: Int
    var x: CGFloat
    var size: CGSize
}
