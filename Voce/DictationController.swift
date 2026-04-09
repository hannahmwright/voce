import AppKit
import Foundation
import OSLog
import SwiftUI
import VoceKit

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
    private var pendingRuntimeRebuild = false
    private let menuBar = MenuBarController()
    private var recordingTimer: Timer?
    private var overlayDismissTask: Task<Void, Never>?
    private var terminationObserver: Any?
    private var overlayPersistenceBundleIdentifier: String?

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
        apply(transition: recordingStateMachine.handlePressToTalkKeyDown())
    }

    func pressToTalkStop() {
        guard preferences.hotkeys.optionPressToTalkEnabled else { return }
        apply(transition: recordingStateMachine.handlePressToTalkKeyUp())
    }

    func toggleHandsFree() {
        apply(transition: recordingStateMachine.handleHandsFreeToggle())
    }

    func submitActiveRecording() {
        guard activeRecordingMode == .handsFree, isRecording else { return }
        guard preferences.hotkeys.enterFinishesHandsFreeAndSubmits else { return }
        pendingCompletionActionOverride = .insertAndSubmit
        toggleHandsFree()
    }

    func finishActiveRecordingWithAI(triggeredBy hotkey: HandsFreeHotkey? = nil) {
        guard activeRecordingMode == .handsFree, isRecording else { return }
        guard preferences.ai.isEnabled else { return }
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
        toggleHandsFree()
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
            trigger: suggestion.phrase,
            expansion: suggestion.phrase,
            scope: .global
        )
        preferences.snippets.append(snippet)
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
                    onPartialText: { [weak self] partialText in
                        Task { @MainActor [weak self] in
                            guard let self, self.isRecording else { return }
                            self.overlay.show(state: .listening(
                                handsFree: mode == .handsFree,
                                elapsedSeconds: Int(self.recordingElapsed)
                            ))
                        }
                    },
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
                    leadingPhraseSelectionEnabled: preferences.ai.isEnabled && preferences.ai.leadingPhraseSelectionEnabled,
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
                    applyExecutionOutcomeStatus(execution)
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

    private func applyExecutionOutcomeStatus(_ execution: CompletionExecutionOutcome) {
        let result = execution.insertResult
        let baseStatus: String
        switch execution.action {
        case .insert, .insertAndSubmit:
            switch result.status {
            case .inserted:
                baseStatus = "Transcript inserted."
                lastError = ""
            case .copiedOnly:
                baseStatus = copiedOnlyStatusMessage(for: result)
                lastError = result.errorMessage ?? ""
            case .failed:
                let reason = result.errorMessage ?? "Insertion chain exhausted."
                baseStatus = "Transcript ready but insertion failed."
                lastError = reason
            }
        case .aiWorkflow:
            switch result.status {
            case .inserted:
                baseStatus = "AI result inserted."
                lastError = ""
            case .copiedOnly:
                baseStatus = "AI result copied to clipboard. Paste with Cmd+V."
                lastError = result.errorMessage ?? ""
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
            preferences.ai.isEnabled
            && activeRecordingMode == .handsFree
            && isRecording
            && (
                preferences.ai.handsFreeFinishHotkey != nil
                || preferences.ai.workflows.contains(where: { $0.handsFreeFinishHotkey != nil })
            )
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
