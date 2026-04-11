import AppKit
import AVFoundation
import Foundation
import OSLog
import SwiftUI
import VoceKit

@MainActor
private final class ClipboardRecoveryPromptPresenter: NSObject {
    private var panel: NSPanel?
    private var globalClickMonitor: Any?
    private var pendingPasteTask: Task<Void, Never>?
    private var pasteAfterRefocus: (() async -> Bool)?
    private var copyToClipboard: (() -> Void)?

    func show(
        onCopy: @escaping () -> Void,
        onPasteAfterRefocus: @escaping () async -> Bool
    ) {
        ensurePanel()
        copyToClipboard = onCopy
        pasteAfterRefocus = onPasteAfterRefocus
        startMonitoring()
        positionPanel()
        panel?.alphaValue = 1
        panel?.orderFrontRegardless()
    }

    func hide() {
        pendingPasteTask?.cancel()
        pendingPasteTask = nil
        pasteAfterRefocus = nil
        copyToClipboard = nil

        if let globalClickMonitor {
            NSEvent.removeMonitor(globalClickMonitor)
            self.globalClickMonitor = nil
        }

        panel?.orderOut(nil)
    }

    @objc
    private func handleCopyButton() {
        copyToClipboard?()
        hide()
    }

    private func ensurePanel() {
        guard panel == nil else { return }

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 248, height: 52),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.ignoresMouseEvents = false

        let root = NSView(frame: panel.contentView?.bounds ?? .zero)
        root.wantsLayer = true
        root.layer?.cornerRadius = 16
        root.layer?.masksToBounds = true
        root.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.94).cgColor
        root.layer?.borderWidth = 1
        root.layer?.borderColor = NSColor.white.withAlphaComponent(0.8).cgColor
        root.layer?.shadowOpacity = 0.12
        root.layer?.shadowRadius = 18
        root.layer?.shadowOffset = .zero
        root.layer?.shadowColor = NSColor.black.cgColor

        let blur = NSVisualEffectView(frame: root.bounds)
        blur.autoresizingMask = [.width, .height]
        blur.material = .hudWindow
        blur.state = .active
        blur.blendingMode = .behindWindow
        root.addSubview(blur)

        let label = NSTextField(labelWithString: "Click the input again")
        label.font = NSFont(name: "Manrope SemiBold", size: 13) ?? .systemFont(ofSize: 13, weight: .semibold)
        label.textColor = NSColor(calibratedWhite: 0.16, alpha: 1)
        label.alignment = .left
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false

        let button = NSButton(title: "Copy", target: self, action: #selector(handleCopyButton))
        button.bezelStyle = .rounded
        button.font = NSFont(name: "Manrope SemiBold", size: 12) ?? .systemFont(ofSize: 12, weight: .semibold)
        button.contentTintColor = NSColor(calibratedWhite: 0.12, alpha: 1)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.setButtonType(.momentaryPushIn)

        root.addSubview(label)
        root.addSubview(button)

        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 14),
            label.centerYAnchor.constraint(equalTo: root.centerYAnchor),
            button.leadingAnchor.constraint(greaterThanOrEqualTo: label.trailingAnchor, constant: 12),
            button.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -10),
            button.centerYAnchor.constraint(equalTo: root.centerYAnchor),
            button.heightAnchor.constraint(equalToConstant: 28),
            button.widthAnchor.constraint(greaterThanOrEqualToConstant: 62)
        ])

        panel.contentView = root
        self.panel = panel
    }

    private func startMonitoring() {
        guard globalClickMonitor == nil else { return }

        globalClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleGlobalClick()
            }
        }
    }

    private func handleGlobalClick() {
        guard let panel, panel.isVisible else { return }
        guard !panel.frame.contains(NSEvent.mouseLocation) else { return }
        guard pendingPasteTask == nil else { return }
        guard let pasteAfterRefocus else { return }

        pendingPasteTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 180_000_000)
            guard !Task.isCancelled else { return }
            let didPaste = await pasteAfterRefocus()
            guard let self else { return }
            self.pendingPasteTask = nil
            if didPaste {
                self.hide()
            }
        }
    }

    private func positionPanel() {
        guard let panel else { return }
        let screen = NSApp.keyWindow?.screen ?? NSScreen.main ?? NSScreen.screens.first
        guard let screen else { return }

        let visibleFrame = screen.visibleFrame
        let origin = NSPoint(
            x: visibleFrame.midX - (panel.frame.width / 2),
            y: visibleFrame.maxY - panel.frame.height - 72
        )
        panel.setFrameOrigin(origin)
    }
}

@MainActor
final class DictationController: ObservableObject {
    private static let minimumVisibleEmptyTranscriptDurationMS = 3_000
    private static let logger = Logger(subsystem: "io.voceapp.voce", category: "DictationController")

    private enum RecordingStartError: LocalizedError {
        case microphonePermissionDenied

        var errorDescription: String? {
            switch self {
            case .microphonePermissionDenied:
                return "Microphone permission is required to start recording."
            }
        }
    }

    @Published var status: String = "Idle"
    @Published var lastTranscript: String = ""
    @Published var lastError: String = ""
    @Published var isRecording: Bool = false
    @Published var handsFreeOn: Bool = false
    @Published var recentEntries: [TranscriptEntry] = []
    @Published var hotkeyRegistrationMessage: String = ""
    @Published var launchAtLoginWarning: String = ""
    @Published var preferences: AppPreferences = .default
    @Published var microphonePermissionStatus: PermissionDiagnostics.AccessStatus = .unknown
    @Published var speechRecognitionPermissionStatus: PermissionDiagnostics.AccessStatus = .unknown
    @Published var accessibilityPermissionStatus: PermissionDiagnostics.AccessStatus = .unknown
    @Published var inputMonitoringPermissionStatus: PermissionDiagnostics.AccessStatus = .unknown
    @Published var recordingElapsed: TimeInterval = 0
    @Published var hasBootstrapped = false

    private let captureService = MacAudioCaptureService()
    private let clipboardService = MacClipboardService()
    private let historyStore: HistoryStore
    private let hotkey: MacHotkeyMonitor
    private let overlay: MacOverlayPresenter
    private let mediaInterruption: MediaInterruptionService
    private let preferencesStore: AppPreferencesStore
    private let launchAtLoginService: LaunchAtLoginService
    private let clipboardRecoveryPrompt = ClipboardRecoveryPromptPresenter()

    private var lexiconService: PersonalLexiconService
    private var styleProfileService: StyleProfileService
    private var snippetService: SnippetService
    private var voiceCommandService: VoiceCommandService
    private var insertionService: any InsertionServiceProtocol = InsertionService(transports: [])
    private var coordinator: SessionCoordinator?
    private var transcriptionEngine: AppleSpeechTranscriptionEngine?
    private let learningEngine = LearningEngine()
    private let completionRoutingService = CompletionRoutingService()
    private let aiGenerationService = AppleFoundationModelsService()

    private var recordingStateMachine = RecordingStateMachine()
    private var currentSessionID: SessionID?
    private var activeAppContext: AppContext?
    private var activeRecordingMode: RecordingMode?
    private var pendingCompletionActionOverride: CompletionAction?
    private var activeMediaToken: MediaInterruptionToken?
    private var activeStartTask: Task<Void, Never>?
    private var activePreviewSession: AppleSpeechPreviewSession?
    private var metricEntries: [TranscriptEntry] = []
    private var pendingRuntimeRebuild = false
    private let menuBar = MenuBarController()
    private var recordingTimer: Timer?
    private var overlayDismissTask: Task<Void, Never>?
    private var terminationObserver: Any?
    private var overlayPersistenceBundleIdentifier: String?
    private var suppressNextPressToTalkStop = false

    init(
        hotkey: MacHotkeyMonitor = MacHotkeyMonitor(),
        overlay: MacOverlayPresenter = MacOverlayPresenter(),
        mediaInterruption: MediaInterruptionService = MacMediaInterruptionService(),
        preferencesStore: AppPreferencesStore = AppPreferencesStore(),
        launchAtLoginService: LaunchAtLoginService = LaunchAtLoginService()
    ) {
        self.hotkey = hotkey
        self.overlay = overlay
        self.mediaInterruption = mediaInterruption
        self.preferencesStore = preferencesStore
        self.launchAtLoginService = launchAtLoginService
        self.historyStore = HistoryStore(clipboardService: clipboardService)
        self.lexiconService = PersonalLexiconService(entries: AppPreferences.default.lexiconEntries)
        self.styleProfileService = StyleProfileService(
            globalProfile: AppPreferences.default.globalStyleProfile,
            appProfiles: AppPreferences.default.appStyleProfiles
        )
        self.snippetService = SnippetService(snippets: AppPreferences.default.snippets)
        self.voiceCommandService = VoiceCommandService(commands: AppPreferences.default.voiceCommands)

        hotkey.onPressToTalkStart = { [weak self] in
            self?.pressToTalkStart()
        }
        hotkey.onPressToTalkStop = { [weak self] in
            self?.pressToTalkStop()
        }
        hotkey.onToggleHandsFree = { [weak self] in
            self?.toggleHandsFree()
        }
        hotkey.onSubmitActiveRecording = { [weak self] in
            self?.submitActiveRecording()
        }
        hotkey.onFinishActiveRecordingWithAI = { [weak self] hotkey in
            self?.finishActiveRecordingWithAI(triggeredBy: hotkey)
        }
        overlay.onUserDraggedToPosition = { [weak self] position in
            self?.saveOverlayDragPosition(position)
        }
        hotkey.onRegistrationStatusChanged = { [weak self] status in
            switch status {
            case .registered:
                self?.hotkeyRegistrationMessage = ""
            case .unavailable(let reason):
                self?.hotkeyRegistrationMessage = reason
            }
        }
        hotkey.start()
        menuBar.setup(controller: self)

        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.teardown()
            }
        }

        Task {
            await bootstrap()
        }
    }

    /// Idempotent shutdown: stops hotkeys, cancels in-flight work, releases media,
    /// hides the overlay, and invalidates timers. Triggered by willTerminateNotification.
    func teardown() {
        if let observer = terminationObserver {
            NotificationCenter.default.removeObserver(observer)
            terminationObserver = nil
        }
        hotkey.stop()
        overlayDismissTask?.cancel()
        overlayDismissTask = nil
        overlay.hide()
        clipboardRecoveryPrompt.hide()
        overlayPersistenceBundleIdentifier = nil
        activeStartTask?.cancel()
        activeStartTask = nil
        activePreviewSession?.cancel()
        activePreviewSession = nil
        if let token = activeMediaToken {
            mediaInterruption.endInterruption(token: token)
            activeMediaToken = nil
        }
        recordingTimer?.invalidate()
        recordingTimer = nil
        // Persist learning data before exit.
        Task { await learningEngine.save() }
    }

    var menuBarIconName: String {
        if isRecording { return "waveform.circle.fill" }
        return handsFreeOn ? "mic.circle.fill" : "mic.circle"
    }

    var recordingLifecycleState: RecordingLifecycleState {
        recordingStateMachine.state
    }

    func bootstrap() async {
        var loaded = await preferencesStore.load()
        loaded.normalize()

        applyPreferencesLocally(loaded)
        refreshPermissionStatuses()
        validateEngineConfiguration()
        await rebuildRuntime()
        await refreshHistory()
        await backfillLifetimeRecordingMetricsIfNeeded()
        await inferLifetimeTrackingStartIfNeeded()
        overlay.prepareWindow()
        hasBootstrapped = true
    }

    func savePreferences(announceImmediateSave: Bool = true) {
        var snapshot = preferences
        snapshot.normalize()
        preferences = snapshot

        Task {
            await preferencesStore.save(snapshot)
            await rebuildRuntimeOrDefer(announceImmediateSave: announceImmediateSave)
        }
    }

    func applySettingsDraft(preferences draft: AppPreferences, announceImmediateSave: Bool = true) {
        var snapshot = draft
        snapshot.normalize()
        preferences = snapshot

        Task {
            await preferencesStore.save(snapshot)
            await rebuildRuntimeOrDefer(announceImmediateSave: announceImmediateSave)
        }
    }

    /// Persist preferences to disk without rebuilding the dictation runtime.
    /// Use this for non-runtime fields like scratchPadContent, userName, and metrics.
    func savePreferencesQuietly(preferences draft: AppPreferences) {
        var snapshot = draft
        snapshot.normalize()
        preferences = snapshot

        Task {
            await preferencesStore.save(snapshot)
        }
    }

    func resetOnboarding() {
        preferences.general.showOnboarding = true
        savePreferences()
    }

    func completeOnboarding() {
        preferences.general.showOnboarding = false
        savePreferences()
    }

    func requestMicrophonePermission() {
        Task {
            _ = await PermissionDiagnostics.requestMicrophonePermission()
            await MainActor.run {
                refreshPermissionStatuses()
            }
        }
    }

    func openMicrophoneSettings() {
        PermissionDiagnostics.openMicrophoneSettings()
    }

    func requestSpeechRecognitionPermission() {
        Task {
            _ = await PermissionDiagnostics.requestSpeechRecognitionPermission()
            await MainActor.run {
                refreshPermissionStatuses()
            }
        }
    }

    func openSpeechRecognitionSettings() {
        PermissionDiagnostics.openSpeechRecognitionSettings()
    }

    func openAccessibilitySettings() {
        PermissionDiagnostics.openAccessibilitySettings()
    }

    func openInputMonitoringSettings() {
        PermissionDiagnostics.openInputMonitoringSettings()
    }

    func beginOverlayRepositionMode() {
        guard isRecording else {
            status = "Start dictation to reposition the overlay."
            return
        }

        if activeAppContext == nil {
            let capturedContext = AppContextProvider.current()
            activeAppContext = capturedContext
            overlayPersistenceBundleIdentifier = capturedContext.bundleIdentifier
        }

        status = "Drag the overlay to reposition it. Reposition mode ends automatically."
        overlay.beginInteractiveRepositionMode()
    }

    func requestAccessibilityPermission() {
        _ = PermissionDiagnostics.requestAccessibilityPermission()
        refreshPermissionStatuses()
    }

    func requestInputMonitoringPermission() {
        _ = PermissionDiagnostics.requestInputMonitoringPermission()
        refreshPermissionStatuses()
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 600_000_000)
            refreshPermissionStatuses()
        }
    }

    func revealCurrentAppInFinder() {
        PermissionDiagnostics.revealCurrentAppInFinder()
    }

    func refreshPermissionStatuses() {
        microphonePermissionStatus = PermissionDiagnostics.microphoneStatus()
        speechRecognitionPermissionStatus = PermissionDiagnostics.speechRecognitionStatus()
        accessibilityPermissionStatus = PermissionDiagnostics.accessibilityStatus()
        inputMonitoringPermissionStatus = PermissionDiagnostics.inputMonitoringStatus()

        // If permissions changed while app was running, reinstall monitors/hotkeys.
        if recordingStateMachine.state == .idle {
            hotkey.stop()
            hotkey.isOptionPressToTalkEnabled = preferences.hotkeys.optionPressToTalkEnabled
            hotkey.pressToTalkHotkey = preferences.hotkeys.pressToTalkHotkey
            hotkey.globalToggleHotkey = preferences.hotkeys.handsFreeGlobalHotkey
            hotkey.isSubmitActiveRecordingEnabled = false
            hotkey.aiFinishHotkey = preferences.ai.handsFreeFinishHotkey
            hotkey.aiWorkflowFinishHotkeys = preferences.ai.workflows.compactMap(\.handsFreeFinishHotkey)
            hotkey.isAIFinishEnabled = false
            hotkey.start()
        }
    }

    func pressToTalkStart() {
        guard preferences.hotkeys.optionPressToTalkEnabled else { return }
        suppressNextPressToTalkStop = false
        apply(transition: recordingStateMachine.handlePressToTalkKeyDown())
    }

    func pressToTalkStop() {
        guard preferences.hotkeys.optionPressToTalkEnabled else { return }
        if suppressNextPressToTalkStop {
            suppressNextPressToTalkStop = false
            return
        }
        apply(transition: recordingStateMachine.handlePressToTalkKeyUp())
    }

    func toggleHandsFree() {
        apply(transition: recordingStateMachine.handleHandsFreeToggle())
    }

    func toggleMenuBarTranscription() {
        pendingCompletionActionOverride = .copyToClipboard
        toggleHandsFree()
    }

    func stopActiveRecording() {
        switch recordingLifecycleState {
        case .recordingHandsFree:
            toggleHandsFree()
        case .recordingPressToTalk:
            pressToTalkStop()
        case .idle, .transcribing:
            break
        }
    }

    func submitActiveRecording() {
        guard activeRecordingMode == .handsFree, isRecording else { return }
        guard preferences.hotkeys.enterFinishesHandsFreeAndSubmits else { return }
        pendingCompletionActionOverride = .insertAndSubmit
        toggleHandsFree()
    }

    func finishActiveRecordingWithAI(triggeredBy hotkey: HandsFreeHotkey? = nil) {
        guard let activeRecordingMode, isRecording else { return }
        guard aiRuntimeEnabled else { return }
        let workflowID: UUID?
        if let hotkey {
            workflowID = preferences.ai.workflows.first(where: { $0.handsFreeFinishHotkey == hotkey })?.id
        } else {
            workflowID = preferences.ai.defaultHandsFreeWorkflowID
        }
        guard let workflowID else { return }
        if let workflowName = preferences.ai.workflows.first(where: { $0.id == workflowID })?.name {
            status = "Finishing with \(workflowName.lowercased())…"
        } else {
            status = "Finishing with AI…"
        }
        pendingCompletionActionOverride = .aiWorkflow(id: workflowID)
        switch activeRecordingMode {
        case .handsFree:
            toggleHandsFree()
        case .pressToTalk:
            suppressNextPressToTalkStop = true
            apply(transition: recordingStateMachine.handlePressToTalkKeyUp())
        }
    }

    func pasteLastTranscript() {
        Task {
            do {
                if let entry = try await historyStore.pasteLast() {
                    lastTranscript = entry.cleanText
                    status = "Last transcript copied to clipboard. Paste with Cmd+V."
                } else {
                    status = "No transcript history yet."
                }
            } catch {
                status = "Paste last failed"
                lastError = error.localizedDescription
            }
        }
    }

    func copyCurrentTranscript() {
        let transcript = currentTranscriptText
        guard !transcript.isEmpty else {
            status = "No transcript available yet."
            return
        }

        Task {
            do {
                try await clipboardService.setString(transcript)
                status = "Selected transcript copied."
            } catch {
                status = "Copy failed"
                lastError = error.localizedDescription
            }
        }
    }

    func pasteCurrentTranscript() {
        let transcript = currentTranscriptText
        guard !transcript.isEmpty else {
            status = "No transcript available yet."
            return
        }

        Task {
            do {
                try await clipboardService.setString(transcript)
                status = "Transcript copied to clipboard. Paste with Cmd+V."
            } catch {
                status = "Paste failed"
                lastError = error.localizedDescription
            }
        }
    }

    func deleteEntry(_ entry: TranscriptEntry) {
        Task {
            do {
                try await historyStore.delete(entryID: entry.id)
                await refreshHistory()
                status = "Transcript deleted."
            } catch {
                status = "Delete failed"
                lastError = error.localizedDescription
            }
        }
    }

    func clearErrors() {
        lastError = ""
        hotkeyRegistrationMessage = ""
    }

    // MARK: - Learning Engine Actions

    func submitCorrection(rawWord: String, correctedWord: String) async {
        let promoted = await learningEngine.recordCorrection(
            rawWord: rawWord,
            correctedWord: correctedWord
        )
        if let entry = promoted {
            // Auto-add to lexicon when correction threshold is reached.
            if !preferences.lexiconEntries.contains(where: {
                $0.term.lowercased() == entry.term.lowercased()
            }) {
                preferences.lexiconEntries.append(entry)
                savePreferences()
                status = "Learned: \"\(entry.term)\" \u{2192} \"\(entry.preferred)\" added to lexicon."
            }
        } else {
            status = "Correction recorded."
        }
        await learningEngine.save()
    }

    func fetchSnippetSuggestions(excluding triggers: Set<String>) async -> [SnippetSuggestion] {
        await learningEngine.snippetSuggestions(excluding: triggers)
    }

    func acceptSnippetSuggestion(_ suggestion: SnippetSuggestion) async {
        let snippet = Snippet(
            trigger: suggestion.suggestedTrigger,
            expansion: suggestion.phrase,
            scope: .global
        )
        if let existingIndex = preferences.snippets.firstIndex(where: {
            $0.trigger.caseInsensitiveCompare(snippet.trigger) == .orderedSame && $0.scope == snippet.scope
        }) {
            preferences.snippets[existingIndex] = snippet
        } else {
            preferences.snippets.append(snippet)
        }
        savePreferences()
        status = "Shortcut added for \"\(suggestion.phrase)\"."
    }

    func dismissSnippetSuggestion(_ suggestion: SnippetSuggestion) async {
        await learningEngine.dismissSnippetSuggestion(phrase: suggestion.phrase)
        await learningEngine.save()
    }

    func fetchStyleSuggestions() async -> [StyleSuggestion] {
        await learningEngine.styleSuggestions(currentProfiles: preferences.appStyleProfiles)
    }

    func acceptStyleSuggestion(_ suggestion: StyleSuggestion) async {
        preferences.appStyleProfiles[suggestion.bundleID] = suggestion.suggestedProfile
        savePreferences()
        status = "Style profile applied for \(suggestion.bundleID)."
    }

    func fetchCorrections() async -> [Correction] {
        await learningEngine.corrections()
    }

    func copyEntry(_ entry: TranscriptEntry) {
        Task {
            do {
                let text = entry.cleanText.isEmpty ? entry.rawText : entry.cleanText
                try await clipboardService.setString(text)
                status = "Selected transcript copied."
            } catch {
                status = "Copy failed"
                lastError = error.localizedDescription
            }
        }
    }

    func copyEntryTranscript(_ entry: TranscriptEntry) {
        Task {
            do {
                let text = (entry.sourceText?.isEmpty == false ? entry.sourceText : entry.rawText) ?? entry.rawText
                try await clipboardService.setString(text)
                status = "Transcribed text copied."
            } catch {
                status = "Copy failed"
                lastError = error.localizedDescription
            }
        }
    }

    func copyEntryAIOutput(_ entry: TranscriptEntry) {
        Task {
            do {
                let text = entry.cleanText.isEmpty ? entry.rawText : entry.cleanText
                try await clipboardService.setString(text)
                status = "AI output copied."
            } catch {
                status = "Copy failed"
                lastError = error.localizedDescription
            }
        }
    }

    func refreshHistory() async {
        let all = await historyStore.recent(limit: 500)
        metricEntries = all
        let thirtyDaysAgo = Date().addingTimeInterval(-30 * 24 * 60 * 60)
        recentEntries = all.filter { $0.createdAt >= thirtyDaysAgo }
    }

    private var currentTranscriptText: String {
        if !lastTranscript.isEmpty {
            return lastTranscript
        }

        if let entry = recentEntries.first {
            return entry.cleanText.isEmpty ? entry.rawText : entry.cleanText
        }

        return ""
    }

    private func apply(transition: RecordingTransition) {
        switch transition {
        case .start(let mode):
            startSession(mode: mode)
        case .stop(let mode):
            stopSession(mode: mode)
        case .ignore(let reason):
            status = reason
        }
    }

    private func startSession(mode: RecordingMode) {
        guard let coordinator else {
            status = "Runtime not ready yet."
            recordingStateMachine.markTranscriptionFailed()
            return
        }

        cancelPendingOverlayDismissal()
        clipboardRecoveryPrompt.hide()
        status = "Checking microphone..."
        lastError = ""
        let capturedContext = AppContextProvider.current()
        activeAppContext = capturedContext
        overlayPersistenceBundleIdentifier = capturedContext.bundleIdentifier
        pendingCompletionActionOverride = nil

        // Restore per-app overlay position if the user previously dragged it,
        // otherwise fall back to accessibility-based anchoring.
        let overlayAnchorSnapshot: MacOverlayPresenter.AnchorSnapshot?
        if let saved = preferences.appAnchorOverrides[capturedContext.bundleIdentifier] {
            if saved.width == 0 && saved.height == 0 {
                // Drag-saved window origin — restore directly.
                overlay.restoreDraggedPosition(NSPoint(x: saved.x, y: saved.y))
                overlayAnchorSnapshot = nil
            } else {
                // Manual anchor rect — position above it.
                overlayAnchorSnapshot = MacOverlayPresenter.AnchorSnapshot(frame: saved.cgRect)
            }
        } else {
            overlayAnchorSnapshot = overlay.captureAnchorSnapshot()
        }

        let shouldPauseMedia = (mode == .handsFree && preferences.media.pauseDuringHandsFree)
                            || (mode == .pressToTalk && preferences.media.pauseDuringPressToTalk)

        activeStartTask = Task { @MainActor in
            do {
                try await ensureMicrophonePermission()

                status = "Arming microphone..."
                let session = AppleSpeechPreviewSession(
                    localeIdentifier: preferences.dictation.localeIdentifier,
                    previewTranscriptionEnabled: false,
                    onPartialText: { _ in },
                    onTerminalError: { [weak self] error in
                        Task { @MainActor [weak self] in
                            self?.handleStreamingFailure(error)
                        }
                    }
                )
                activePreviewSession = session
                try await session.start()

                status = mode == .handsFree ? "Hands-free listening..." : "Recording..."
                isRecording = true
                handsFreeOn = mode == .handsFree
                menuBar.updateIcon(isRecording: true, handsFreeOn: mode == .handsFree)
                activeRecordingMode = mode
                updateActiveRecordingHotkeys()
                recordingElapsed = 0
                recordingTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                    Task { @MainActor [weak self] in
                        self?.recordingElapsed += 1
                    }
                }
                overlay.setAnchorSnapshot(overlayAnchorSnapshot)
                overlay.show(state: .listening(handsFree: mode == .handsFree, elapsedSeconds: 0))

                if shouldPauseMedia {
                    activeMediaToken = await mediaInterruption.beginInterruption()
                }

                let sessionID = await coordinator.registerStreamingSession(appContext: capturedContext)
                await coordinator.setHandsFreeEnabled(mode == .handsFree)
                currentSessionID = sessionID
            } catch {
                if let token = activeMediaToken {
                    mediaInterruption.endInterruption(token: token)
                    activeMediaToken = nil
                }
                self.recordingTimer?.invalidate()
                self.recordingTimer = nil
                self.recordingElapsed = 0
                isRecording = false
                handsFreeOn = false
                menuBar.updateIcon(isRecording: false, handsFreeOn: false)
                activeRecordingMode = nil
                activeAppContext = nil
                overlayPersistenceBundleIdentifier = nil
                pendingCompletionActionOverride = nil
                updateActiveRecordingHotkeys()
                activePreviewSession = nil
                recordingStateMachine.markTranscriptionFailed()
                status = "Failed to start"
                lastError = error.localizedDescription
                overlay.hide()
                clipboardRecoveryPrompt.hide()
            }
            activeStartTask = nil
        }
    }

    private func handleStreamingFailure(_ error: Error) {
        guard let session = activePreviewSession else { return }

        let pendingStart = activeStartTask
        activeStartTask = nil
        activePreviewSession = nil

        recordingTimer?.invalidate()
        recordingTimer = nil
        recordingElapsed = 0
        isRecording = false
        handsFreeOn = false
        menuBar.updateIcon(isRecording: false, handsFreeOn: false)
        activeRecordingMode = nil
        updateActiveRecordingHotkeys()

        Task {
            await pendingStart?.value

            session.cancel()

            if let sessionID = currentSessionID, let coordinator {
                await coordinator.cancel(sessionID: sessionID)
            }
            currentSessionID = nil

            if let token = activeMediaToken {
                mediaInterruption.endInterruption(token: token)
                activeMediaToken = nil
            }

            activeAppContext = nil
            overlayPersistenceBundleIdentifier = nil
            pendingCompletionActionOverride = nil

            recordingStateMachine.markTranscriptionFailed()
            status = streamingFailureStatusMessage(for: error)
            lastError = error.localizedDescription
            overlay.hide()
            clipboardRecoveryPrompt.hide()
            await applyDeferredRebuildIfNeeded()
        }
    }

    private func stopSession(mode: RecordingMode) {
        let pendingStart = activeStartTask
        activeStartTask = nil

        // Capture streaming session before clearing state.
        let previewSession = activePreviewSession
        activePreviewSession = nil
        // Shared cleanup — runs on every path including the guard-return.
        recordingTimer?.invalidate()
        recordingTimer = nil
        accumulateRecordingSeconds(recordingElapsed)
        recordingElapsed = 0
        isRecording = false
        handsFreeOn = false
        menuBar.updateIcon(isRecording: false, handsFreeOn: false)
        activeRecordingMode = nil
        updateActiveRecordingHotkeys()

        Task {
            // Wait for startSession's Task to finish so currentSessionID
            // and activeMediaToken are guaranteed to be set (or errored out).
            await pendingStart?.value

            guard let coordinator, let sessionID = currentSessionID else {
                previewSession?.cancel()
                recordingStateMachine.markTranscriptionFailed()
                status = "No active recording session."
                return
            }
            currentSessionID = nil
            let preferredCompletionAction = pendingCompletionActionOverride
            activeAppContext = nil
            pendingCompletionActionOverride = nil

            if let token = activeMediaToken {
                mediaInterruption.endInterruption(token: token)
                activeMediaToken = nil
            }

            status = "Finalising..."
            lastError = ""
            overlay.show(state: .transcribing)

            var captureDurationMS = 0
            do {
                let clock = ContinuousClock()
                let stopBeganAt = clock.now
                guard let stopResult = try previewSession?.stop() else {
                    throw AppleSpeechPreviewError.missingOutputFile
                }
                captureDurationMS = stopResult.captureDurationMS
                let stopElapsed = stopBeganAt.duration(to: clock.now)
                let stopElapsedSeconds = Double(stopElapsed.components.seconds)
                    + Double(stopElapsed.components.attoseconds) / 1_000_000_000_000_000_000
                Self.logger.notice(
                    "Preview stop completed in \(stopElapsedSeconds, format: .fixed(precision: 2))s; captured \(captureDurationMS)ms"
                )

                let transcriptionBeganAt = clock.now
                let finalizedTranscript = try await coordinator.processStreamingAudio(
                    audioURL: stopResult.captureURL,
                    sessionID: sessionID,
                    languageHints: [preferences.dictation.localeIdentifier]
                )
                let transcriptionElapsed = transcriptionBeganAt.duration(to: clock.now)
                let transcriptionElapsedSeconds = Double(transcriptionElapsed.components.seconds)
                    + Double(transcriptionElapsed.components.attoseconds) / 1_000_000_000_000_000_000
                Self.logger.notice(
                    "Coordinator finalized transcript in \(transcriptionElapsedSeconds, format: .fixed(precision: 2))s"
                )

                let routingBeganAt = clock.now
                let routedCompletion = try completionRoutingService.route(
                    finalizedTranscript: finalizedTranscript,
                    preferredAction: preferredCompletionAction,
                    leadingPhraseSelectionEnabled: aiRuntimeEnabled && preferences.ai.leadingPhraseSelectionEnabled,
                    workflows: preferences.ai.workflows
                )
                let routingElapsed = routingBeganAt.duration(to: clock.now)
                let routingElapsedSeconds = Double(routingElapsed.components.seconds)
                    + Double(routingElapsed.components.attoseconds) / 1_000_000_000_000_000_000
                Self.logger.notice(
                    "Completion routing finished in \(routingElapsedSeconds, format: .fixed(precision: 2))s"
                )

                if case .aiWorkflow(let workflowID) = routedCompletion.action {
                    let workflowName = preferences.ai.workflows.first(where: { $0.id == workflowID })?.name ?? "AI"
                    status = aiGenerationStatusMessage(for: workflowName)
                }

                do {
                    let executionBeganAt = clock.now
                    let executor = CompletionExecutionService(
                        insertionService: insertionService,
                        clipboardService: clipboardService,
                        aiGenerationService: aiGenerationService
                    )
                    let execution = try await executor.execute(
                        routedCompletion: routedCompletion,
                        finalizedTranscript: finalizedTranscript,
                        workflows: preferences.ai.workflows
                    )
                    let executionElapsed = executionBeganAt.duration(to: clock.now)
                    let executionElapsedSeconds = Double(executionElapsed.components.seconds)
                        + Double(executionElapsed.components.attoseconds) / 1_000_000_000_000_000_000
                    Self.logger.notice(
                        "Completion execution finished in \(executionElapsedSeconds, format: .fixed(precision: 2))s"
                    )

                    lastTranscript = execution.finalText
                    applyExecutionOutcomeStatus(
                        execution,
                        targetAppContext: finalizedTranscript.appContext
                    )
                    do {
                        try await appendHistoryEntry(
                            finalizedTranscript: finalizedTranscript,
                            execution: execution
                        )
                    } catch {
                        lastError = error.localizedDescription
                    }
                    scheduleLearningUpdate(for: finalizedTranscript)
                    dismissOverlaySoon(pop: execution.insertResult.status == .inserted)
                } catch let aiError as AIWorkflowError {
                    lastTranscript = finalizedTranscript.cleanText
                    status = aiError.errorDescription ?? "AI request failed."
                    lastError = aiError.errorDescription ?? ""
                    overlay.hide()
                    clipboardRecoveryPrompt.hide()
                    do {
                        try await appendFailedAIHistoryEntry(
                            finalizedTranscript: finalizedTranscript,
                            routedCompletion: routedCompletion,
                            errorMessage: lastError
                        )
                    } catch {
                        lastError = aiError.errorDescription ?? ""
                    }
                    scheduleLearningUpdate(for: finalizedTranscript)
                    dismissOverlaySoon()
                } catch let routingError as CompletionRoutingError {
                    lastTranscript = finalizedTranscript.cleanText
                    status = routingErrorStatusMessage(for: routingError)
                    lastError = ""
                    overlay.hide()
                    clipboardRecoveryPrompt.hide()
                    scheduleLearningUpdate(for: finalizedTranscript)
                    dismissOverlaySoon()
                }
                await refreshHistory()
                recordingStateMachine.markTranscriptionCompleted()
                await applyDeferredRebuildIfNeeded()
            } catch {
                if shouldSuppressEmptyTranscriptError(error, captureDurationMS: captureDurationMS) {
                    handleShortSilentCapture()
                    await applyDeferredRebuildIfNeeded()
                    return
                }
                status = "Transcription failed"
                lastError = error.localizedDescription
                overlay.hide()
                clipboardRecoveryPrompt.hide()
                recordingStateMachine.markTranscriptionFailed()
                await applyDeferredRebuildIfNeeded()
            }
        }
    }

    private func dismissOverlaySoon(pop: Bool = false) {
        overlayDismissTask?.cancel()
        overlayDismissTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard !Task.isCancelled else { return }
            if pop {
                overlay.popAndHide()
            } else {
                overlay.hide()
            }
            overlayPersistenceBundleIdentifier = nil
            overlayDismissTask = nil
        }
    }

    private func routingErrorStatusMessage(for error: CompletionRoutingError) -> String {
        switch error {
        case .workflowNotFound:
            return error.errorDescription ?? "Selected AI workflow was not found."
        case .noContentAfterTrigger(let phrase):
            return "Say something after \"\(phrase)\"."
        }
    }

    private func cancelPendingOverlayDismissal() {
        overlayDismissTask?.cancel()
        overlayDismissTask = nil
    }

    private var isOverlayReservedForDictationSession: Bool {
        activeStartTask != nil
            || isRecording
            || recordingLifecycleState != .idle
            || overlayDismissTask != nil
            || overlayPersistenceBundleIdentifier != nil
    }

    /// Bundle IDs for browsers — these work well with accessibility APIs
    /// so we don't save per-app drag overrides for them.
    private func saveOverlayDragPosition(_ position: NSPoint) {
        guard let bundleID = activeAppContext?.bundleIdentifier ?? overlayPersistenceBundleIdentifier,
              bundleID != "unknown" else { return }

        // Save the exact window origin so we can restore it next time.
        // width/height = 0 signals a drag-saved position (vs manual anchor).
        preferences.appAnchorOverrides[bundleID] = AppAnchorOverride(
            x: position.x, y: position.y, width: 0, height: 0
        )
        Task { await preferencesStore.save(preferences) }
    }

    private func applyPreferencesLocally(_ newValue: AppPreferences) {
        preferences = newValue
        hotkey.isOptionPressToTalkEnabled = newValue.hotkeys.optionPressToTalkEnabled
        hotkey.pressToTalkHotkey = newValue.hotkeys.pressToTalkHotkey
        hotkey.globalToggleHotkey = newValue.hotkeys.handsFreeGlobalHotkey
        hotkey.aiFinishHotkey = newValue.ai.handsFreeFinishHotkey
        hotkey.aiWorkflowFinishHotkeys = newValue.ai.workflows.compactMap(\.handsFreeFinishHotkey)
        updateActiveRecordingHotkeys()
        applyDockVisibility(showDockIcon: newValue.general.showDockIcon)
    }

    private func rebuildRuntimeOrDefer(announceImmediateSave: Bool) async {
        if recordingStateMachine.state == .idle {
            if announceImmediateSave {
                status = "Settings saved."
            }
            await rebuildRuntime()
        } else {
            pendingRuntimeRebuild = true
            status = "Settings saved. Changes will apply after current transcription."
        }
    }

    private func applyDeferredRebuildIfNeeded() async {
        guard pendingRuntimeRebuild, recordingStateMachine.state == .idle else { return }
        pendingRuntimeRebuild = false
        await rebuildRuntime()
    }

    private func rebuildRuntime() async {
        var snapshot = preferences
        snapshot.normalize()
        applyPreferencesLocally(snapshot)

        // Get learned word frequencies for vocabulary-biased candidate ranking.
        let wordFreqs = await learningEngine.wordFrequencySnapshot()

        let runtimeFactory = DictationRuntimeFactory(
            snapshot: snapshot,
            clipboardService: clipboardService,
            wordFrequencies: wordFreqs
        )
        lexiconService = runtimeFactory.makeLexiconService()
        styleProfileService = runtimeFactory.makeStyleProfileService()
        snippetService = runtimeFactory.makeSnippetService()
        voiceCommandService = runtimeFactory.makeVoiceCommandService()

        let transcription = runtimeFactory.makeTranscriptionEngine()
        transcriptionEngine = transcription
        let cleanupEngine: any CleanupEngine = runtimeFactory.makeCleanupEngine()
        let insertion = InsertionService(transports: runtimeFactory.makeInsertionTransports())
        insertionService = insertion

        coordinator = SessionCoordinator(
            captureService: captureService,
            transcriptionEngine: transcription,
            cleanupEngine: cleanupEngine,
            lexiconService: lexiconService,
            styleProfileService: styleProfileService,
            snippetService: snippetService,
            voiceCommandService: voiceCommandService,
            fallbackCleanupEngine: RuleBasedCleanupEngine(),
            learningEngine: learningEngine
        )

        do {
            try launchAtLoginService.setEnabled(snapshot.general.launchAtLoginEnabled)
            launchAtLoginWarning = ""
        } catch {
            launchAtLoginWarning = error.localizedDescription
        }

        status = "Running Apple preview + Apple Speech final transcription + local cleanup."
    }

    private func fallbackWarningText(from outcome: CleanupOutcome?) -> String? {
        guard let outcome, outcome.source == .localFallback else {
            return nil
        }
        return outcome.warning ?? "Primary cleanup unavailable, used local fallback."
    }

    var appleIntelligenceAvailabilityText: String {
        aiGenerationService.availabilityStatus().displayText
    }

    var aiAvailabilityIsAvailable: Bool {
        aiGenerationService.availabilityStatus().isAvailable
    }

    private var aiRuntimeEnabled: Bool {
        preferences.ai.isEnabled && aiAvailabilityIsAvailable
    }

    var availableAIWorkflows: [AIWorkflow] {
        preferences.ai.workflows
    }

    private func validateEngineConfiguration() {
        let localeIdentifier = preferences.dictation.localeIdentifier
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !localeIdentifier.isEmpty else {
            status = "Apple Speech locale is missing. Check Settings \u{2192} Engine."
            return
        }
    }

    private func ensureMicrophonePermission() async throws {
        let currentStatus = PermissionDiagnostics.microphoneStatus()
        switch currentStatus {
        case .granted:
            microphonePermissionStatus = .granted
        case .denied:
            microphonePermissionStatus = .denied
            throw RecordingStartError.microphonePermissionDenied
        case .unknown:
            let granted = await PermissionDiagnostics.requestMicrophonePermission()
            refreshPermissionStatuses()
            guard granted else {
                throw RecordingStartError.microphonePermissionDenied
            }
        }
    }

    private func applyDockVisibility(showDockIcon: Bool) {
        let policy: NSApplication.ActivationPolicy = showDockIcon ? .regular : .accessory
        NSApp.setActivationPolicy(policy)
    }

    private func copiedOnlyStatusMessage(for result: InsertResult) -> String {
        if result.recoveryAction == .refocusToPaste {
            return "Click the input again."
        }

        guard let reason = result.errorMessage?.lowercased() else {
            return "Transcript copied to clipboard. Paste with Cmd+V."
        }

        if reason.contains("accessibility permission") {
            return "Transcript copied. Auto-paste unavailable until Accessibility is re-granted for this Voce build."
        }

        return "Transcript copied to clipboard. Paste with Cmd+V."
    }

    private func streamingFailureStatusMessage(for error: Error) -> String {
        _ = error
        return "Recording stopped"
    }

    private func shouldSuppressEmptyTranscriptError(_ error: Error? = nil, captureDurationMS: Int) -> Bool {
        guard captureDurationMS > 0, captureDurationMS < Self.minimumVisibleEmptyTranscriptDurationMS else {
            return false
        }

        guard let error else {
            return true
        }

        if case AppleSpeechTranscriptionError.emptyTranscript = error {
            return true
        }

        return false
    }

    private func handleShortSilentCapture() {
        status = "Recording stopped"
        lastError = ""
        overlay.hide()
        clipboardRecoveryPrompt.hide()
        overlayPersistenceBundleIdentifier = nil
        recordingStateMachine.markTranscriptionCompleted()
    }

    private func scheduleLearningUpdate(for finalizedTranscript: FinalizedTranscript) {
        let transcript = finalizedTranscript
        Task(priority: .utility) {
            let clock = ContinuousClock()
            let startedAt = clock.now
            await self.learningEngine.observeSession(
                rawText: transcript.rawText,
                cleanText: transcript.cleanText,
                removedFillers: transcript.removedFillers,
                appBundleID: transcript.appContext.bundleIdentifier
            )
            await self.learningEngine.save()

            let elapsed = startedAt.duration(to: clock.now)
            let elapsedSeconds = Double(elapsed.components.seconds)
                + Double(elapsed.components.attoseconds) / 1_000_000_000_000_000_000
            Self.logger.notice(
                "Deferred learning update + save finished in \(elapsedSeconds, format: .fixed(precision: 2))s"
            )
        }
    }

    private func applyExecutionOutcomeStatus(
        _ execution: CompletionExecutionOutcome,
        targetAppContext: AppContext
    ) {
        let result = execution.insertResult
        let baseStatus: String
        clipboardRecoveryPrompt.hide()
        switch execution.action {
        case .insert, .insertAndSubmit:
            switch result.status {
            case .inserted:
                baseStatus = "Transcript inserted."
                lastError = ""
            case .copiedOnly:
                baseStatus = copiedOnlyStatusMessage(for: result)
                lastError = result.errorMessage ?? ""
                presentClipboardRecoveryPromptIfNeeded(for: result, targetAppContext: targetAppContext)
            case .failed:
                let reason = result.errorMessage ?? "Insertion chain exhausted."
                baseStatus = "Transcript ready but insertion failed."
                lastError = reason
            }
        case .copyToClipboard:
            switch result.status {
            case .inserted:
                baseStatus = "Transcript inserted."
                lastError = ""
            case .copiedOnly:
                baseStatus = "Transcript copied to clipboard."
                lastError = ""
            case .failed:
                let reason = result.errorMessage ?? "Clipboard copy failed."
                baseStatus = "Transcript ready but copy failed."
                lastError = reason
            }
        case .aiWorkflow:
            switch result.status {
            case .inserted:
                baseStatus = "AI result inserted."
                lastError = ""
            case .copiedOnly:
                baseStatus = result.recoveryAction == .refocusToPaste
                    ? "Click the input again."
                    : "AI result copied to clipboard. Paste with Cmd+V."
                lastError = result.errorMessage ?? ""
                presentClipboardRecoveryPromptIfNeeded(for: result, targetAppContext: targetAppContext)
            case .failed:
                let reason = result.errorMessage ?? "Insertion chain exhausted."
                baseStatus = "AI result ready but insertion failed."
                lastError = reason
            }
        }

        var messages = [baseStatus]
        if let cleanupWarning = fallbackWarningText(from: result.cleanupOutcome) {
            messages.append(cleanupWarning)
        }
        if let submitWarning = execution.submitWarning, !submitWarning.isEmpty {
            messages.append(submitWarning)
        }
        status = messages.joined(separator: " ")
    }

    private func presentClipboardRecoveryPromptIfNeeded(
        for result: InsertResult,
        targetAppContext: AppContext
    ) {
        guard result.recoveryAction == .refocusToPaste else { return }

        clipboardRecoveryPrompt.show(
            onCopy: { [weak self] in
                self?.copyCurrentTranscriptToClipboardForRecovery()
            },
            onPasteAfterRefocus: { [weak self] in
                guard let self else { return false }
                return await self.completeClipboardRecoveryPaste(into: targetAppContext)
            }
        )
    }

    private func copyCurrentTranscriptToClipboardForRecovery() {
        let transcript = currentTranscriptText
        guard !transcript.isEmpty else { return }

        Task {
            do {
                try await clipboardService.setString(transcript)
                status = "Copied to clipboard."
                lastError = ""
            } catch {
                status = "Copy failed"
                lastError = error.localizedDescription
            }
        }
    }

    private func completeClipboardRecoveryPaste(into targetAppContext: AppContext) async -> Bool {
        let outcome = await MacPasteHelper.activateAndPaste(target: targetAppContext)
        switch outcome {
        case .attempted:
            status = "Transcript inserted."
            lastError = ""
            return true
        case .skipped:
            return false
        }
    }

    private func aiGenerationStatusMessage(for workflowName: String) -> String {
        "Generating \(workflowName.lowercased())…"
    }

    private func appendHistoryEntry(
        finalizedTranscript: FinalizedTranscript,
        execution: CompletionExecutionOutcome
    ) async throws {
        let entry = TranscriptEntry(
            appBundleID: finalizedTranscript.appContext.bundleIdentifier,
            rawText: finalizedTranscript.rawText,
            sourceText: execution.sourceText,
            cleanText: execution.finalText,
            audioURL: finalizedTranscript.audioURL,
            insertionStatus: execution.insertResult.status,
            processingNote: finalizedTranscript.processingNote,
            completionAction: completionActionDescription(execution.action),
            aiWorkflowName: execution.aiWorkflowName,
            aiProvider: execution.aiProvider
        )
        try await historyStore.append(entry: entry)
    }

    private func appendFailedAIHistoryEntry(
        finalizedTranscript: FinalizedTranscript,
        routedCompletion: RoutedCompletion,
        errorMessage: String
    ) async throws {
        guard case .aiWorkflow(let workflowID) = routedCompletion.action else {
            return
        }
        let workflowName = preferences.ai.workflows.first(where: { $0.id == workflowID })?.name
        let entry = TranscriptEntry(
            appBundleID: finalizedTranscript.appContext.bundleIdentifier,
            rawText: finalizedTranscript.rawText,
            sourceText: routedCompletion.inputText,
            cleanText: finalizedTranscript.cleanText,
            audioURL: finalizedTranscript.audioURL,
            insertionStatus: .failed,
            processingNote: finalizedTranscript.processingNote ?? errorMessage,
            completionAction: completionActionDescription(routedCompletion.action),
            aiWorkflowName: workflowName,
            aiProvider: nil
        )
        try await historyStore.append(entry: entry)
    }

    private func completionActionDescription(_ action: CompletionAction) -> String {
        switch action {
        case .insert:
            return "insert"
        case .copyToClipboard:
            return "copyToClipboard"
        case .insertAndSubmit:
            return "insertAndSubmit"
        case .aiWorkflow:
            return "aiWorkflow"
        }
    }

    private func updateActiveRecordingHotkeys() {
        hotkey.isSubmitActiveRecordingEnabled =
            preferences.hotkeys.enterFinishesHandsFreeAndSubmits
            && activeRecordingMode == .handsFree
            && isRecording
        hotkey.aiFinishHotkey = preferences.ai.handsFreeFinishHotkey
        hotkey.aiWorkflowFinishHotkeys = preferences.ai.workflows.compactMap(\.handsFreeFinishHotkey)
        hotkey.isAIFinishEnabled =
            aiRuntimeEnabled
            && activeRecordingMode != nil
            && isRecording
            && (
                preferences.ai.handsFreeFinishHotkey != nil
                || preferences.ai.workflows.contains(where: { $0.handsFreeFinishHotkey != nil })
            )
    }

    // MARK: - Metrics

    private static let metricsDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    var displayName: String {
        let name = preferences.general.userName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty { return name }
        let fullName = NSFullUserName()
        let firstName = fullName.components(separatedBy: " ").first ?? fullName
        return firstName.isEmpty ? "there" : firstName
    }

    var totalWordsDictated: Int {
        metricEntries
            .reduce(0) { total, entry in
                let text = entry.cleanText.isEmpty ? entry.rawText : entry.cleanText
                return total + text.split(whereSeparator: \.isWhitespace).count
            }
    }

    var wordsDictatedToday: Int {
        let calendar = Calendar.current
        return metricEntries
            .filter { calendar.isDateInToday($0.createdAt) }
            .reduce(0) { total, entry in
                let text = entry.cleanText.isEmpty ? entry.rawText : entry.cleanText
                return total + text.split(whereSeparator: \.isWhitespace).count
            }
    }

    private var timedWordsDictated: Int {
        guard let trackingStartedAt = preferences.metricsLifetimeTrackingStartedAt else {
            return 0
        }

        return metricEntries
            .filter { $0.createdAt >= trackingStartedAt }
            .reduce(0) { total, entry in
                let text = entry.cleanText.isEmpty ? entry.rawText : entry.cleanText
                return total + text.split(whereSeparator: \.isWhitespace).count
            }
    }

    var wordsPerMinute: Int {
        let lifetimeSeconds = preferences.metricsRecordingSecondsLifetime
        guard lifetimeSeconds > 0 else {
            return 0
        }
        let minutes = lifetimeSeconds / 60.0
        guard minutes > 0.1 else { return 0 }
        let timedWords = timedWordsDictated
        guard timedWords > 0 else { return 0 }
        return Int(Double(timedWords) / minutes)
    }

    var daysUsed: Int {
        let calendar = Calendar.current
        let uniqueDays = Set(metricEntries.map { calendar.startOfDay(for: $0.createdAt) })
        return uniqueDays.count
    }

    var currentUsageStreak: Int {
        let calendar = Calendar.current
        let uniqueDays = Array(Set(metricEntries.map { calendar.startOfDay(for: $0.createdAt) }))
            .sorted(by: >)

        guard let firstDay = uniqueDays.first else {
            return 0
        }

        var streak = 1
        var previousDay = firstDay

        for day in uniqueDays.dropFirst() {
            guard
                let expectedPrevious = calendar.date(byAdding: .day, value: -1, to: previousDay),
                calendar.isDate(day, inSameDayAs: expectedPrevious)
            else {
                break
            }

            streak += 1
            previousDay = day
        }

        return streak
    }

    var primaryHotkeyLabel: String {
        let hotkeys = preferences.hotkeys
        if hotkeys.optionPressToTalkEnabled {
            return hotkeys.pressToTalkHotkey.displayName
        }
        if let hf = hotkeys.handsFreeGlobalHotkey {
            return handsFreeToggleDisplayName(for: hf)
        }
        return "your hotkey"
    }

    var tapToTalkHotkeyLabel: String {
        if let hotkey = preferences.hotkeys.handsFreeGlobalHotkey {
            return handsFreeToggleDisplayName(for: hotkey)
        }
        return primaryHotkeyLabel
    }

    func accumulateRecordingSeconds(_ seconds: TimeInterval) {
        guard seconds > 0 else { return }
        if preferences.metricsLifetimeTrackingStartedAt == nil {
            preferences.metricsLifetimeTrackingStartedAt = Date()
        }
        let todayString = Self.metricsDateFormatter.string(from: Date())
        if preferences.metricsLastRecordingDate != todayString {
            preferences.metricsRecordingSecondsToday = 0
            preferences.metricsLastRecordingDate = todayString
        }
        preferences.metricsRecordingSecondsToday += seconds
        preferences.metricsRecordingSecondsLifetime += seconds

        Task {
            await preferencesStore.save(preferences)
        }
    }

    private func backfillLifetimeRecordingMetricsIfNeeded() async {
        guard preferences.metricsRecordingSecondsLifetime <= 0,
              !metricEntries.isEmpty else {
            return
        }

        var totalSeconds = 0.0
        for entry in metricEntries {
            guard let url = entry.audioURL,
                  FileManager.default.fileExists(atPath: url.path) else {
                continue
            }

            let asset = AVURLAsset(url: url)
            guard let duration = try? await asset.load(.duration) else {
                continue
            }

            let seconds = CMTimeGetSeconds(duration)
            if seconds.isFinite, seconds > 0 {
                totalSeconds += seconds
            }
        }

        guard totalSeconds > 0 else { return }
        preferences.metricsRecordingSecondsLifetime = totalSeconds
        preferences.metricsLifetimeTrackingStartedAt = metricEntries.map(\.createdAt).min()
        await preferencesStore.save(preferences)
    }

    private func inferLifetimeTrackingStartIfNeeded() async {
        guard preferences.metricsRecordingSecondsLifetime > 0,
              preferences.metricsLifetimeTrackingStartedAt == nil else {
            return
        }

        if let inferredDate = Self.metricsDateFormatter.date(from: preferences.metricsLastRecordingDate) {
            preferences.metricsLifetimeTrackingStartedAt = inferredDate
        } else {
            preferences.metricsLifetimeTrackingStartedAt = Date()
        }

        await preferencesStore.save(preferences)
    }
}

private struct DictationRuntimeFactory {
    let snapshot: AppPreferences
    let clipboardService: any ClipboardService
    let wordFrequencies: [String: Int]

    func makeLexiconService() -> PersonalLexiconService {
        PersonalLexiconService(entries: snapshot.lexiconEntries)
    }

    func makeStyleProfileService() -> StyleProfileService {
        StyleProfileService(
            globalProfile: snapshot.globalStyleProfile,
            appProfiles: snapshot.appStyleProfiles
        )
    }

    func makeSnippetService() -> SnippetService {
        SnippetService(snippets: snapshot.snippets)
    }

    func makeVoiceCommandService() -> VoiceCommandService {
        VoiceCommandService(commands: snapshot.voiceCommands)
    }

    func makeTranscriptionEngine() -> AppleSpeechTranscriptionEngine {
        AppleSpeechTranscriptionEngine(
            config: .init(
                localeIdentifier: snapshot.dictation.localeIdentifier
            )
        )
    }

    func makeCleanupEngine() -> any CleanupEngine {
        RuleBasedCleanupEngine(wordFrequencies: wordFrequencies)
    }

    func makeInsertionTransports() -> [any InsertionTransport] {
        var transports: [any InsertionTransport] = []

        for method in snapshot.insertion.orderedMethods {
            switch method {
            case .direct:
                transports.append(DirectTypingInsertionTransport())
            case .accessibility:
                transports.append(AccessibilityInsertionTransport())
            case .clipboardPaste:
                transports.append(ClipboardInsertionTransport(clipboard: clipboardService, autoPaste: { target in
                    await MacPasteHelper.activateAndPaste(target: target)
                }))
            case .none:
                continue
            }
        }

        if !transports.contains(where: { $0.method == .clipboardPaste }) {
            transports.append(ClipboardInsertionTransport(clipboard: clipboardService, autoPaste: { target in
                await MacPasteHelper.activateAndPaste(target: target)
            }))
        }

        return transports
    }
}
