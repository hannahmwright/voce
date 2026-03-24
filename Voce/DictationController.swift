import AppKit
import Foundation
import SwiftUI
import VoceKit

@MainActor
final class DictationController: ObservableObject {
    private static let minimumVisibleEmptyTranscriptDurationMS = 3_000

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
    @Published var accessibilityPermissionStatus: PermissionDiagnostics.AccessStatus = .unknown
    @Published var inputMonitoringPermissionStatus: PermissionDiagnostics.AccessStatus = .unknown
    @Published var recordingElapsed: TimeInterval = 0
    @Published var hasBootstrapped = false
    @Published var rollingFallbackMetrics = RollingFallbackMetricsSnapshot.empty

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
    private var coordinator: SessionCoordinator?
    private var transcriptionEngine: MoonshineTranscriptionEngine?
    private let learningEngine = LearningEngine()

    private var recordingStateMachine = RecordingStateMachine()
    private var currentSessionID: SessionID?
    private var activeAppContext: AppContext?
    private var activeRecordingMode: RecordingMode?
    private var submitCurrentRecordingRequested = false
    private var activeMediaToken: MediaInterruptionToken?
    private var activeStartTask: Task<Void, Never>?
    private var activePreviewSession: AppleSpeechPreviewSession?
    private var activeRollingFinalizer: RollingChunkFinalizer?
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
        overlay.onUserDraggedToPosition = { [weak self] position in
            self?.saveOverlayDragPosition(position)
        }
        hotkey.onRegistrationStatusChanged = { [weak self] status in
            switch status {
            case .registered:
                self?.hotkeyRegistrationMessage = ""
            case .unavailable(let reason):
                self?.hotkeyRegistrationMessage = reason
                guard let self else { return }
                guard !self.isOverlayReservedForDictationSession else { return }
                self.overlay.show(state: .failure(message: reason))
                self.dismissOverlaySoon()
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
        activeRollingFinalizer = nil
        if let token = activeMediaToken {
            mediaInterruption.endInterruption(token: token)
            activeMediaToken = nil
        }
        recordingTimer?.invalidate()
        recordingTimer = nil
        MoonshineTranscriberCache.shared.invalidate()

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
        await refreshRollingFallbackMetrics()
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
        accessibilityPermissionStatus = PermissionDiagnostics.accessibilityStatus()
        inputMonitoringPermissionStatus = PermissionDiagnostics.inputMonitoringStatus()

        // If permissions changed while app was running, reinstall monitors/hotkeys.
        if recordingStateMachine.state == .idle {
            hotkey.stop()
            hotkey.isOptionPressToTalkEnabled = preferences.hotkeys.optionPressToTalkEnabled
            hotkey.pressToTalkHotkey = preferences.hotkeys.pressToTalkHotkey
            hotkey.globalToggleHotkey = preferences.hotkeys.handsFreeGlobalHotkey
            hotkey.isSubmitActiveRecordingEnabled = false
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
        submitCurrentRecordingRequested = true
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
                overlay.show(state: .failure(message: error.localizedDescription))
                dismissOverlaySoon()
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

    func pasteEntry(_ entry: TranscriptEntry) {
        Task {
            do {
                let text = entry.cleanText.isEmpty ? entry.rawText : entry.cleanText
                try await clipboardService.setString(text)
                status = "Transcript copied to clipboard. Paste with Cmd+V."
            } catch {
                status = "Paste failed"
                lastError = error.localizedDescription
            }
        }
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

    func refreshHistory() async {
        let all = await historyStore.recent(limit: 500)
        let thirtyDaysAgo = Date().addingTimeInterval(-30 * 24 * 60 * 60)
        recentEntries = all.filter { $0.createdAt >= thirtyDaysAgo }
    }

    func refreshRollingFallbackMetrics() async {
        rollingFallbackMetrics = await RollingFallbackMetricsStore.shared.snapshot()
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
        submitCurrentRecordingRequested = false

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

                status = mode == .handsFree ? "Hands-free listening..." : "Recording..."
                isRecording = true
                handsFreeOn = mode == .handsFree
                menuBar.updateIcon(isRecording: true, handsFreeOn: mode == .handsFree)
                activeRecordingMode = mode
                updateSubmitActiveRecordingHotkey()
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
                if let transcriptionEngine {
                    activeRollingFinalizer = RollingChunkFinalizer(transcriptionEngine: transcriptionEngine)
                } else {
                    activeRollingFinalizer = nil
                }

                let session = AppleSpeechPreviewSession(
                    onPartialText: { [weak self] partialText in
                        Task { @MainActor [weak self] in
                            guard let self, self.isRecording else { return }
                            self.overlay.show(state: .liveTranscript(
                                text: partialText,
                                handsFree: mode == .handsFree
                            ))
                        }
                    },
                    onSealedChunk: { [weak self] chunk in
                        guard let self else { return }
                        Task {
                            await self.activeRollingFinalizer?.enqueue(chunk: chunk)
                        }
                    },
                    onTerminalError: { [weak self] error in
                        Task { @MainActor [weak self] in
                            self?.handleStreamingFailure(error)
                        }
                    }
                )
                try await session.start()
                activePreviewSession = session
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
                submitCurrentRecordingRequested = false
                updateSubmitActiveRecordingHotkey()
                activePreviewSession = nil
                activeRollingFinalizer = nil
                recordingStateMachine.markTranscriptionFailed()
                status = "Failed to start"
                lastError = error.localizedDescription
                overlay.show(state: .failure(message: error.localizedDescription))
                dismissOverlaySoon()
            }
            activeStartTask = nil
        }
    }

    private func handleStreamingFailure(_ error: Error) {
        guard let session = activePreviewSession else { return }

        let pendingStart = activeStartTask
        activeStartTask = nil
        activePreviewSession = nil
        activeRollingFinalizer = nil

        recordingTimer?.invalidate()
        recordingTimer = nil
        recordingElapsed = 0
        isRecording = false
        handsFreeOn = false
        menuBar.updateIcon(isRecording: false, handsFreeOn: false)
        activeRecordingMode = nil
        updateSubmitActiveRecordingHotkey()

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
            submitCurrentRecordingRequested = false

            recordingStateMachine.markTranscriptionFailed()
            status = streamingFailureStatusMessage(for: error)
            lastError = error.localizedDescription
            overlay.show(state: .failure(message: error.localizedDescription))
            dismissOverlaySoon()
            await applyDeferredRebuildIfNeeded()
        }
    }

    private func stopSession(mode: RecordingMode) {
        let pendingStart = activeStartTask
        activeStartTask = nil

        // Capture streaming session before clearing state.
        let previewSession = activePreviewSession
        activePreviewSession = nil
        let rollingFinalizer = activeRollingFinalizer
        activeRollingFinalizer = nil

        // Shared cleanup — runs on every path including the guard-return.
        recordingTimer?.invalidate()
        recordingTimer = nil
        recordingElapsed = 0
        isRecording = false
        handsFreeOn = false
        menuBar.updateIcon(isRecording: false, handsFreeOn: false)
        activeRecordingMode = nil
        updateSubmitActiveRecordingHotkey()

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
            let targetAppContext = activeAppContext
            let shouldSubmitWithReturn = submitCurrentRecordingRequested
            activeAppContext = nil
            submitCurrentRecordingRequested = false

            if let token = activeMediaToken {
                mediaInterruption.endInterruption(token: token)
                activeMediaToken = nil
            }

            status = "Finalising..."
            lastError = ""
            overlay.show(state: .transcribing)

            var captureDurationMS = 0
            do {
                guard let stopResult = try previewSession?.stop() else {
                    throw AppleSpeechPreviewError.missingOutputFile
                }
                captureDurationMS = stopResult.captureDurationMS
                let rollingTranscript = await rollingFinalizer?.finish(
                    finalChunk: stopResult.finalChunk,
                    expectedChunkCount: stopResult.totalChunkCount
                )
                let result: InsertResult
                let processingNote: String?
                switch rollingTranscript {
                case .completed(let rollingTranscript):
                    if rollingTranscript.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        await coordinator.cancel(sessionID: sessionID)
                        if shouldSuppressEmptyTranscriptError(captureDurationMS: stopResult.captureDurationMS) {
                            handleShortSilentCapture()
                            await applyDeferredRebuildIfNeeded()
                            return
                        }
                        throw MoonshineTranscriptionError.emptyLiveTranscript
                    }
                    processingNote = nil
                    result = try await coordinator.processStreamingTranscript(
                        rollingTranscript,
                        sessionID: sessionID,
                        processingNote: processingNote
                    )
                case .fallback(let fallbackReason):
                    processingNote = fallbackReason.note
                    await RollingFallbackMetricsStore.shared.increment(reason: fallbackReason)
                    await refreshRollingFallbackMetrics()
                    result = try await coordinator.processStreamingAudio(
                        audioURL: stopResult.captureURL,
                        sessionID: sessionID,
                        processingNote: processingNote
                    )
                case nil:
                    processingNote = RollingChunkFinalizer.FallbackReason.incompleteRollingTranscript.note
                    await RollingFallbackMetricsStore.shared.increment(reason: .incompleteRollingTranscript)
                    await refreshRollingFallbackMetrics()
                    result = try await coordinator.processStreamingAudio(
                        audioURL: stopResult.captureURL,
                        sessionID: sessionID,
                        processingNote: processingNote
                    )
                }

                lastTranscript = result.insertedText
                switch result.status {
                case .inserted:
                    status = "Transcript inserted."
                    lastError = ""
                    overlay.show(state: .inserted)
                case .copiedOnly:
                    status = copiedOnlyStatusMessage(for: result)
                    lastError = result.errorMessage ?? ""
                    overlay.show(state: .copiedOnly)
                case .failed:
                    status = "Transcript ready but insertion failed."
                    let reason = result.errorMessage ?? "Insertion chain exhausted."
                    lastError = reason
                    overlay.show(state: .failure(message: reason))
                }

                if let fallbackWarning = fallbackWarningText(from: result.cleanupOutcome) {
                    status = "\(status) \(fallbackWarning)"
                }
                if let processingNote {
                    status = "\(status) \(processingNote)"
                }

                if shouldSubmitWithReturn, result.status == .inserted, let targetAppContext {
                    let submitOutcome = await MacPasteHelper.activateAndPressReturn(target: targetAppContext)
                    if case .skipped(let reason) = submitOutcome {
                        status = "Transcript inserted."
                        lastError = reason
                    }
                }

                dismissOverlaySoon(pop: result.status == .inserted)
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
                overlay.show(state: .failure(message: error.localizedDescription))
                dismissOverlaySoon()
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
    private static let browserBundleIDs: Set<String> = [
        "com.apple.Safari",
        "com.google.Chrome",
        "org.mozilla.firefox",
        "com.microsoft.edgemac",
        "com.brave.Browser",
        "com.operasoftware.Opera",
        "company.thebrowser.Browser",     // Arc
        "com.vivaldi.Vivaldi",
        "com.nickvision.nicegram",
    ]

    private func saveOverlayDragPosition(_ position: NSPoint) {
        guard let bundleID = activeAppContext?.bundleIdentifier ?? overlayPersistenceBundleIdentifier,
              bundleID != "unknown",
              !Self.browserBundleIDs.contains(bundleID) else { return }

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
        updateSubmitActiveRecordingHotkey()
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

        coordinator = SessionCoordinator(
            captureService: captureService,
            transcriptionEngine: transcription,
            cleanupEngine: cleanupEngine,
            insertionService: insertion,
            historyStore: historyStore,
            lexiconService: lexiconService,
            styleProfileService: styleProfileService,
            snippetService: snippetService,
            voiceCommandService: voiceCommandService,
            fallbackCleanupEngine: RuleBasedCleanupEngine(),
            learningEngine: learningEngine
        )

        MoonshineTranscriberCache.shared.invalidate()
        if snapshot.dictation.keepModelWarm {
            MoonshineTranscriberCache.shared.warm(
                config: MoonshineTranscriptionEngine.Configuration(
                    modelDirectoryPath: snapshot.dictation.modelDirectoryPath,
                    modelArch: snapshot.dictation.modelArch,
                    keepModelWarm: snapshot.dictation.keepModelWarm
                )
            )
        }

        do {
            try launchAtLoginService.setEnabled(snapshot.general.launchAtLoginEnabled)
            launchAtLoginWarning = ""
        } catch {
            launchAtLoginWarning = error.localizedDescription
        }

        status = "Running Apple live preview + Moonshine final transcription + local cleanup."
    }

    private func fallbackWarningText(from outcome: CleanupOutcome?) -> String? {
        guard let outcome, outcome.source == .localFallback else {
            return nil
        }
        return outcome.warning ?? "Primary cleanup unavailable, used local fallback."
    }

    private func validateEngineConfiguration() {
        let missing = MoonshineModelPaths.missingFiles(
            in: preferences.dictation.modelDirectoryPath,
            preset: preferences.dictation.modelArch
        )
        guard missing.isEmpty else {
            status = "Moonshine model not downloaded. Check Settings \u{2192} Engine."
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
        if case MoonshineTranscriptionError.liveCaptureOverloaded = error {
            return "System overloaded. Recording stopped, please try again."
        }

        return "Recording stopped"
    }

    private func shouldSuppressEmptyTranscriptError(_ error: Error? = nil, captureDurationMS: Int) -> Bool {
        guard captureDurationMS > 0, captureDurationMS < Self.minimumVisibleEmptyTranscriptDurationMS else {
            return false
        }

        guard let error else {
            return true
        }

        if case MoonshineTranscriptionError.emptyLiveTranscript = error {
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

    private func updateSubmitActiveRecordingHotkey() {
        hotkey.isSubmitActiveRecordingEnabled =
            preferences.hotkeys.enterFinishesHandsFreeAndSubmits
            && activeRecordingMode == .handsFree
            && isRecording
    }
}

private actor RollingChunkFinalizer {
    enum FinishOutcome: Sendable {
        case completed(RawTranscript)
        case fallback(FallbackReason)
    }

    enum FallbackReason: String, Sendable {
        case weakSeam = "Recovered with full final pass after a weak live chunk seam."
        case chunkTranscriptionFailed = "Recovered with full final pass after a rolling chunk transcription failure."
        case incompleteRollingTranscript = "Recovered with full final pass because rolling chunk finalization was incomplete."

        var note: String { rawValue }
    }

    private struct SeamDecision: Sendable {
        enum Strategy: String, Sendable {
            case initial
            case appendWithoutOverlap
            case tokenOverlap
            case splitWordStitch
            case weakAppend
        }

        let mergedText: String
        let strategy: Strategy
        let score: Double
        let overlapTokens: Int
    }

    private struct ProcessedChunk: Sendable {
        let transcript: RawTranscript
        let durationMS: Int
        let leadingOverlapMS: Int
    }

    private struct CombinedTranscriptResult: Sendable {
        let transcript: RawTranscript
        let weakBoundaryCount: Int
        let weakestBoundaryScore: Double
    }

    private let transcriptionEngine: MoonshineTranscriptionEngine
    private var queuedChunks: [CapturedAudioChunk] = []
    private var processedChunks: [Int: ProcessedChunk] = [:]
    private var failure: Error?
    private var workerTask: Task<Void, Never>?
    private let diagnostics = RollingSeamDiagnostics()
    private static let minimumAcceptableBoundaryScore = 0.45
    private static let weakBoundaryThreshold = 0.70

    init(transcriptionEngine: MoonshineTranscriptionEngine) {
        self.transcriptionEngine = transcriptionEngine
    }

    func enqueue(chunk: CapturedAudioChunk) {
        queuedChunks.append(chunk)
        startWorkerIfNeeded()
    }

    func finish(finalChunk: CapturedAudioChunk?, expectedChunkCount: Int) async -> FinishOutcome {
        diagnostics.reset()

        if let finalChunk {
            enqueue(chunk: finalChunk)
        }

        while let workerTask {
            await workerTask.value
        }

        if failure != nil {
            diagnostics.record("rolling transcript unavailable reason=chunkTranscriptionFailed failure=\(String(describing: failure)) expectedChunks=\(expectedChunkCount) processedChunks=\(processedChunks.count)")
            diagnostics.flush()
            return .fallback(.chunkTranscriptionFailed)
        }

        guard expectedChunkCount > 0, processedChunks.count == expectedChunkCount else {
            diagnostics.record("rolling transcript unavailable reason=incompleteRollingTranscript expectedChunks=\(expectedChunkCount) processedChunks=\(processedChunks.count)")
            diagnostics.flush()
            return .fallback(.incompleteRollingTranscript)
        }

        let combinedResult = buildCombinedTranscript(expectedChunkCount: expectedChunkCount)
        if combinedResult.weakBoundaryCount > 0 {
            diagnostics.record(
                "weak boundaries detected count=\(combinedResult.weakBoundaryCount) weakestScore=\(String(format: "%.2f", combinedResult.weakestBoundaryScore))"
            )
        }

        guard combinedResult.weakestBoundaryScore >= Self.minimumAcceptableBoundaryScore else {
            diagnostics.record(
                "rolling transcript rejected due to low seam score threshold=\(String(format: "%.2f", Self.minimumAcceptableBoundaryScore))"
            )
            diagnostics.flush()
            return .fallback(.weakSeam)
        }

        if combinedResult.weakBoundaryCount > 0 {
            diagnostics.flush()
        }

        return .completed(combinedResult.transcript)
    }

    private func startWorkerIfNeeded() {
        guard workerTask == nil else { return }
        workerTask = Task { [weak self] in
            await self?.drainQueue()
        }
    }

    private func drainQueue() async {
        while !queuedChunks.isEmpty {
            let chunk = queuedChunks.removeFirst()
            defer { try? FileManager.default.removeItem(at: chunk.url) }

            do {
                let rawTranscript = try await transcriptionEngine.transcribe(
                    audioURL: chunk.url,
                    languageHints: ["en-US"]
                )
                processedChunks[chunk.index] = ProcessedChunk(
                    transcript: rawTranscript,
                    durationMS: chunk.durationMS,
                    leadingOverlapMS: chunk.leadingOverlapMS
                )
            } catch {
                failure = error
            }
        }

        workerTask = nil
    }

    private func buildCombinedTranscript(expectedChunkCount: Int) -> CombinedTranscriptResult {
        var combinedSegments: [TranscriptSegment] = []
        var mergedText = ""
        var offsetMS = 0
        var weakestBoundaryScore = 1.0
        var weakBoundaryCount = 0

        for chunkIndex in 0..<expectedChunkCount {
            guard let processedChunk = processedChunks[chunkIndex] else { continue }
            let normalizedChunkText = processedChunk.transcript.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let seamDecision = Self.mergeText(
                accumulated: mergedText,
                next: normalizedChunkText,
                hasLeadingOverlap: processedChunk.leadingOverlapMS > 0
            )
            mergedText = seamDecision.mergedText

            if chunkIndex > 0 {
                weakestBoundaryScore = min(weakestBoundaryScore, seamDecision.score)
                if seamDecision.score < Self.weakBoundaryThreshold {
                    weakBoundaryCount += 1
                    diagnostics.record(
                        "boundary chunk=\(chunkIndex - 1)->\(chunkIndex) strategy=\(seamDecision.strategy.rawValue) score=\(String(format: "%.2f", seamDecision.score)) overlapTokens=\(seamDecision.overlapTokens) leadingOverlapMS=\(processedChunk.leadingOverlapMS)"
                    )
                }
            }

            let visibleAdvanceMS = max(0, processedChunk.durationMS - processedChunk.leadingOverlapMS)
            combinedSegments.append(
                contentsOf: processedChunk.transcript.segments.compactMap { segment in
                    guard segment.endMS > processedChunk.leadingOverlapMS else { return nil }
                    let adjustedStartMS = max(0, segment.startMS - processedChunk.leadingOverlapMS)
                    let adjustedEndMS = max(0, segment.endMS - processedChunk.leadingOverlapMS)
                    return TranscriptSegment(
                        startMS: adjustedStartMS + offsetMS,
                        endMS: adjustedEndMS + offsetMS,
                        text: segment.text,
                        confidence: segment.confidence
                    )
                }
            )
            offsetMS += visibleAdvanceMS
        }

        return CombinedTranscriptResult(
            transcript: RawTranscript(
                text: ConsecutivePhraseDeduplicator.collapse(mergedText),
                segments: combinedSegments,
                durationMS: offsetMS
            ),
            weakBoundaryCount: weakBoundaryCount,
            weakestBoundaryScore: weakestBoundaryScore
        )
    }

    private static func mergeText(accumulated: String, next: String, hasLeadingOverlap: Bool) -> SeamDecision {
        let trimmedAccumulated = accumulated.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedNext = next.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmedAccumulated.isEmpty else {
            return SeamDecision(mergedText: trimmedNext, strategy: .initial, score: 1.0, overlapTokens: 0)
        }
        guard !trimmedNext.isEmpty else {
            return SeamDecision(mergedText: trimmedAccumulated, strategy: .initial, score: 1.0, overlapTokens: 0)
        }
        guard hasLeadingOverlap else {
            return SeamDecision(
                mergedText: "\(trimmedAccumulated) \(trimmedNext)",
                strategy: .appendWithoutOverlap,
                score: 1.0,
                overlapTokens: 0
            )
        }

        let accumulatedTokens = tokenComponents(for: trimmedAccumulated)
        let nextTokens = tokenComponents(for: trimmedNext)

        let maxOverlap = min(accumulatedTokens.count, nextTokens.count, 12)
        var bestOverlap = 0

        if maxOverlap > 0 {
            for overlap in stride(from: maxOverlap, through: 1, by: -1) {
                let accumulatedSuffix = Array(accumulatedTokens.suffix(overlap))
                let nextPrefix = Array(nextTokens.prefix(overlap))
                if normalized(accumulatedSuffix) == normalized(nextPrefix) {
                    bestOverlap = overlap
                    break
                }
            }
        }

        if bestOverlap > 0 {
            let mergedTokens = accumulatedTokens + nextTokens.dropFirst(bestOverlap)
            let score = bestOverlap >= 2 ? 1.0 : 0.85
            return SeamDecision(
                mergedText: mergedTokens.joined(separator: " "),
                strategy: .tokenOverlap,
                score: score,
                overlapTokens: bestOverlap
            )
        }

        // Fallback for split words where token overlap cannot match.
        if let stitched = stitchSplitWord(accumulated: trimmedAccumulated, next: trimmedNext) {
            return SeamDecision(
                mergedText: stitched,
                strategy: .splitWordStitch,
                score: 0.75,
                overlapTokens: 0
            )
        }

        return SeamDecision(
            mergedText: "\(trimmedAccumulated) \(trimmedNext)",
            strategy: .weakAppend,
            score: 0.20,
            overlapTokens: 0
        )
    }

    private static func tokenComponents(for text: String) -> [String] {
        text.split(whereSeparator: \.isWhitespace).map(String.init)
    }

    private static func normalized(_ tokens: [String]) -> [String] {
        tokens.map {
            $0.lowercased().trimmingCharacters(in: .punctuationCharacters.union(.symbols))
        }
    }

    private static func stitchSplitWord(accumulated: String, next: String) -> String? {
        guard let lastAccumulatedToken = accumulated.split(whereSeparator: \.isWhitespace).last,
              let firstNextToken = next.split(whereSeparator: \.isWhitespace).first else {
            return nil
        }

        let left = String(lastAccumulatedToken)
        let right = String(firstNextToken)
        guard left.last?.isLetter == true, right.first?.isLetter == true else {
            return nil
        }
        guard left.count <= 12, right.count <= 12 else {
            return nil
        }

        let accumulatedPrefix = accumulated.dropLast(left.count).trimmingCharacters(in: .whitespacesAndNewlines)
        let nextSuffix = next.dropFirst(right.count).trimmingCharacters(in: .whitespacesAndNewlines)
        let stitchedWord = left + right

        if accumulatedPrefix.isEmpty {
            return nextSuffix.isEmpty ? stitchedWord : "\(stitchedWord) \(nextSuffix)"
        }

        if nextSuffix.isEmpty {
            return "\(accumulatedPrefix) \(stitchedWord)"
        }

        return "\(accumulatedPrefix) \(stitchedWord) \(nextSuffix)"
    }
}

private final class RollingSeamDiagnostics: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []
    private let sessionID = UUID().uuidString

    func reset() {
        lock.lock()
        lines.removeAll(keepingCapacity: true)
        lock.unlock()
    }

    func record(_ message: String) {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        lock.lock()
        lines.append("[\(timestamp)] \(message)")
        if lines.count > 200 {
            lines.removeFirst(lines.count - 200)
        }
        lock.unlock()
    }

    func flush() {
        lock.lock()
        let content = lines.joined(separator: "\n")
        lock.unlock()

        guard !content.isEmpty else { return }

        let fileManager = FileManager.default
        let baseDirectory = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Voce/Diagnostics", isDirectory: true)
        guard let directory = baseDirectory else { return }

        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            let logURL = directory.appendingPathComponent("rolling-seams-\(sessionID).log")
            try content.write(to: logURL, atomically: true, encoding: .utf8)
        } catch {
            return
        }
    }
}

struct RollingFallbackMetricsSnapshot: Codable, Sendable {
    var totalFallbacks: Int
    var weakSeamFallbacks: Int
    var chunkTranscriptionFailureFallbacks: Int
    var incompleteRollingTranscriptFallbacks: Int
    var updatedAt: Date

    static let empty = RollingFallbackMetricsSnapshot(
        totalFallbacks: 0,
        weakSeamFallbacks: 0,
        chunkTranscriptionFailureFallbacks: 0,
        incompleteRollingTranscriptFallbacks: 0,
        updatedAt: .distantPast
    )
}

private actor RollingFallbackMetricsStore {

    static let shared = RollingFallbackMetricsStore()

    private let storageURL: URL
    private var cachedSnapshot: RollingFallbackMetricsSnapshot?

    init(storageURL: URL? = nil) {
        if let storageURL {
            self.storageURL = storageURL
        } else {
            let baseDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
                .appendingPathComponent("Voce/Diagnostics", isDirectory: true)
            self.storageURL = (baseDirectory ?? FileManager.default.temporaryDirectory)
                .appendingPathComponent("rolling-fallback-metrics.json")
        }
    }

    func increment(reason: RollingChunkFinalizer.FallbackReason) {
        var snapshot = loadSnapshot()
        snapshot.totalFallbacks += 1
        snapshot.updatedAt = Date()

        switch reason {
        case .weakSeam:
            snapshot.weakSeamFallbacks += 1
        case .chunkTranscriptionFailed:
            snapshot.chunkTranscriptionFailureFallbacks += 1
        case .incompleteRollingTranscript:
            snapshot.incompleteRollingTranscriptFallbacks += 1
        }

        persist(snapshot)
    }

    func snapshot() -> RollingFallbackMetricsSnapshot {
        loadSnapshot()
    }

    private func loadSnapshot() -> RollingFallbackMetricsSnapshot {
        if let cachedSnapshot {
            return cachedSnapshot
        }

        guard FileManager.default.fileExists(atPath: storageURL.path) else {
            cachedSnapshot = .empty
            return .empty
        }

        do {
            let data = try Data(contentsOf: storageURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let snapshot = try decoder.decode(RollingFallbackMetricsSnapshot.self, from: data)
            cachedSnapshot = snapshot
            return snapshot
        } catch {
            cachedSnapshot = .empty
            return .empty
        }
    }

    private func persist(_ snapshot: RollingFallbackMetricsSnapshot) {
        do {
            try FileManager.default.createDirectory(
                at: storageURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(snapshot)
            try data.write(to: storageURL, options: .atomic)
            cachedSnapshot = snapshot
        } catch {
            return
        }
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

    func makeTranscriptionEngine() -> MoonshineTranscriptionEngine {
        MoonshineTranscriptionEngine(
            config: .init(
                modelDirectoryPath: snapshot.dictation.modelDirectoryPath,
                modelArch: snapshot.dictation.modelArch,
                keepModelWarm: snapshot.dictation.keepModelWarm
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
