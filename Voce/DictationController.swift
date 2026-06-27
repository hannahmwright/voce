import AppKit
import ApplicationServices
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
struct DailyUsageActivityDay: Equatable {
    let day: Date
    let wordCount: Int
    let sessionCount: Int
}

private enum ActiveCloudUsageMetering {
    case voceHosted
    case directOpenAI
}

@MainActor
final class DictationController: ObservableObject {
    private static let minimumVisibleEmptyTranscriptDurationMS = 3_000
    private static let directOpenAIEstimatedCostPerMinute = 0.017
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
    @Published var historyAIProcessingEntryID: UUID?
    @Published var hotkeyRegistrationMessage: String = ""
    @Published var launchAtLoginWarning: String = ""
    @Published var preferences: AppPreferences = .default
    @Published var microphonePermissionStatus: PermissionDiagnostics.AccessStatus = .unknown
    @Published var speechRecognitionPermissionStatus: PermissionDiagnostics.AccessStatus = .unknown
    @Published var accessibilityPermissionStatus: PermissionDiagnostics.AccessStatus = .unknown
    @Published var inputMonitoringPermissionStatus: PermissionDiagnostics.AccessStatus = .unknown
    @Published var recordingElapsed: TimeInterval = 0
    @Published var hasBootstrapped = false
    @Published private(set) var backgroundProcessingSessionCount: Int = 0
    @Published var voceProEntitlementStatus: VoceProEntitlementStatus = .missingEmail {
        didSet {
            guard hasBootstrapped else { return }
            if voceProEntitlementStatus.isEntitled {
                prefetchRealtimeWhisperClientSecretIfNeeded()
            }
            if cloudRoutingSignature(for: oldValue) != cloudRoutingSignature(for: voceProEntitlementStatus) {
                Task { @MainActor [weak self] in
                    await self?.rebuildRuntimeOrDefer(announceImmediateSave: false)
                }
            }
        }
    }

    private let captureService = MacAudioCaptureService()
    private let clipboardService = MacClipboardService()
    private let historyStore: HistoryStore
    private let hotkey: MacHotkeyMonitor
    private let overlay: MacOverlayPresenter
    private let mediaInterruption: MediaInterruptionService
    private let preferencesStore: AppPreferencesStore
    private let launchAtLoginService: LaunchAtLoginService
    private let entitlementService: VoceProEntitlementService
    private let clipboardRecoveryPrompt = ClipboardRecoveryPromptPresenter()

    private var lexiconService: PersonalLexiconService
    private var styleProfileService: StyleProfileService
    private var snippetService: SnippetService
    private var voiceCommandService: VoiceCommandService
    private var dictationEngineModeResolver = DictationEngineModeResolver(
        globalMode: AppPreferences.default.dictation.engineMode,
        appPreferences: AppPreferences.default.appDictationEnginePreferences,
        cloudModeAvailable: VoceRuntimeConfiguration.isDevApp
    )
    private var insertionService: any InsertionServiceProtocol = InsertionService(transports: [])
    private var coordinator: SessionCoordinator?
    private let cloudDictationAvailabilityService = CloudDictationAvailabilityService()
    private let learningEngine = LearningEngine()
    private let completionRoutingService = CompletionRoutingService()
    private let aiGenerationService = AppleFoundationModelsService()

    private var recordingStateMachine = RecordingStateMachine()
    private var currentSessionID: SessionID?
    private var activeAppContext: AppContext?
    private var activeRecordingMode: RecordingMode?
    private var pendingCompletionActionOverride: CompletionAction?
    private var activeStyleOverride: StyleProfile?
    private var activeMediaToken: MediaInterruptionToken?
    private var activeStartTask: Task<Void, Never>?
    private var activeStartTaskID: UUID?
    private var activePreviewSession: AppleSpeechPreviewSession?
    private var activeRealtimeWhisperSession: OpenAIRealtimeWhisperCaptureSession?
    private var activeCloudUsageMetering: ActiveCloudUsageMetering?
    private var metricEntries: [TranscriptEntry] = []
    private var pendingRuntimeRebuild = false
    private let menuBar = MenuBarController()
    private var recordingTimer: Timer?
    private var overlayDismissTask: Task<Void, Never>?
    private var entitlementRefreshTask: Task<Void, Never>?
    private var realtimeWhisperClientSecretPrefetchTask: Task<Void, Never>?
    private var realtimeWhisperClientSecretRefreshTask: Task<Void, Never>?
    private var captureReadyOverlayStartTaskID: UUID?
    private var terminationObserver: Any?
    private var overlayPersistenceBundleIdentifier: String?
    private var activeFreeUsageLimitSeconds: TimeInterval?
    private var activeHostedCloudUsageLimitSeconds: TimeInterval?
    private var suppressNextPressToTalkStop = false
    private var cloudValidationTask: Task<Void, Never>?
    private var cloudValidationCredentialVersion = UUID()
    private var lastCloudValidationToken: String?
    private var lastCloudValidationFailureMessage: String?
    private var nextBackgroundProcessingSequence = 0
    private var nextCompletionSequenceToCommit = 0
    private var completedCompletionSequences = Set<Int>()
    private var completionSequenceWaiters: [Int: CheckedContinuation<Void, Never>] = [:]
    private var pendingStartAfterAudioSecured: RecordingMode?
    private var lastRecordingStopTime: CFAbsoluteTime = 0
    private var lastRecordingStopMode: RecordingMode?

    private struct SelectionCapture {
        var text: String
        var appContext: AppContext
    }

    private struct PasteboardSnapshot {
        private var items: [NSPasteboardItem] = []

        init(pasteboard: NSPasteboard) {
            items = pasteboard.pasteboardItems?.map { item in
                let copy = NSPasteboardItem()
                for type in item.types {
                    if let data = item.data(forType: type) {
                        copy.setData(data, forType: type)
                    } else if let string = item.string(forType: type) {
                        copy.setString(string, forType: type)
                    }
                }
                return copy
            } ?? []
        }

        func restore(to pasteboard: NSPasteboard) {
            pasteboard.clearContents()
            guard !items.isEmpty else { return }
            pasteboard.writeObjects(items)
        }
    }

    init(
        hotkey: MacHotkeyMonitor = MacHotkeyMonitor(),
        overlay: MacOverlayPresenter = MacOverlayPresenter(),
        mediaInterruption: MediaInterruptionService = MacMediaInterruptionService(),
        preferencesStore: AppPreferencesStore = AppPreferencesStore(),
        launchAtLoginService: LaunchAtLoginService = LaunchAtLoginService(),
        entitlementService: VoceProEntitlementService = VoceProEntitlementService()
    ) {
        self.hotkey = hotkey
        self.overlay = overlay
        self.mediaInterruption = mediaInterruption
        self.preferencesStore = preferencesStore
        self.launchAtLoginService = launchAtLoginService
        self.entitlementService = entitlementService
        self.historyStore = HistoryStore(clipboardService: clipboardService)
        self.lexiconService = PersonalLexiconService(entries: AppPreferences.default.lexiconEntries)
        self.styleProfileService = StyleProfileService(
            globalProfile: AppPreferences.default.globalStyleProfile,
            appProfiles: AppPreferences.default.appStyleProfiles
        )
        self.snippetService = SnippetService(snippets: AppPreferences.default.snippets)
        self.voiceCommandService = VoiceCommandService(commands: AppPreferences.default.voiceCommands)

        captureService.onAudioLevelChanged = { [weak overlay] level in
            overlay?.updateAudioLevel(level)
        }

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
        hotkey.onCaptureSelectionCorrection = { [weak self] in
            self?.captureSelectionForCorrection()
        }
        hotkey.onCaptureSelectionSnippet = { [weak self] in
            self?.captureSelectionForSnippet()
        }
        hotkey.onVoceActionsTap = { [weak self] in
            self?.showVoceActionsPicker()
        }
        overlay.onUserDraggedToPosition = { [weak self] position in
            self?.saveOverlayDragPosition(position)
        }
        overlay.onStopRequested = { [weak self] in
            self?.stopActiveRecording()
        }
        overlay.onAIWorkflowRequested = { [weak self] workflowID in
            self?.finishActiveRecordingWithAI(workflowID: workflowID)
        }
        overlay.onStyleRequested = { [weak self] mode in
            self?.applyActiveRecordingStyleOverride(mode)
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
        entitlementRefreshTask?.cancel()
        entitlementRefreshTask = nil
        realtimeWhisperClientSecretPrefetchTask?.cancel()
        realtimeWhisperClientSecretPrefetchTask = nil
        realtimeWhisperClientSecretRefreshTask?.cancel()
        realtimeWhisperClientSecretRefreshTask = nil
        captureReadyOverlayStartTaskID = nil
        overlay.hide()
        clipboardRecoveryPrompt.hide()
        overlayPersistenceBundleIdentifier = nil
        activeStartTask?.cancel()
        activeStartTask = nil
        activePreviewSession?.cancel()
        activePreviewSession = nil
        activeRealtimeWhisperSession?.cancel()
        activeRealtimeWhisperSession = nil
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
        return recordingStateMachine.state
    }

    func bootstrap() async {
        var loaded = await preferencesStore.load()
        loaded.normalize()

        // Email verification is required for every plan (free/base/pro). If a
        // previous build let the user finish onboarding without a verified
        // access session, force onboarding back on so they complete access.
        let trimmedSubscriberEmail = loaded.billing.subscriberEmail
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let hasVerifiedAccessSession: Bool
        if trimmedSubscriberEmail.isEmpty {
            hasVerifiedAccessSession = false
        } else {
            hasVerifiedAccessSession = await entitlementService.hasAccessSession(email: trimmedSubscriberEmail)
        }
        if !loaded.general.showOnboarding && !hasVerifiedAccessSession {
            loaded.general.showOnboarding = true
        }

        applyPreferencesLocally(loaded)
        refreshPermissionStatuses()
        validateEngineConfiguration()
        await rebuildRuntime()
        await refreshHistory()
        await backfillLifetimeRecordingMetricsIfNeeded()
        await inferLifetimeTrackingStartIfNeeded()
        overlay.prepareWindow()
        hasBootstrapped = true
        scheduleVoceProEntitlementRefresh(immediate: true)
        prefetchRealtimeWhisperClientSecretIfNeeded()
    }

    func savePreferences(announceImmediateSave: Bool = true) {
        let previousSubscriberEmail = normalizedSubscriberEmail
        var snapshot = preferences
        snapshot.normalize()
        preferences = snapshot
        scheduleVoceProEntitlementRefreshIfNeeded(previousEmail: previousSubscriberEmail)

        Task {
            await preferencesStore.save(snapshot)
            await rebuildRuntimeOrDefer(announceImmediateSave: announceImmediateSave)
        }
    }

    func applySettingsDraft(preferences draft: AppPreferences, announceImmediateSave: Bool = true) {
        let previousSubscriberEmail = normalizedSubscriberEmail
        var snapshot = draft
        snapshot.normalize()
        preferences = snapshot
        scheduleVoceProEntitlementRefreshIfNeeded(previousEmail: previousSubscriberEmail)

        Task {
            await preferencesStore.save(snapshot)
            await rebuildRuntimeOrDefer(announceImmediateSave: announceImmediateSave)
        }
    }

    /// Persist preferences to disk without rebuilding the dictation runtime.
    /// Use this for non-runtime fields like scratchPadContent, userName, and metrics.
    func savePreferencesQuietly(preferences draft: AppPreferences) {
        let previousSubscriberEmail = normalizedSubscriberEmail
        var snapshot = draft
        snapshot.normalize()
        preferences = snapshot
        scheduleVoceProEntitlementRefreshIfNeeded(previousEmail: previousSubscriberEmail)

        Task {
            await preferencesStore.save(snapshot)
        }
    }

    func refreshVoceProEntitlement() {
        scheduleVoceProEntitlementRefresh(immediate: true)
    }

    func requestVoceAccessCode(email: String) async throws {
        try await entitlementService.requestVerificationCode(email: email)
    }

    func verifyVoceAccessCode(email: String, code: String) async throws {
        _ = try await entitlementService.verifyCode(email: email, code: code)
        scheduleVoceProEntitlementRefresh(immediate: true)
    }

    #if DEBUG
    func resetVoceAccessSessionForTesting() {
        let email = normalizedSubscriberEmail
        guard !email.isEmpty else {
            voceProEntitlementStatus = .missingEmail
            return
        }

        Task { [weak self, entitlementService] in
            do {
                try await entitlementService.clearSession(email: email)
                await MainActor.run {
                    guard self?.normalizedSubscriberEmail == email else { return }
                    self?.status = "Voce access session reset."
                    self?.voceProEntitlementStatus = .needsVerification(email: email)
                }
            } catch {
                let message = (error as? LocalizedError)?.errorDescription
                    ?? "Could not reset Voce access."
                await MainActor.run {
                    guard self?.normalizedSubscriberEmail == email else { return }
                    self?.voceProEntitlementStatus = .failed(email: email, message: message)
                }
            }
        }
    }
    #endif

    func openVoceCheckout(plan: VoceCheckoutPlan, billingCycle: VoceCheckoutBillingCycle) {
        let email = normalizedSubscriberEmail
        guard !email.isEmpty else {
            status = "Enter your email to choose a Voce plan."
            lastError = status
            return
        }

        status = "Opening \(plan.title) checkout..."
        Task { [weak self, entitlementService] in
            do {
                let checkoutURL = try await entitlementService.checkoutURL(
                    email: email,
                    plan: plan,
                    billingCycle: billingCycle
                )
                await MainActor.run {
                    NSWorkspace.shared.open(checkoutURL)
                    self?.status = "\(plan.title) checkout opened."
                }
            } catch {
                let message = (error as? LocalizedError)?.errorDescription
                    ?? "Could not open checkout."
                await MainActor.run {
                    self?.status = message
                    self?.lastError = message
                }
            }
        }
    }

    func openVoceProPortal() {
        let email = normalizedSubscriberEmail
        guard !email.isEmpty else {
            status = "Enter your email to manage your subscription."
            lastError = status
            return
        }

        status = "Opening subscription settings..."
        Task { [weak self, entitlementService] in
            do {
                let portalURL = try await entitlementService.portalURL(email: email)
                await MainActor.run {
                    NSWorkspace.shared.open(portalURL)
                    self?.status = "Subscription settings opened."
                }
            } catch {
                let message = (error as? LocalizedError)?.errorDescription
                    ?? "Could not open subscription settings."
                await MainActor.run {
                    self?.status = message
                    self?.lastError = message
                }
            }
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
            hotkey.selectionCorrectionHotkey = preferences.hotkeys.dictionaryCorrectionHotkey
            hotkey.selectionSnippetHotkey = preferences.hotkeys.snippetCreationHotkey
            hotkey.isVoceActionsTapEnabled = preferences.hotkeys.voceActionsTapEnabled
            hotkey.isSubmitActiveRecordingEnabled = false
            hotkey.aiFinishHotkey = preferences.ai.handsFreeFinishHotkey
            hotkey.aiWorkflowFinishHotkeys = preferences.ai.workflows.compactMap(\.handsFreeFinishHotkey)
            hotkey.isAIFinishEnabled = false
            hotkey.start()
        }
    }

    func pressToTalkStart() {
        guard preferences.hotkeys.optionPressToTalkEnabled else { return }
        guard !shouldIgnoreResidualStartSignal(mode: .pressToTalk) else { return }
        if queueStartAfterAudioSecuredIfNeeded(mode: .pressToTalk) {
            return
        }
        guard canStartRecordingNow() else { return }
        suppressNextPressToTalkStop = false
        apply(transition: recordingStateMachine.handlePressToTalkKeyDown())
    }

    func pressToTalkStop() {
        guard preferences.hotkeys.optionPressToTalkEnabled else { return }
        if pendingStartAfterAudioSecured == .pressToTalk {
            pendingStartAfterAudioSecured = nil
            return
        }
        if suppressNextPressToTalkStop {
            suppressNextPressToTalkStop = false
            return
        }
        if preferences.hotkeys.enterFinishesHandsFreeAndSubmits {
            pendingCompletionActionOverride = .insertAndSubmit
        }
        let transition = recordingStateMachine.handlePressToTalkKeyUp()
        if case .ignore = transition,
           isRecording,
           activeRecordingMode == .pressToTalk {
            stopSession(mode: .pressToTalk)
            return
        }
        apply(transition: transition)
    }

    func toggleHandsFree() {
        if isRecording,
           activeRecordingMode == .handsFree,
           recordingStateMachine.state != .recordingHandsFree {
            stopSession(mode: .handsFree)
            return
        }
        if recordingStateMachine.state == .idle {
            guard !shouldIgnoreResidualStartSignal(mode: .handsFree) else { return }
        }
        if queueStartAfterAudioSecuredIfNeeded(mode: .handsFree) {
            return
        }
        if recordingStateMachine.state == .idle {
            guard canStartRecordingNow() else { return }
        }
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
            if let activeRecordingMode, isRecording {
                stopSession(mode: activeRecordingMode)
            }
        }
    }

    func submitActiveRecording() {
        guard activeRecordingMode == .handsFree, isRecording else { return }
        guard preferences.hotkeys.enterFinishesHandsFreeAndSubmits else { return }
        pendingCompletionActionOverride = .insertAndSubmit
        toggleHandsFree()
    }

    func finishActiveRecordingWithAI(triggeredBy hotkey: HandsFreeHotkey? = nil) {
        let workflowID: UUID?
        if let hotkey {
            workflowID = preferences.ai.workflows.first(where: { $0.handsFreeFinishHotkey == hotkey })?.id
        } else {
            workflowID = preferences.ai.defaultHandsFreeWorkflowID
        }
        guard let workflowID else { return }
        finishActiveRecordingWithAI(workflowID: workflowID)
    }

    func finishActiveRecordingWithAI(workflowID: UUID) {
        guard let activeRecordingMode, isRecording else { return }
        guard aiRuntimeEnabled else { return }
        guard let workflow = preferences.ai.workflows.first(where: { $0.id == workflowID && $0.isEnabled }) else {
            status = "That AI workflow is not available."
            return
        }
        status = "Finishing with \(workflow.name.lowercased())…"
        pendingCompletionActionOverride = .aiWorkflow(id: workflowID)
        switch activeRecordingMode {
        case .handsFree:
            toggleHandsFree()
        case .pressToTalk:
            suppressNextPressToTalkStop = true
            apply(transition: recordingStateMachine.handlePressToTalkKeyUp())
        }
    }

    private func applyActiveRecordingStyleOverride(_ structureMode: StructureMode) {
        guard isRecording, let activeAppContext else { return }
        var profile = effectiveStyleProfile(for: activeAppContext)
        profile.name = "This Dictation"
        profile.structureMode = structureMode
        activeStyleOverride = profile
        overlay.selectedControlStyle = structureMode
        status = "Style set to \(styleTitle(for: structureMode))."
    }

    func captureSelectionForCorrection() {
        guard !isRecording else {
            status = "Finish recording before using dictionary quick fix."
            lastError = status
            return
        }

        Task { @MainActor [weak self] in
            guard let self else { return }
            guard let capture = await captureFrontmostSelection() else {
                status = "Select text first, then press the dictionary quick fix shortcut."
                lastError = status
                return
            }
            self.presentDictionaryCorrectionPopover(for: capture)
        }
    }

    func captureSelectionForSnippet() {
        guard !isRecording else {
            status = "Finish recording before creating a shortcut."
            lastError = status
            return
        }

        Task { @MainActor [weak self] in
            guard let self else { return }
            guard let capture = await captureFrontmostSelection() else {
                status = "Select text first, then press the create snippet shortcut."
                lastError = status
                return
            }
            self.presentSnippetCreationPopover(for: capture)
        }
    }

    /// Entry point for the Cmd+Option tap. Captures the frontmost selection
    /// before showing any UI (otherwise the popover steals focus and we can't
    /// copy from the host app), then offers the user a choice between
    /// dictionary fix and snippet creation. Both branches reuse the existing
    /// per-action popover presenters.
    func showVoceActionsPicker() {
        guard !isRecording else {
            status = "Finish recording before using Voce actions."
            lastError = status
            return
        }

        Task { @MainActor [weak self] in
            guard let self else { return }
            guard let capture = await self.captureFrontmostSelection() else {
                status = "Select text first, then tap ⌘⌥ for Voce actions."
                lastError = status
                return
            }

            self.menuBar.showVoceActionPicker(
                selection: capture.text,
                sourceAppName: capture.appContext.appName
            ) { [weak self] action in
                guard let self else { return }
                switch action {
                case .dictionaryFix:
                    self.presentDictionaryCorrectionPopover(for: capture)
                case .createSnippet:
                    self.presentSnippetCreationPopover(for: capture)
                }
            }
        }
    }

    /// Hand a captured selection to the dictionary-correction popover. Pulled
    /// out of `captureSelectionForCorrection` so the Voce action picker can
    /// reuse the same flow without re-capturing (the picker has already taken
    /// the selection up-front).
    private func presentDictionaryCorrectionPopover(for capture: SelectionCapture) {
        menuBar.showSelectionCorrection(
            term: capture.text,
            sourceAppName: capture.appContext.appName
        ) { [weak self] replacement in
            Task { @MainActor [weak self] in
                await self?.saveSelectionCorrection(capture: capture, replacement: replacement)
            }
        }
    }

    /// Hand a captured selection to the snippet-creation popover. See
    /// `presentDictionaryCorrectionPopover` for the rationale on the split.
    private func presentSnippetCreationPopover(for capture: SelectionCapture) {
        menuBar.showSelectionSnippet(expansion: capture.text) { [weak self] trigger in
            Task { @MainActor [weak self] in
                await self?.saveSelectionSnippet(capture: capture, trigger: trigger)
            }
        }
    }

    func createCorrectionFromCurrentTranscript() {
        guard !isRecording else {
            status = "Finish recording before creating a dictionary item."
            lastError = status
            return
        }

        let term = currentTranscriptText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else {
            status = "No dictation available yet."
            return
        }

        menuBar.showSelectionCorrection(term: term, sourceAppName: nil) { [weak self] replacement in
            Task { @MainActor [weak self] in
                await self?.saveTranscriptCorrection(term: term, replacement: replacement)
            }
        }
    }

    func createCorrectionForSuppliedTerm(
        _ term: String,
        sourceAppName: String? = nil,
        onSave: ((String) -> Void)? = nil
    ) {
        guard !isRecording else {
            status = "Finish recording before creating a dictionary item."
            lastError = status
            return
        }

        let trimmedTerm = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTerm.isEmpty else {
            status = "No text available yet."
            return
        }

        menuBar.showSelectionCorrection(term: trimmedTerm, sourceAppName: sourceAppName) { [weak self] replacement in
            Task { @MainActor [weak self] in
                await self?.saveTranscriptCorrection(term: trimmedTerm, replacement: replacement)
                onSave?(replacement)
            }
        }
    }

    func createSnippetFromCurrentTranscript() {
        guard !isRecording else {
            status = "Finish recording before creating a shortcut."
            lastError = status
            return
        }

        let expansion = currentTranscriptText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !expansion.isEmpty else {
            status = "No dictation available yet."
            return
        }

        menuBar.showSelectionSnippet(expansion: expansion) { [weak self] trigger in
            Task { @MainActor [weak self] in
                await self?.saveTranscriptSnippet(expansion: expansion, trigger: trigger)
            }
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

    var enabledAIWorkflows: [AIWorkflow] {
        preferences.ai.workflows.filter(\.isEnabled)
    }

    var canRunAIWorkflows: Bool {
        voceProEntitlementStatus.isEntitled && aiRuntimeEnabled
    }

    private func effectiveStyleProfile(for appContext: AppContext) -> StyleProfile {
        if let appProfile = preferences.appStyleProfiles[appContext.bundleIdentifier] {
            return appProfile
        }

        if appContext.isIDE {
            return StyleProfile(
                name: "IDE",
                tone: .technical,
                structureMode: .natural,
                fillerPolicy: .balanced,
                commandPolicy: .passthrough
            )
        }

        if appContext.isRemoteDesktop {
            return StyleProfile(
                name: "Remote Desktop",
                tone: .concise,
                structureMode: .paragraph,
                fillerPolicy: .aggressive,
                commandPolicy: .transform
            )
        }

        return preferences.globalStyleProfile
    }

    private func styleTitle(for mode: StructureMode) -> String {
        switch mode {
        case .natural:
            return "Natural"
        case .paragraph:
            return "Paragraph"
        case .bullets:
            return "Bullets"
        case .email:
            return "Email"
        case .command:
            return "Command"
        }
    }

    var currentPlanTier: VocePlanTier? {
        guard case .entitled(let entitlement) = voceProEntitlementStatus else {
            return nil
        }
        return entitlement.planTier
    }

    var hasCloudDictationEntitlement: Bool {
        hasCloudDictationEntitlement(in: voceProEntitlementStatus)
    }

    var canUseCloudDictation: Bool {
        isDevBuildWithCloudOptions || hasCloudDictationEntitlement
    }

    var canUseCloudRuntime: Bool {
        isDevBuildWithCloudOptions || canUseCloudRuntime(in: voceProEntitlementStatus)
    }

    private func hasCloudDictationEntitlement(in status: VoceProEntitlementStatus) -> Bool {
        guard case .entitled(let entitlement) = status else {
            return false
        }
        return entitlement.hasFeature(.cloudDictation)
    }

    private func canUseCloudRuntime(in status: VoceProEntitlementStatus) -> Bool {
        guard hasCloudDictationEntitlement(in: status) else { return false }
        return hostedCloudRemainingSeconds(in: status) != 0 || canUseDirectCloudOverageFallback
    }

    private func cloudRoutingSignature(for status: VoceProEntitlementStatus) -> String {
        [
            canUseCloudRuntime(in: status) ? "cloud-runtime" : "local-runtime",
            usesDirectCloudCredentials(in: status) ? "direct" : "hosted",
            hostedCloudRemainingSeconds(in: status) == 0 ? "cloud-empty" : "cloud-available",
        ].joined(separator: "|")
    }

    private func hostedCloudRemainingSeconds(in status: VoceProEntitlementStatus) -> Int? {
        guard case .entitled(let entitlement) = status else { return nil }
        return entitlement.cloudRemainingSeconds
    }

    private var hostedCloudRemainingSeconds: Int? {
        hostedCloudRemainingSeconds(in: voceProEntitlementStatus)
    }

    var hostedCloudUsageFraction: Double? {
        guard case .entitled(let entitlement) = voceProEntitlementStatus,
              let used = entitlement.cloudUsedSeconds,
              let limit = entitlement.cloudLimitSeconds,
              limit > 0
        else { return nil }
        return min(max(Double(used) / Double(limit), 0), 1)
    }

    var hostedCloudUsageSummary: String? {
        guard case .entitled(let entitlement) = voceProEntitlementStatus,
              let used = entitlement.cloudUsedSeconds,
              let limit = entitlement.cloudLimitSeconds,
              let remaining = entitlement.cloudRemainingSeconds
        else { return nil }
        return "\(Self.minutesText(for: used)) used of \(Self.minutesText(for: limit)); \(Self.minutesText(for: remaining)) left this month."
    }

    var hostedCloudUsageWarning: String? {
        guard case .entitled(let entitlement) = voceProEntitlementStatus,
              entitlement.hasFeature(.cloudDictation),
              entitlement.cloudRemainingSeconds == 0
        else { return nil }
        if canUseDirectCloudOverageFallback {
            return "Voce Cloud minutes are used. Voce will use your OpenAI key for cloud dictation."
        }
        return "Voce Cloud minutes are used. Voce will use local dictation until next month or until you add an OpenAI key."
    }

    var directOpenAIUsageSummary: String {
        let cloud = preferences.dictation.cloud
        let periodKey = Self.currentUsagePeriodKey()
        let usedSeconds = cloud.directUsagePeriodKey == periodKey ? max(0, cloud.directUsageSeconds) : 0
        let minutes = Double(usedSeconds) / 60
        let estimatedCost = minutes * Self.directOpenAIEstimatedCostPerMinute
        return "\(Self.minutesText(for: usedSeconds)) used this month. Estimated realtime OpenAI cost: \(Self.currencyString(estimatedCost))."
    }

    private var canUseDirectCloudOverageFallback: Bool {
        preferences.dictation.cloud.openAIKeyFallbackEnabled && hasResolvableDirectCloudCredentials
    }

    private var hasResolvableDirectCloudCredentials: Bool {
        !cloudDictationAvailabilityService.directCredentialStatus(for: preferences.dictation).isError
    }

    private func usesDirectCloudCredentials(in status: VoceProEntitlementStatus) -> Bool {
        isDevBuildWithCloudOptions || (hostedCloudRemainingSeconds(in: status) == 0 && canUseDirectCloudOverageFallback)
    }

    private static func minutesText(for seconds: Int) -> String {
        let minutes = max(0, Int(ceil(Double(seconds) / 60)))
        return "\(minutes) \(minutes == 1 ? "minute" : "minutes")"
    }

    private static func currencyString(_ value: Double) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = "USD"
        formatter.maximumFractionDigits = 2
        return formatter.string(from: NSNumber(value: value)) ?? String(format: "$%.2f", value)
    }

    private static func currentUsagePeriodKey(for date: Date = Date()) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
        let components = calendar.dateComponents([.year, .month], from: date)
        let year = components.year ?? 1970
        let month = components.month ?? 1
        return String(format: "%04d-%02d", year, month)
    }

    var cloudDictationStatus: CloudDictationAvailabilityStatus {
        let baseStatus = baseCloudDictationStatus()
        guard !baseStatus.isError else {
            return baseStatus
        }

        let token = cloudValidationToken(for: preferences)
        guard lastCloudValidationToken == token else {
            return baseStatus
        }

        if let lastCloudValidationFailureMessage {
            return CloudDictationAvailabilityStatus(message: lastCloudValidationFailureMessage, isError: true)
        }

        return baseStatus
    }

    var hasStoredCloudAPIKey: Bool {
        CloudProviderCredentialStore.shared.hasStoredOpenAIAPIKey()
    }

    var isDevBuildWithCloudOptions: Bool {
        VoceRuntimeConfiguration.isDevApp
    }

    var usesDirectCloudCredentials: Bool {
        usesDirectCloudCredentials(in: voceProEntitlementStatus)
    }

    var cloudCredentialEnvironmentVariableName: String {
        CloudProviderCredentialStore.shared.environmentVariableDisplayName()
    }

    private func baseCloudDictationStatus() -> CloudDictationAvailabilityStatus {
        if usesDirectCloudCredentials {
            return cloudDictationAvailabilityService.directCredentialStatus(for: preferences.dictation)
        }

        if hasCloudDictationEntitlement,
           hostedCloudRemainingSeconds == 0 {
            if preferences.dictation.cloud.openAIKeyFallbackEnabled {
                return CloudDictationAvailabilityStatus(
                    message: "Voce Cloud minutes are used. Add or fix your OpenAI API key to keep cloud dictation, or use local dictation until next month.",
                    isError: true
                )
            }
            return CloudDictationAvailabilityStatus(
                message: "Voce Cloud minutes are used. Voce will use local dictation until next month.",
                isError: true
            )
        }

        let email = normalizedSubscriberEmail
        guard !email.isEmpty else {
            return CloudDictationAvailabilityStatus(
                message: "Cloud dictation unavailable: verify your email to use cloud dictation.",
                isError: true
            )
        }

        let sessionToken = (try? VoceAccessSessionStore.shared.sessionToken(for: email)) ?? nil
        guard let sessionToken,
              !sessionToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return CloudDictationAvailabilityStatus(
                message: "Cloud dictation unavailable: verify your email to use cloud dictation.",
                isError: true
            )
        }

        if let remaining = hostedCloudRemainingSeconds {
            return CloudDictationAvailabilityStatus(
                message: "Ready. \(Self.minutesText(for: remaining)) of Voce Cloud left this month.",
                isError: false
            )
        }

        return CloudDictationAvailabilityStatus(message: "Ready. Authenticated through your Voce account.", isError: false)
    }

    private func makeCloudSpeechProviderClient(
        for dictation: AppPreferences.Dictation
    ) -> any CloudSpeechProviderClient {
        return CloudSpeechProviderFactory.makeProvider(
            dictation: dictation,
            useDirectCredentials: usesDirectCloudCredentials,
            subscriberEmail: normalizedSubscriberEmail
        )
    }

    private func usesRealtimeWhisperCapture(for appContext: AppContext) -> Bool {
        dictationEngineModeResolver.resolve(for: appContext) == .cloud
    }

    private func requestedDictationMode(for appContext: AppContext) -> DictationEngineMode {
        preferences.appDictationEnginePreferences[appContext.bundleIdentifier]?
            .resolvedMode(globalMode: preferences.dictation.engineMode)
            ?? preferences.dictation.engineMode
    }

    private func cloudRoutingNotice(for appContext: AppContext) -> String? {
        guard requestedDictationMode(for: appContext) == .cloud else { return nil }

        if usesRealtimeWhisperCapture(for: appContext) {
            if usesDirectCloudCredentials, hostedCloudRemainingSeconds == 0 {
                return "Voce Cloud minutes are used. Recording with your OpenAI key."
            }
            return nil
        }

        guard hostedCloudRemainingSeconds == 0 else { return nil }
        return "Voce Cloud minutes are used. Recording locally until next month."
    }

    private func makeRealtimeWhisperCaptureSession(
        onPartialText: @escaping @Sendable (String) -> Void,
        onTerminalError: @escaping @Sendable (Error) -> Void,
        onAudioLevel: @escaping @Sendable (Double) -> Void
    ) throws -> OpenAIRealtimeWhisperCaptureSession {
        let localeIdentifier = preferences.dictation.localeIdentifier
        let transcriptionHints = preferences.visibleLexiconEntries
        let resolvedModel = realtimeWhisperTranscriptionModel
        let authTokenProvider: @Sendable () async throws -> String
        if usesDirectCloudCredentials {
            let apiKeySource = preferences.dictation.cloud.apiKeySource
            authTokenProvider = {
                do {
                    return try CloudProviderCredentialStore.shared.resolveOpenAIAPIKey(
                        source: apiKeySource
                    )
                } catch CloudProviderCredentialStoreError.missingAPIKey {
                    throw CloudDictationError.missingAPIKey
                } catch {
                    throw error
                }
            }
        } else {
            let tokenProvider = VoceRealtimeTranscriptionTokenProvider(
                subscriberEmail: normalizedSubscriberEmail
            )
            let directFallbackEnabled = canUseDirectCloudOverageFallback
            let fallbackAPIKeySource = preferences.dictation.cloud.apiKeySource
            authTokenProvider = {
                do {
                    return try await tokenProvider.clientSecret(
                        localeIdentifier: localeIdentifier,
                        hints: transcriptionHints,
                        model: resolvedModel
                    )
                } catch CloudDictationError.hostedCloudMinutesExhausted where directFallbackEnabled {
                    await MainActor.run {
                        self.activeCloudUsageMetering = .directOpenAI
                        self.activeHostedCloudUsageLimitSeconds = nil
                        self.status = "Voce Cloud minutes are used. Recording with your OpenAI key."
                    }
                    do {
                        return try CloudProviderCredentialStore.shared.resolveOpenAIAPIKey(
                            source: fallbackAPIKeySource
                        )
                    } catch CloudProviderCredentialStoreError.missingAPIKey {
                        throw CloudDictationError.missingAPIKey
                    } catch {
                        throw error
                    }
                }
            }
        }

        return OpenAIRealtimeWhisperCaptureSession(
            authTokenProvider: authTokenProvider,
            model: resolvedModel,
            localeIdentifier: localeIdentifier,
            transcriptionHints: transcriptionHints,
            onPartialText: onPartialText,
            onTerminalError: onTerminalError,
            onAudioLevel: onAudioLevel
        )
    }

    private var realtimeWhisperTranscriptionModel: String {
        let model = ProcessInfo.processInfo.environment["VOCE_OPENAI_REALTIME_TRANSCRIPTION_MODEL"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let model, !model.isEmpty {
            return model
        }
        return "gpt-realtime-whisper"
    }

    private func prefetchRealtimeWhisperClientSecretIfNeeded() {
        guard hasBootstrapped,
              !usesDirectCloudCredentials,
              canUseCloudRuntime,
              hostedCloudRemainingSeconds != 0,
              preferences.usesCloudDictationConfiguration
        else {
            cancelRealtimeWhisperClientSecretWarmup()
            return
        }

        let email = normalizedSubscriberEmail
        guard !email.isEmpty else {
            cancelRealtimeWhisperClientSecretWarmup()
            return
        }

        let localeIdentifier = preferences.dictation.localeIdentifier
        let transcriptionHints = preferences.visibleLexiconEntries
        let model = realtimeWhisperTranscriptionModel
        realtimeWhisperClientSecretPrefetchTask?.cancel()
        realtimeWhisperClientSecretRefreshTask?.cancel()
        realtimeWhisperClientSecretRefreshTask = nil
        realtimeWhisperClientSecretPrefetchTask = Task { [weak self] in
            let secret: RealtimeTranscriptionClientSecret
            do {
                let tokenProvider = VoceRealtimeTranscriptionTokenProvider(
                    subscriberEmail: email
                )
                secret = try await tokenProvider.prefetchClientSecret(
                    localeIdentifier: localeIdentifier,
                    hints: transcriptionHints,
                    model: model
                )
            } catch {
                // Prefetch is opportunistic. Recording startup still reports
                // actionable cloud errors if fetching a token fails there.
                return
            }

            await MainActor.run {
                guard self?.normalizedSubscriberEmail == email else { return }
                self?.realtimeWhisperClientSecretPrefetchTask = nil
                self?.scheduleRealtimeWhisperClientSecretRefresh(
                    expiresAt: secret.expiresAt,
                    email: email,
                    localeIdentifier: localeIdentifier,
                    hints: transcriptionHints,
                    model: model
                )
            }
        }
    }

    private func cancelRealtimeWhisperClientSecretWarmup() {
        realtimeWhisperClientSecretPrefetchTask?.cancel()
        realtimeWhisperClientSecretPrefetchTask = nil
        realtimeWhisperClientSecretRefreshTask?.cancel()
        realtimeWhisperClientSecretRefreshTask = nil
    }

    private func scheduleRealtimeWhisperClientSecretRefresh(
        expiresAt: Int?,
        email: String,
        localeIdentifier: String,
        hints: [LexiconEntry],
        model: String
    ) {
        realtimeWhisperClientSecretRefreshTask?.cancel()
        realtimeWhisperClientSecretRefreshTask = nil

        guard let expiresAt else { return }
        let refreshLeadTime: TimeInterval = 5 * 60
        let refreshAt = Date(timeIntervalSince1970: TimeInterval(expiresAt))
            .addingTimeInterval(-refreshLeadTime)
        let delay = max(refreshAt.timeIntervalSinceNow, 0)

        realtimeWhisperClientSecretRefreshTask = Task { [weak self] in
            if delay > 0 {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
            guard !Task.isCancelled else { return }

            do {
                let tokenProvider = VoceRealtimeTranscriptionTokenProvider(
                    subscriberEmail: email
                )
                _ = try await tokenProvider.prefetchClientSecret(
                    localeIdentifier: localeIdentifier,
                    hints: hints,
                    model: model
                )
            } catch {
                return
            }

            await MainActor.run {
                guard let self,
                      self.normalizedSubscriberEmail == email,
                      self.preferences.dictation.localeIdentifier == localeIdentifier,
                      self.realtimeWhisperTranscriptionModel == model,
                      self.preferences.usesCloudDictationConfiguration,
                      self.canUseCloudRuntime,
                      self.hostedCloudRemainingSeconds != 0,
                      !self.usesDirectCloudCredentials
                else { return }

                self.realtimeWhisperClientSecretRefreshTask = nil
                self.prefetchRealtimeWhisperClientSecretIfNeeded()
            }
        }
    }

    func saveCloudAPIKey(_ apiKey: String) throws {
        try CloudProviderCredentialStore.shared.saveOpenAIAPIKey(apiKey)
        cloudValidationCredentialVersion = UUID()
        lastCloudValidationToken = nil
        lastCloudValidationFailureMessage = nil
        refreshCloudValidationIfNeeded(force: true)
        Task { @MainActor [weak self] in
            await self?.rebuildRuntimeOrDefer(announceImmediateSave: false)
        }
    }

    func clearCloudAPIKey() throws {
        try CloudProviderCredentialStore.shared.clearOpenAIAPIKey()
        cloudValidationTask?.cancel()
        cloudValidationTask = nil
        cloudValidationCredentialVersion = UUID()
        lastCloudValidationToken = nil
        lastCloudValidationFailureMessage = nil
        Task { @MainActor [weak self] in
            await self?.rebuildRuntimeOrDefer(announceImmediateSave: false)
        }
    }

    func runCloudDictationTest() async throws -> String {
        guard canUseCloudDictation else {
            throw CloudDictationError.providerError("Cloud dictation is part of Voce Pro.")
        }
        try await runCloudValidation(dictation: preferences.dictation)
        return "Cloud dictation is ready."
    }

    func runAIWorkflow(_ workflow: AIWorkflow, on entry: TranscriptEntry) {
        guard !isRecording else {
            status = "Finish recording before running AI on history."
            return
        }
        guard voceProEntitlementStatus.isEntitled else {
            status = "Verify your email to use AI workflows."
            lastError = voceProEntitlementStatus.message
            return
        }
        guard aiRuntimeEnabled else {
            status = "AI is not available right now."
            lastError = appleIntelligenceAvailabilityText
            return
        }

        let inputText = historyAIInput(for: entry)
        guard !inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            status = "No transcript text to send to AI."
            return
        }

        historyAIProcessingEntryID = entry.id
        status = aiGenerationStatusMessage(for: workflow.name)
        lastError = ""

        Task { @MainActor [weak self] in
            guard let self else { return }

            do {
                let result = try await self.aiGenerationService.generate(workflow: workflow, input: inputText)
                try await self.clipboardService.setString(result.outputText)
                try await self.updateHistoryEntryWithAIResult(
                    sourceEntry: entry,
                    inputText: inputText,
                    result: result,
                    workflow: workflow
                )
                await self.refreshHistory()
                self.lastTranscript = result.outputText
                self.status = "\(workflow.name) copied and updated."
            } catch let error as AIWorkflowError {
                self.status = error.errorDescription ?? "AI request failed."
                self.lastError = self.status
            } catch {
                self.status = "AI request failed."
                self.lastError = error.localizedDescription
            }

            if self.historyAIProcessingEntryID == entry.id {
                self.historyAIProcessingEntryID = nil
            }
        }
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
        activeStyleOverride = nil
        activeCloudUsageMetering = nil
        activeFreeUsageLimitSeconds = voceProEntitlementStatus.freeRecordingRemainingSeconds
        activeHostedCloudUsageLimitSeconds = nil
        overlay.selectedControlStyle = effectiveStyleProfile(for: capturedContext).structureMode

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

        let startTaskID = UUID()
        activeStartTaskID = startTaskID
        captureReadyOverlayStartTaskID = nil
        activeStartTask = Task { @MainActor in
            do {
                try await ensureMicrophonePermission()
                try await validateEngineReadinessForRecording(appContext: capturedContext)

                status = "Arming microphone..."
                // Show the bubble immediately with a spinner. The first real
                // mic callback switches it to the listening glyph, even if the
                // realtime websocket is still arming.
                overlay.setAnchorSnapshot(overlayAnchorSnapshot)
                overlay.controlWorkflows = enabledAIWorkflows
                overlay.show(state: .preparing(handsFree: mode == .handsFree))

                if usesRealtimeWhisperCapture(for: capturedContext) {
                    activeCloudUsageMetering = usesDirectCloudCredentials ? .directOpenAI : .voceHosted
                    if activeCloudUsageMetering == .voceHosted,
                       let remaining = hostedCloudRemainingSeconds,
                       remaining > 0 {
                        activeHostedCloudUsageLimitSeconds = TimeInterval(remaining)
                    }
                    let session = try makeRealtimeWhisperCaptureSession(
                        onPartialText: { [weak self, weak overlay] text in
                            Task { @MainActor [weak self, weak overlay] in
                                guard self?.shouldDisplayStreamingCaptureFeedback(for: mode) == true else { return }
                                overlay?.show(state: .liveTranscript(text: text, handsFree: mode == .handsFree))
                            }
                        },
                        onTerminalError: { [weak self] error in
                            Task { @MainActor [weak self] in
                                self?.handleStreamingFailure(error)
                            }
                        },
                        onAudioLevel: { [weak self, weak overlay] level in
                            Task { @MainActor [weak self, weak overlay] in
                                guard overlay != nil else { return }
                                self?.displayCaptureReadyFeedbackIfNeeded(
                                    for: mode,
                                    startTaskID: startTaskID,
                                    level: level
                                )
                            }
                        }
                    )
                    activeRealtimeWhisperSession = session
                    try await session.start()
                } else {
                    activeCloudUsageMetering = nil
                    activeHostedCloudUsageLimitSeconds = nil
                    let session = AppleSpeechPreviewSession(
                        localeIdentifier: preferences.dictation.localeIdentifier,
                        previewTranscriptionEnabled: false,
                        onPartialText: { _ in },
                        onTerminalError: { [weak self] error in
                            Task { @MainActor [weak self] in
                                self?.handleStreamingFailure(error)
                            }
                        },
                        onAudioLevel: { [weak self, weak overlay] level in
                            Task { @MainActor [weak self, weak overlay] in
                                guard overlay != nil else { return }
                                self?.displayCaptureReadyFeedbackIfNeeded(
                                    for: mode,
                                    startTaskID: startTaskID,
                                    level: level
                                )
                            }
                        }
                    )
                    activePreviewSession = session
                    try await session.start()
                }

                let sessionID = await coordinator.registerStreamingSession(appContext: capturedContext)
                await coordinator.setHandsFreeEnabled(mode == .handsFree)
                currentSessionID = sessionID

                status = cloudRoutingNotice(for: capturedContext)
                    ?? (mode == .handsFree ? "Hands-free listening..." : "Recording...")
                isRecording = true
                handsFreeOn = mode == .handsFree
                menuBar.updateIcon(isRecording: true, handsFreeOn: mode == .handsFree)
                activeRecordingMode = mode
                updateActiveRecordingHotkeys()
                recordingElapsed = 0
                recordingTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                    Task { @MainActor [weak self] in
                        self?.recordingElapsed += 1
                        self?.stopIfFreeUsageLimitReached()
                        self?.stopIfHostedCloudUsageLimitReached()
                    }
                }
                if captureReadyOverlayStartTaskID != startTaskID {
                    overlay.show(state: .listening(handsFree: mode == .handsFree, elapsedSeconds: 0))
                    captureReadyOverlayStartTaskID = startTaskID
                }

                if shouldPauseMedia {
                    let mediaToken = await mediaInterruption.beginInterruption()
                    if currentSessionID == sessionID, isRecording {
                        activeMediaToken = mediaToken
                    } else if let mediaToken {
                        mediaInterruption.endInterruption(token: mediaToken)
                    }
                }
            } catch {
                if let token = activeMediaToken {
                    mediaInterruption.endInterruption(token: token)
                    activeMediaToken = nil
                }
                self.recordingTimer?.invalidate()
                self.recordingTimer = nil
                self.recordingElapsed = 0
                captureReadyOverlayStartTaskID = nil
                isRecording = false
                handsFreeOn = false
                menuBar.updateIcon(isRecording: false, handsFreeOn: false)
                activeRecordingMode = nil
                activeAppContext = nil
                activeFreeUsageLimitSeconds = nil
                activeHostedCloudUsageLimitSeconds = nil
                overlayPersistenceBundleIdentifier = nil
                pendingCompletionActionOverride = nil
                activeStyleOverride = nil
                updateActiveRecordingHotkeys()
                activePreviewSession = nil
                activeRealtimeWhisperSession = nil
                activeCloudUsageMetering = nil
                recordingStateMachine.markTranscriptionFailed()
                status = "Failed to start"
                lastError = error.localizedDescription
                overlay.hide()
                clipboardRecoveryPrompt.hide()
            }
            if activeStartTaskID == startTaskID {
                activeStartTask = nil
                activeStartTaskID = nil
            }
        }
    }

    private func shouldDisplayStreamingCaptureFeedback(for mode: RecordingMode) -> Bool {
        isRecording && activeRecordingMode == mode
    }

    private func displayCaptureReadyFeedbackIfNeeded(
        for mode: RecordingMode,
        startTaskID: UUID,
        level: Double
    ) {
        let startIsStillArming = activeStartTaskID == startTaskID
            && (activePreviewSession != nil || activeRealtimeWhisperSession != nil)
        let recordingIsActive = shouldDisplayStreamingCaptureFeedback(for: mode)
        guard startIsStillArming || recordingIsActive else { return }

        if captureReadyOverlayStartTaskID != startTaskID {
            captureReadyOverlayStartTaskID = startTaskID
            overlay.show(state: .listening(handsFree: mode == .handsFree, elapsedSeconds: 0))
        }
        overlay.updateAudioLevel(level)
    }

    private func handleStreamingFailure(_ error: Error) {
        let previewSession = activePreviewSession
        let realtimeSession = activeRealtimeWhisperSession
        guard previewSession != nil || realtimeSession != nil else { return }

        let pendingStart = activeStartTask
        activeStartTask = nil
        activeStartTaskID = nil
        activePreviewSession = nil
        activeRealtimeWhisperSession = nil
        activeCloudUsageMetering = nil

        recordingTimer?.invalidate()
        recordingTimer = nil
        captureReadyOverlayStartTaskID = nil
        recordingElapsed = 0
        isRecording = false
        handsFreeOn = false
        menuBar.updateIcon(isRecording: false, handsFreeOn: false)
        activeRecordingMode = nil
        activeFreeUsageLimitSeconds = nil
        activeHostedCloudUsageLimitSeconds = nil
        updateActiveRecordingHotkeys()

        Task {
            await pendingStart?.value

            previewSession?.cancel()
            realtimeSession?.cancel()

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
            activeStyleOverride = nil

            recordingStateMachine.markTranscriptionFailed()
            status = streamingFailureStatusMessage(for: error)
            lastError = error.localizedDescription
            overlay.hide()
            clipboardRecoveryPrompt.hide()
            await applyDeferredRebuildIfNeeded()
        }
    }

    private func stopSession(mode: RecordingMode) {
        recordStopForResidualStartSuppression(mode: mode)
        let pendingStart = activeStartTask
        activeStartTask = nil
        activeStartTaskID = nil

        // Capture streaming session before clearing state.
        let previewSession = activePreviewSession
        activePreviewSession = nil
        let realtimeSession = activeRealtimeWhisperSession
        activeRealtimeWhisperSession = nil
        let cloudUsageMetering = activeCloudUsageMetering
        activeCloudUsageMetering = nil
        let recordedSeconds = recordingElapsed
        // Shared cleanup — runs on every path including the guard-return.
        recordingTimer?.invalidate()
        recordingTimer = nil
        captureReadyOverlayStartTaskID = nil
        accumulateRecordingSeconds(recordedSeconds)
        recordVoceUsageSeconds(recordedSeconds)
        recordingElapsed = 0
        isRecording = false
        handsFreeOn = false
        menuBar.updateIcon(isRecording: false, handsFreeOn: false)
        activeRecordingMode = nil
        activeFreeUsageLimitSeconds = nil
        activeHostedCloudUsageLimitSeconds = nil
        updateActiveRecordingHotkeys()

        let readyCoordinator = coordinator
        let readySessionID = currentSessionID
        let readyPreferredCompletionAction = pendingCompletionActionOverride
        let readyStyleOverride = activeStyleOverride
        let readyMediaToken = activeMediaToken

        if readySessionID != nil {
            currentSessionID = nil
            activeAppContext = nil
            pendingCompletionActionOverride = nil
            activeStyleOverride = nil
            activeMediaToken = nil
            recordingStateMachine.markTranscriptionCompleted()
            startPendingRecordingAfterAudioSecuredIfNeeded()
        }

        Task {
            var isBackgroundProcessing = false
            var processingSequence: Int?
            defer {
                if isBackgroundProcessing {
                    if let processingSequence {
                        finishCompletionTurn(sequence: processingSequence)
                    }
                    finishBackgroundProcessingSession()
                }
            }

            let coordinator: SessionCoordinator?
            let sessionID: SessionID?
            let preferredCompletionAction: CompletionAction?
            let styleOverride: StyleProfile?
            let mediaToken: MediaInterruptionToken?

            if let readyCoordinator, let readySessionID {
                coordinator = readyCoordinator
                sessionID = readySessionID
                preferredCompletionAction = readyPreferredCompletionAction
                styleOverride = readyStyleOverride
                mediaToken = readyMediaToken
            } else {
                // If stop happens while the microphone is still arming, wait
                // only until setup either publishes a session ID or fails.
                await pendingStart?.value
                coordinator = self.coordinator
                sessionID = currentSessionID
                preferredCompletionAction = pendingCompletionActionOverride
                styleOverride = activeStyleOverride
                mediaToken = activeMediaToken

                currentSessionID = nil
                activeAppContext = nil
                pendingCompletionActionOverride = nil
                activeStyleOverride = nil
                activeMediaToken = nil
                recordingStateMachine.markTranscriptionCompleted()
                startPendingRecordingAfterAudioSecuredIfNeeded()
            }

            guard let coordinator, let sessionID else {
                previewSession?.cancel()
                realtimeSession?.cancel()
                recordingStateMachine.markTranscriptionFailed()
                status = "No active recording session."
                return
            }
            beginBackgroundProcessingSession()
            isBackgroundProcessing = true
            processingSequence = allocateBackgroundProcessingSequence()

            if !isRecording, activeStartTask == nil {
                status = "Finalising..."
                lastError = ""
                overlay.show(state: .transcribing)
            }

            if let mediaToken {
                mediaInterruption.endInterruption(token: mediaToken)
            }

            var captureDurationMS = 0
            do {
                let clock = ContinuousClock()
                let stopBeganAt = clock.now
                let finalizedTranscript: FinalizedTranscript
                let skipsCleanupForAIWorkflow: Bool
                if case .aiWorkflow = preferredCompletionAction {
                    skipsCleanupForAIWorkflow = true
                } else {
                    skipsCleanupForAIWorkflow = false
                }

                if let realtimeSession {
                    let stopResult = try await realtimeSession.stop()
                    defer { try? FileManager.default.removeItem(at: stopResult.captureURL) }
                    captureDurationMS = stopResult.rawTranscript.durationMS
                    recordDictationAuditUsage(
                        mode: cloudUsageMetering,
                        seconds: TimeInterval(captureDurationMS) / 1_000
                    )
                    let stopElapsed = stopBeganAt.duration(to: clock.now)
                    let stopElapsedSeconds = Double(stopElapsed.components.seconds)
                        + Double(stopElapsed.components.attoseconds) / 1_000_000_000_000_000_000
                    Self.logger.notice(
                        "Realtime Whisper stop completed in \(stopElapsedSeconds, format: .fixed(precision: 2))s; captured \(captureDurationMS)ms"
                    )

                    let transcriptionBeganAt = clock.now
                    finalizedTranscript = try await coordinator.processStreamingTranscript(
                        stopResult.rawTranscript,
                        sessionID: sessionID,
                        processingNote: "Realtime Whisper",
                        styleOverride: styleOverride,
                        skipsCleanup: skipsCleanupForAIWorkflow
                    )
                    let transcriptionElapsed = transcriptionBeganAt.duration(to: clock.now)
                    let transcriptionElapsedSeconds = Double(transcriptionElapsed.components.seconds)
                        + Double(transcriptionElapsed.components.attoseconds) / 1_000_000_000_000_000_000
                    Self.logger.notice(
                        "Coordinator finalized realtime transcript in \(transcriptionElapsedSeconds, format: .fixed(precision: 2))s"
                    )
                } else if let previewSession {
                    let stopResult = try previewSession.stop()
                    captureDurationMS = stopResult.captureDurationMS
                    recordDictationAuditUsage(
                        mode: nil,
                        seconds: TimeInterval(captureDurationMS) / 1_000
                    )
                    let stopElapsed = stopBeganAt.duration(to: clock.now)
                    let stopElapsedSeconds = Double(stopElapsed.components.seconds)
                        + Double(stopElapsed.components.attoseconds) / 1_000_000_000_000_000_000
                    Self.logger.notice(
                        "Preview stop completed in \(stopElapsedSeconds, format: .fixed(precision: 2))s; captured \(captureDurationMS)ms"
                    )

                    let transcriptionBeganAt = clock.now
                    finalizedTranscript = try await coordinator.processStreamingAudio(
                        audioURL: stopResult.captureURL,
                        sessionID: sessionID,
                        languageHints: [preferences.dictation.localeIdentifier],
                        styleOverride: styleOverride,
                        skipsCleanup: skipsCleanupForAIWorkflow
                    )
                    let transcriptionElapsed = transcriptionBeganAt.duration(to: clock.now)
                    let transcriptionElapsedSeconds = Double(transcriptionElapsed.components.seconds)
                        + Double(transcriptionElapsed.components.attoseconds) / 1_000_000_000_000_000_000
                    Self.logger.notice(
                        "Coordinator finalized transcript in \(transcriptionElapsedSeconds, format: .fixed(precision: 2))s"
                    )
                } else {
                    throw AppleSpeechPreviewError.missingOutputFile
                }

                if let processingSequence {
                    await waitForCompletionTurn(sequence: processingSequence)
                }

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
                } else if shouldPolishPlainDictation(routedCompletion) {
                    status = "Polishing…"
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
                        workflows: preferences.ai.workflows,
                        dictationPolishingEnabled: shouldPolishPlainDictation(routedCompletion)
                    )
                    let executionElapsed = executionBeganAt.duration(to: clock.now)
                    let executionElapsedSeconds = Double(executionElapsed.components.seconds)
                        + Double(executionElapsed.components.attoseconds) / 1_000_000_000_000_000_000
                    Self.logger.notice(
                        "Completion execution finished in \(executionElapsedSeconds, format: .fixed(precision: 2))s"
                    )

                    lastTranscript = execution.finalText
                    let shouldPreserveActiveRecordingStatus = isRecording
                    applyExecutionOutcomeStatus(
                        execution,
                        targetAppContext: finalizedTranscript.appContext
                    )
                    if shouldPreserveActiveRecordingStatus {
                        restoreActiveRecordingStatus()
                    }
                    do {
                        try await appendHistoryEntry(
                            finalizedTranscript: finalizedTranscript,
                            execution: execution
                        )
                    } catch {
                        lastError = error.localizedDescription
                    }
                    scheduleLearningUpdate(for: finalizedTranscript)
                    let insertedSuccessfully = execution.insertResult.status == .inserted
                    let insertedIntoVoce = finalizedTranscript.appContext.bundleIdentifier == Bundle.main.bundleIdentifier
                    if !isRecording {
                        dismissOverlaySoon(
                            pop: insertedSuccessfully || insertedIntoVoce,
                            delayNanoseconds: (insertedSuccessfully || insertedIntoVoce) ? 0 : 1_500_000_000
                        )
                    }
                } catch let aiError as AIWorkflowError {
                    lastTranscript = finalizedTranscript.cleanText
                    if isRecording {
                        restoreActiveRecordingStatus()
                    } else {
                        status = aiError.errorDescription ?? "AI request failed."
                        lastError = aiError.errorDescription ?? ""
                        overlay.hide()
                        clipboardRecoveryPrompt.hide()
                    }
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
                    if !isRecording {
                        dismissOverlaySoon()
                    }
                } catch let routingError as CompletionRoutingError {
                    lastTranscript = finalizedTranscript.cleanText
                    if isRecording {
                        restoreActiveRecordingStatus()
                    } else {
                        status = routingErrorStatusMessage(for: routingError)
                        lastError = ""
                        overlay.hide()
                        clipboardRecoveryPrompt.hide()
                    }
                    scheduleLearningUpdate(for: finalizedTranscript)
                    if !isRecording {
                        dismissOverlaySoon()
                    }
                }
                await refreshHistory()
                await applyDeferredRebuildIfNeeded()
            } catch {
                if shouldSuppressEmptyTranscriptError(error, captureDurationMS: captureDurationMS) {
                    handleShortSilentCapture()
                    await applyDeferredRebuildIfNeeded()
                    return
                }
                if preferences.usesCloudDictationConfiguration {
                    refreshCloudValidationIfNeeded(force: true)
                }
                Self.logger.error(
                    "Streaming transcription failed after \(captureDurationMS, privacy: .public)ms capture: \(error.localizedDescription, privacy: .public)"
                )
                if isBackgroundProcessing, isRecording {
                    restoreActiveRecordingStatus()
                } else {
                    status = "Transcription failed"
                    lastError = error.localizedDescription
                    overlay.hide()
                    clipboardRecoveryPrompt.hide()
                    recordingStateMachine.markTranscriptionFailed()
                }
                await applyDeferredRebuildIfNeeded()
            }
        }
    }

    private func beginBackgroundProcessingSession() {
        backgroundProcessingSessionCount += 1
    }

    private func finishBackgroundProcessingSession() {
        backgroundProcessingSessionCount = max(0, backgroundProcessingSessionCount - 1)
    }

    private func queueStartAfterAudioSecuredIfNeeded(mode: RecordingMode) -> Bool {
        guard recordingStateMachine.state == .transcribing else {
            return false
        }

        guard !isRecording else {
            return false
        }

        guard !shouldIgnoreResidualStartSignal(mode: mode) else {
            return true
        }

        pendingStartAfterAudioSecured = mode
        status = "Starting next dictation..."
        lastError = ""
        return true
    }

    private func recordStopForResidualStartSuppression(mode: RecordingMode) {
        lastRecordingStopTime = CFAbsoluteTimeGetCurrent()
        lastRecordingStopMode = mode
    }

    private func shouldIgnoreResidualStartSignal(mode: RecordingMode) -> Bool {
        guard lastRecordingStopMode == mode else { return false }

        let elapsed = CFAbsoluteTimeGetCurrent() - lastRecordingStopTime
        return elapsed >= 0 && elapsed < 0.45
    }

    private func startPendingRecordingAfterAudioSecuredIfNeeded() {
        guard let mode = pendingStartAfterAudioSecured else { return }
        pendingStartAfterAudioSecured = nil

        guard recordingStateMachine.state == .idle else { return }
        guard canStartRecordingNow() else { return }

        switch mode {
        case .pressToTalk:
            suppressNextPressToTalkStop = false
            apply(transition: recordingStateMachine.handlePressToTalkKeyDown())
        case .handsFree:
            apply(transition: recordingStateMachine.handleHandsFreeToggle())
        }
    }

    private func allocateBackgroundProcessingSequence() -> Int {
        let sequence = nextBackgroundProcessingSequence
        nextBackgroundProcessingSequence += 1
        return sequence
    }

    private func waitForCompletionTurn(sequence: Int) async {
        guard sequence > nextCompletionSequenceToCommit else { return }

        await withCheckedContinuation { continuation in
            completionSequenceWaiters[sequence] = continuation
        }
    }

    private func finishCompletionTurn(sequence: Int) {
        guard sequence >= nextCompletionSequenceToCommit else { return }

        completedCompletionSequences.insert(sequence)

        while completedCompletionSequences.remove(nextCompletionSequenceToCommit) != nil {
            nextCompletionSequenceToCommit += 1
            completionSequenceWaiters.removeValue(forKey: nextCompletionSequenceToCommit)?.resume()
        }
    }

    private func restoreActiveRecordingStatus() {
        guard isRecording else { return }

        switch activeRecordingMode {
        case .handsFree:
            status = "Hands-free listening..."
        case .pressToTalk:
            status = "Recording..."
        case nil:
            break
        }
        lastError = ""
    }

    private func dismissOverlaySoon(pop: Bool = false, delayNanoseconds: UInt64 = 1_500_000_000) {
        overlayDismissTask?.cancel()

        guard delayNanoseconds > 0 else {
            if pop {
                overlay.popAndHide()
            } else {
                overlay.hide()
            }
            overlayPersistenceBundleIdentifier = nil
            overlayDismissTask = nil
            return
        }

        overlayDismissTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: delayNanoseconds)
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

    private func captureFrontmostSelection() async -> SelectionCapture? {
        let appContext = AppContextProvider.current()
        var selectedText = accessibilitySelectedText()
        if selectedText == nil {
            selectedText = await copySelectedTextWithTemporaryPasteboard()
        }
        let trimmed = selectedText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else { return nil }
        return SelectionCapture(text: trimmed, appContext: appContext)
    }

    private func saveSelectionCorrection(capture: SelectionCapture, replacement: String) async {
        let trimmedReplacement = replacement.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedReplacement.isEmpty else { return }

        let entry = LexiconEntry(term: capture.text, preferred: trimmedReplacement, scope: .global)
        if let existingIndex = preferences.lexiconEntries.firstIndex(where: {
            $0.term.caseInsensitiveCompare(entry.term) == .orderedSame && $0.scope == entry.scope
        }) {
            preferences.lexiconEntries[existingIndex] = entry
        } else {
            preferences.lexiconEntries.append(entry)
        }
        await lexiconService.upsert(term: entry.term, preferred: entry.preferred, scope: entry.scope)
        savePreferences()

        let result = await insertionService.insert(text: trimmedReplacement, target: capture.appContext)
        switch result.status {
        case .inserted:
            status = "Dictionary quick fix saved and replaced."
            lastError = ""
        case .copiedOnly:
            status = "Dictionary quick fix saved. Replacement copied to clipboard."
            lastError = result.errorMessage ?? ""
        case .failed:
            status = "Dictionary quick fix saved, but replacement failed."
            lastError = result.errorMessage ?? ""
        }
    }

    private func saveSelectionSnippet(capture: SelectionCapture, trigger: String) async {
        let trimmedTrigger = trigger.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTrigger.isEmpty else { return }

        let snippet = Snippet(trigger: trimmedTrigger, expansion: capture.text, scope: .global)
        if let existingIndex = preferences.snippets.firstIndex(where: {
            $0.trigger.caseInsensitiveCompare(snippet.trigger) == .orderedSame && $0.scope == snippet.scope
        }) {
            preferences.snippets[existingIndex] = snippet
        } else {
            preferences.snippets.append(snippet)
        }
        await snippetService.upsert(snippet)
        savePreferences()
        status = "Shortcut saved for \"\(capture.text)\"."
        lastError = ""
    }

    private func saveTranscriptCorrection(term: String, replacement: String) async {
        let trimmedTerm = term.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedReplacement = replacement.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTerm.isEmpty, !trimmedReplacement.isEmpty else { return }

        let entry = LexiconEntry(term: trimmedTerm, preferred: trimmedReplacement, scope: .global)
        if let existingIndex = preferences.lexiconEntries.firstIndex(where: {
            $0.term.caseInsensitiveCompare(entry.term) == .orderedSame && $0.scope == entry.scope
        }) {
            preferences.lexiconEntries[existingIndex] = entry
        } else {
            preferences.lexiconEntries.append(entry)
        }
        await lexiconService.upsert(term: entry.term, preferred: entry.preferred, scope: entry.scope)
        savePreferences()
        status = "Dictionary item saved for \"\(trimmedTerm)\"."
        lastError = ""
    }

    private func saveTranscriptSnippet(expansion: String, trigger: String) async {
        let trimmedExpansion = expansion.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedTrigger = trigger.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedExpansion.isEmpty, !trimmedTrigger.isEmpty else { return }

        let snippet = Snippet(trigger: trimmedTrigger, expansion: trimmedExpansion, scope: .global)
        if let existingIndex = preferences.snippets.firstIndex(where: {
            $0.trigger.caseInsensitiveCompare(snippet.trigger) == .orderedSame && $0.scope == snippet.scope
        }) {
            preferences.snippets[existingIndex] = snippet
        } else {
            preferences.snippets.append(snippet)
        }
        await snippetService.upsert(snippet)
        savePreferences()
        status = "Shortcut saved for \"\(trimmedExpansion)\"."
        lastError = ""
    }

    private func accessibilitySelectedText() -> String? {
        guard AXIsProcessTrusted() else { return nil }

        let systemWide = AXUIElementCreateSystemWide()
        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            systemWide,
            kAXFocusedUIElementAttribute as CFString,
            &focusedRef
        ) == .success,
        let focusedRef,
        CFGetTypeID(focusedRef) == AXUIElementGetTypeID() else {
            return nil
        }

        let element = unsafeDowncast(focusedRef as AnyObject, to: AXUIElement.self)
        if let selected = selectedTextAttribute(from: element) {
            return selected
        }
        return selectedTextFromValueAndRange(element: element)
    }

    private func selectedTextAttribute(from element: AXUIElement) -> String? {
        var selectedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXSelectedTextAttribute as CFString,
            &selectedRef
        ) == .success else {
            return nil
        }
        return selectedRef as? String
    }

    private func selectedTextFromValueAndRange(element: AXUIElement) -> String? {
        var valueRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXValueAttribute as CFString,
            &valueRef
        ) == .success,
        let value = valueRef as? String else {
            return nil
        }

        var selectedRangeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXSelectedTextRangeAttribute as CFString,
            &selectedRangeRef
        ) == .success,
        let selectedRangeRef,
        CFGetTypeID(selectedRangeRef) == AXValueGetTypeID() else {
            return nil
        }

        let selectedRangeValue = unsafeDowncast(selectedRangeRef as AnyObject, to: AXValue.self)
        guard AXValueGetType(selectedRangeValue) == .cfRange else { return nil }

        var selectedRange = CFRange()
        guard AXValueGetValue(selectedRangeValue, .cfRange, &selectedRange),
              selectedRange.length > 0,
              let range = stringRange(from: selectedRange, in: value) else {
            return nil
        }
        return String(value[range])
    }

    private func copySelectedTextWithTemporaryPasteboard() async -> String? {
        let pasteboard = NSPasteboard.general
        let snapshot = PasteboardSnapshot(pasteboard: pasteboard)

        pasteboard.clearContents()
        guard simulateCommandC() else {
            snapshot.restore(to: pasteboard)
            return nil
        }

        try? await Task.sleep(nanoseconds: 160_000_000)
        let copied = pasteboard.string(forType: .string)
        snapshot.restore(to: pasteboard)
        return copied
    }

    private func simulateCommandC() -> Bool {
        guard let source = CGEventSource(stateID: .combinedSessionState),
              let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 8, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 8, keyDown: false) else {
            return false
        }

        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        keyDown.post(tap: .cgAnnotatedSessionEventTap)
        keyUp.post(tap: .cgAnnotatedSessionEventTap)
        return true
    }

    private func stringRange(from cfRange: CFRange, in text: String) -> Range<String.Index>? {
        guard cfRange.location >= 0, cfRange.length >= 0 else { return nil }
        guard let startUTF16 = text.utf16.index(
            text.utf16.startIndex,
            offsetBy: cfRange.location,
            limitedBy: text.utf16.endIndex
        ),
        let endUTF16 = text.utf16.index(
            startUTF16,
            offsetBy: cfRange.length,
            limitedBy: text.utf16.endIndex
        ),
        let start = String.Index(startUTF16, within: text),
        let end = String.Index(endUTF16, within: text) else {
            return nil
        }
        return start..<end
    }

    private func applyPreferencesLocally(_ newValue: AppPreferences) {
        let previousCloudToken = cloudValidationToken(for: preferences)
        preferences = newValue
        hotkey.isOptionPressToTalkEnabled = newValue.hotkeys.optionPressToTalkEnabled
        hotkey.pressToTalkHotkey = newValue.hotkeys.pressToTalkHotkey
        hotkey.globalToggleHotkey = newValue.hotkeys.handsFreeGlobalHotkey
        hotkey.selectionCorrectionHotkey = newValue.hotkeys.dictionaryCorrectionHotkey
        hotkey.selectionSnippetHotkey = newValue.hotkeys.snippetCreationHotkey
        hotkey.isVoceActionsTapEnabled = newValue.hotkeys.voceActionsTapEnabled
        hotkey.aiFinishHotkey = newValue.ai.handsFreeFinishHotkey
        hotkey.aiWorkflowFinishHotkeys = newValue.ai.workflows.compactMap(\.handsFreeFinishHotkey)
        overlay.controlWorkflows = enabledAIWorkflows
        overlay.bubbleAppearance = newValue.general.bubbleAppearance
        updateActiveRecordingHotkeys()
        applyDockVisibility(showDockIcon: newValue.general.showDockIcon)

        switch newValue.general.appearancePreference {
        case .dark:
            overlay.prefersDarkAppearance = true
        case .light:
            overlay.prefersDarkAppearance = false
        case .system:
            overlay.prefersDarkAppearance = nil
        }

        let newCloudToken = cloudValidationToken(for: newValue)
        if previousCloudToken != newCloudToken {
            lastCloudValidationToken = nil
            lastCloudValidationFailureMessage = nil
        }
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
            wordFrequencies: wordFreqs,
            cloudRuntimeAllowed: canUseCloudRuntime,
            subscriberEmail: normalizedSubscriberEmail,
            useDirectCloudCredentials: usesDirectCloudCredentials
        )
        lexiconService = runtimeFactory.makeLexiconService()
        styleProfileService = runtimeFactory.makeStyleProfileService()
        snippetService = runtimeFactory.makeSnippetService()
        voiceCommandService = runtimeFactory.makeVoiceCommandService()
        dictationEngineModeResolver = runtimeFactory.makeEngineModeResolver()

        let insertion = InsertionService(transports: runtimeFactory.makeInsertionTransports())
        insertionService = insertion

        coordinator = SessionCoordinator(
            captureService: captureService,
            engineResolver: runtimeFactory.makeSessionEngineResolver(),
            lexiconService: lexiconService,
            styleProfileService: styleProfileService,
            snippetService: snippetService,
            voiceCommandService: voiceCommandService,
            learningEngine: learningEngine
        )

        do {
            try launchAtLoginService.setEnabled(snapshot.general.launchAtLoginEnabled)
            launchAtLoginWarning = ""
        } catch {
            launchAtLoginWarning = error.localizedDescription
        }

        status = runtimeFactory.runtimeStatusText()
        refreshCloudValidationIfNeeded(force: false)
        prefetchRealtimeWhisperClientSecretIfNeeded()
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

    private var normalizedSubscriberEmail: String {
        preferences.billing.subscriberEmail
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    private var canUseDictationPolish: Bool {
        voceProEntitlementStatus.isEntitled
    }

    private func canStartRecordingNow() -> Bool {
        switch voceProEntitlementStatus {
        case .entitled:
            return true
        case .missingEmail:
            status = "Enter your email in Settings to start Voce."
            lastError = status
            return false
        case .needsVerification:
            status = "Verify your email to start Voce."
            lastError = status
            return false
        case .checking:
            status = "Checking Voce access..."
            return false
        case .notEntitled:
            status = "Monthly free time is used. Subscribe to keep using Voce."
            lastError = status
            return false
        case .failed:
            status = "Could not check Voce access."
            lastError = voceProEntitlementStatus.message
            scheduleVoceProEntitlementRefresh(immediate: true)
            return false
        }
    }

    private func stopIfFreeUsageLimitReached() {
        guard let activeFreeUsageLimitSeconds,
              activeFreeUsageLimitSeconds > 0,
              recordingElapsed >= activeFreeUsageLimitSeconds,
              isRecording
        else {
            return
        }

        status = "Monthly free time reached."
        stopActiveRecording()
    }

    private func stopIfHostedCloudUsageLimitReached() {
        guard let activeHostedCloudUsageLimitSeconds,
              activeHostedCloudUsageLimitSeconds > 0,
              recordingElapsed >= activeHostedCloudUsageLimitSeconds,
              isRecording
        else {
            return
        }

        status = "Voce Cloud monthly minutes reached."
        stopActiveRecording()
    }

    private func scheduleVoceProEntitlementRefreshIfNeeded(previousEmail: String) {
        if previousEmail != normalizedSubscriberEmail {
            scheduleVoceProEntitlementRefresh(immediate: false)
        }
    }

    private func scheduleVoceProEntitlementRefresh(immediate: Bool) {
        let email = normalizedSubscriberEmail
        entitlementRefreshTask?.cancel()

        guard !email.isEmpty else {
            voceProEntitlementStatus = .missingEmail
            return
        }

        voceProEntitlementStatus = .checking(email: email)
        let delayNanoseconds: UInt64 = immediate ? 0 : 500_000_000
        entitlementRefreshTask = Task { [weak self, entitlementService] in
            if delayNanoseconds > 0 {
                try? await Task.sleep(nanoseconds: delayNanoseconds)
            }
            guard !Task.isCancelled else { return }

            do {
                let entitlement = try await entitlementService.check(email: email)
                await MainActor.run {
                    guard self?.normalizedSubscriberEmail == email else { return }
                    self?.voceProEntitlementStatus = entitlement.entitled
                        ? .entitled(entitlement)
                        : .notEntitled(email: email)
                }
            } catch {
                let message = (error as? LocalizedError)?.errorDescription
                    ?? "Could not check Voce access."
                await MainActor.run {
                    guard self?.normalizedSubscriberEmail == email else { return }
                    if case VoceProEntitlementError.authenticationRequired = error {
                        self?.voceProEntitlementStatus = .needsVerification(email: email)
                    } else {
                        self?.voceProEntitlementStatus = .failed(email: email, message: message)
                    }
                }
            }
        }
    }

    private func recordVoceUsageSeconds(_ seconds: TimeInterval) {
        let email = normalizedSubscriberEmail
        guard !email.isEmpty, seconds > 0 else { return }

        let wholeSeconds = max(1, Int(ceil(seconds)))
        Task { [weak self, entitlementService] in
            do {
                let entitlement = try await entitlementService.recordUsage(
                    email: email,
                    seconds: wholeSeconds
                )
                await MainActor.run {
                    guard self?.normalizedSubscriberEmail == email else { return }
                    self?.voceProEntitlementStatus = entitlement.entitled
                        ? .entitled(entitlement)
                        : .notEntitled(email: email)
                }
            } catch {
                let message = (error as? LocalizedError)?.errorDescription
                    ?? "Could not update Voce usage."
                await MainActor.run {
                    guard self?.normalizedSubscriberEmail == email else { return }
                    if case VoceProEntitlementError.authenticationRequired = error {
                        self?.voceProEntitlementStatus = .needsVerification(email: email)
                    } else {
                        self?.voceProEntitlementStatus = .failed(email: email, message: message)
                    }
                }
            }
        }
    }

    private func recordDictationAuditUsage(mode: ActiveCloudUsageMetering?, seconds: TimeInterval) {
        guard seconds > 0 else { return }

        switch mode {
        case .voceHosted:
            recordHostedCloudUsageSeconds(seconds)
        case .directOpenAI:
            recordAuditUsageSeconds(feature: .dictationBYOK, seconds: seconds)
            recordDirectOpenAIUsageSeconds(seconds)
        case nil:
            recordAuditUsageSeconds(feature: .dictationLocal, seconds: seconds)
        }
    }

    private func recordAuditUsageSeconds(feature: VoceEntitlementFeature, seconds: TimeInterval) {
        let email = normalizedSubscriberEmail
        guard !email.isEmpty, seconds > 0 else { return }

        let wholeSeconds = max(1, Int(ceil(seconds)))
        Task { [entitlementService] in
            do {
                _ = try await entitlementService.recordUsage(
                    email: email,
                    feature: feature,
                    seconds: wholeSeconds
                )
            } catch {
                Self.logger.error(
                    "Could not update dictation audit usage \(feature.rawValue, privacy: .public): \(error.localizedDescription, privacy: .public)"
                )
            }
        }
    }

    private func recordHostedCloudUsageSeconds(_ seconds: TimeInterval) {
        let email = normalizedSubscriberEmail
        guard !email.isEmpty, seconds > 0 else { return }

        let wholeSeconds = max(1, Int(ceil(seconds)))
        Task { [weak self, entitlementService] in
            do {
                let entitlement = try await entitlementService.recordUsage(
                    email: email,
                    feature: .cloudDictation,
                    seconds: wholeSeconds
                )
                await MainActor.run {
                    guard self?.normalizedSubscriberEmail == email else { return }
                    self?.voceProEntitlementStatus = entitlement.hasFeature(.appAccess)
                        ? .entitled(entitlement)
                        : .notEntitled(email: email)
                }
            } catch {
                // Hosted usage metering should not make a completed dictation
                // look failed. The next entitlement refresh will retry the read
                // side and recover the visible usage state.
                Self.logger.error("Could not update hosted cloud usage: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func recordDirectOpenAIUsageSeconds(_ seconds: TimeInterval) {
        guard seconds > 0 else { return }

        var snapshot = preferences
        let periodKey = Self.currentUsagePeriodKey()
        if snapshot.dictation.cloud.directUsagePeriodKey != periodKey {
            snapshot.dictation.cloud.directUsagePeriodKey = periodKey
            snapshot.dictation.cloud.directUsageSeconds = 0
        }
        snapshot.dictation.cloud.directUsageSeconds += max(1, Int(ceil(seconds)))
        preferences = snapshot

        Task { [preferencesStore] in
            await preferencesStore.save(snapshot)
        }
    }

    private func validateEngineConfiguration() {
        let localeIdentifier = preferences.dictation.localeIdentifier
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !localeIdentifier.isEmpty else {
            status = "Apple Speech locale is missing. Check Settings \u{2192} Engine."
            return
        }

        if preferences.usesCloudDictationConfiguration {
            let cloudStatus = cloudDictationStatus
            if cloudStatus.isError {
                status = cloudStatus.message
            }
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

    private func validateEngineReadinessForRecording(appContext: AppContext) async throws {
        switch dictationEngineModeResolver.resolve(for: appContext) {
        case .local:
            return
        case .cloud:
            guard canUseCloudDictation else {
                throw CloudDictationError.providerError("Cloud dictation is part of Voce Pro.")
            }
            let cloudStatus = baseCloudDictationStatus()
            guard !cloudStatus.isError else {
                throw CloudDictationError.providerError(cloudStatus.message)
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
        if execution.dictationPolishingApplied {
            messages.append("Polished.")
        } else if execution.dictationPolishingSkippedReason != nil {
            messages.append("Polish skipped.")
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

    private func shouldPolishPlainDictation(_ routedCompletion: RoutedCompletion) -> Bool {
        guard aiRuntimeEnabled, preferences.ai.dictationPolishingEnabled, canUseDictationPolish else {
            return false
        }

        switch routedCompletion.action {
        case .insert, .copyToClipboard, .insertAndSubmit:
            return true
        case .aiWorkflow:
            return false
        }
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

    private func updateHistoryEntryWithAIResult(
        sourceEntry: TranscriptEntry,
        inputText: String,
        result: AIWorkflowResult,
        workflow: AIWorkflow
    ) async throws {
        var updatedEntry = sourceEntry
        updatedEntry.sourceText = inputText
        updatedEntry.cleanText = result.outputText
        updatedEntry.insertionStatus = .copiedOnly
        updatedEntry.processingNote = nil
        updatedEntry.completionAction = completionActionDescription(.aiWorkflow(id: workflow.id))
        updatedEntry.aiWorkflowName = workflow.name
        updatedEntry.aiProvider = result.provider
        try await historyStore.update(entry: updatedEntry)
    }

    private func historyAIInput(for entry: TranscriptEntry) -> String {
        if let sourceText = entry.sourceText?.trimmingCharacters(in: .whitespacesAndNewlines),
           !sourceText.isEmpty {
            return sourceText
        }

        let cleanText = entry.cleanText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !cleanText.isEmpty {
            return cleanText
        }

        return entry.rawText.trimmingCharacters(in: .whitespacesAndNewlines)
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

    var dailyUsageActivity: [DailyUsageActivityDay] {
        let calendar = Calendar.current
        let grouped = Dictionary(grouping: metricEntries) { entry in
            calendar.startOfDay(for: entry.createdAt)
        }

        return grouped
            .map { day, entries in
                DailyUsageActivityDay(
                    day: day,
                    wordCount: entries.reduce(0) { $0 + wordCount(for: $1) },
                    sessionCount: entries.count
                )
            }
            .sorted { $0.day < $1.day }
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

    private func wordCount(for entry: TranscriptEntry) -> Int {
        let text: String
        if entry.aiWorkflowName != nil,
           let sourceText = entry.sourceText,
           !sourceText.isEmpty {
            text = sourceText
        } else {
            text = entry.cleanText.isEmpty ? entry.rawText : entry.cleanText
        }
        return text.split(whereSeparator: \.isWhitespace).count
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

    private func cloudValidationToken(for preferences: AppPreferences) -> String {
        let overrideSignature = preferences.appDictationEnginePreferences
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value.rawValue)" }
            .joined(separator: ",")
        let subscriberEmail = preferences.billing.subscriberEmail
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        return [
            usesDirectCloudCredentials ? "direct-cloud" : "voce-cloud",
            subscriberEmail,
            preferences.dictation.localeIdentifier,
            preferences.dictation.engineMode.rawValue,
            preferences.dictation.cloud.provider.rawValue,
            preferences.dictation.cloud.refinementEnabled ? "refine-on" : "refine-off",
            preferences.dictation.cloud.apiKeySource.rawValue,
            overrideSignature,
            cloudValidationCredentialVersion.uuidString,
        ].joined(separator: "|")
    }

    private func refreshCloudValidationIfNeeded(force: Bool) {
        guard canUseCloudDictation,
              preferences.usesCloudDictationConfiguration
        else {
            cloudValidationTask?.cancel()
            cloudValidationTask = nil
            return
        }

        let baseStatus = baseCloudDictationStatus()
        guard !baseStatus.isError else {
            cloudValidationTask?.cancel()
            cloudValidationTask = nil
            lastCloudValidationToken = nil
            lastCloudValidationFailureMessage = nil
            return
        }

        let dictation = preferences.dictation
        let token = cloudValidationToken(for: preferences)
        guard force || lastCloudValidationToken != token else {
            return
        }

        cloudValidationTask?.cancel()
        cloudValidationTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.runCloudValidation(dictation: dictation, token: token)
            } catch is CancellationError {
                return
            } catch {
                return
            }
        }
    }

    private func runCloudValidation(
        dictation: AppPreferences.Dictation,
        token: String? = nil
    ) async throws {
        let effectiveToken = token ?? cloudValidationToken(for: preferences)

        do {
            let provider = makeCloudSpeechProviderClient(for: dictation)
            try await provider.preflightCheck(localeIdentifier: dictation.localeIdentifier)
            guard !Task.isCancelled else { return }
            if cloudValidationToken(for: preferences) == effectiveToken {
                lastCloudValidationToken = effectiveToken
                lastCloudValidationFailureMessage = nil
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            guard !Task.isCancelled else { throw CancellationError() }
            if cloudValidationToken(for: preferences) == effectiveToken {
                lastCloudValidationToken = effectiveToken
                lastCloudValidationFailureMessage = error.localizedDescription
            }
            throw error
        }
    }
}

private struct DictationRuntimeFactory {
    let snapshot: AppPreferences
    let clipboardService: any ClipboardService
    let wordFrequencies: [String: Int]
    let cloudRuntimeAllowed: Bool
    let subscriberEmail: String
    let useDirectCloudCredentials: Bool

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

    func makeEngineModeResolver() -> DictationEngineModeResolver {
        DictationEngineModeResolver(
            globalMode: snapshot.dictation.engineMode,
            appPreferences: snapshot.appDictationEnginePreferences,
            cloudModeAvailable: cloudRuntimeAllowed
        )
    }

    func makeSessionEngineResolver() -> @Sendable (AppContext) async -> SessionProcessingEngines {
        let modeResolver = makeEngineModeResolver()
        let localTranscription = AppleSpeechTranscriptionEngine(
            config: .init(
                localeIdentifier: snapshot.dictation.localeIdentifier
            )
        )
        let cloudTranscription = CloudStreamingTranscriptionEngine(
            provider: makeCloudSpeechProviderClient(),
            localeIdentifier: snapshot.dictation.localeIdentifier
        )
        let localCleanup = RuleBasedCleanupEngine(wordFrequencies: wordFrequencies)
        let localFallback = RuleBasedCleanupEngine()
        let cloudRefinementEngine: any TranscriptRefinementEngine
        if snapshot.dictation.cloud.refinementEnabled {
            if Self.environmentFlag("VOCE_CLOUD_REFINEMENT_CHUNKING", defaultValue: true) {
                cloudRefinementEngine = ChunkedTranscriptRefinementEngine(
                    provider: makeCloudSpeechProviderClient(),
                    localeIdentifier: snapshot.dictation.localeIdentifier,
                    thresholdWordCount: Self.environmentInt("VOCE_CLOUD_REFINEMENT_CHUNK_THRESHOLD_WORDS") ?? 120,
                    targetChunkWordCount: Self.environmentInt("VOCE_CLOUD_REFINEMENT_CHUNK_WORDS") ?? 80
                )
            } else {
                cloudRefinementEngine = OpenAITranscriptRefinementEngine(
                    provider: makeCloudSpeechProviderClient(),
                    localeIdentifier: snapshot.dictation.localeIdentifier
                )
            }
        } else {
            cloudRefinementEngine = NoOpTranscriptRefinementEngine()
        }

        return { appContext in
            switch modeResolver.resolve(for: appContext) {
            case .local:
                return SessionProcessingEngines(
                    transcriptionEngine: localTranscription,
                    cleanupEngine: localCleanup,
                    fallbackCleanupEngine: localFallback
                )
            case .cloud:
                return SessionProcessingEngines(
                    transcriptionEngine: cloudTranscription,
                    cleanupEngine: CloudCleanupEngineAdapter(
                        refinementEngine: cloudRefinementEngine,
                        currentAppContextProvider: { appContext }
                    ),
                    fallbackCleanupEngine: localFallback
                )
            }
        }
    }

    func runtimeStatusText() -> String {
        let modeResolver = makeEngineModeResolver()
        guard snapshot.usesCloudDictationConfiguration, modeResolver.cloudModeAvailable else {
            return "Running Apple preview + Apple Speech final transcription + local cleanup."
        }

        if snapshot.dictation.engineMode == .cloud,
           !snapshot.appDictationEnginePreferences.values.contains(.local) {
            return "Running OpenAI Realtime Whisper capture/transcription + cloud refinement."
        }

        return "Running Apple preview only for local apps; cloud apps use cloud transcription."
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

    private func makeCloudSpeechProviderClient() -> any CloudSpeechProviderClient {
        CloudSpeechProviderFactory.makeProvider(
            dictation: snapshot.dictation,
            useDirectCredentials: useDirectCloudCredentials,
            subscriberEmail: subscriberEmail
        )
    }

    private static func environmentFlag(_ name: String, defaultValue: Bool = false) -> Bool {
        guard let value = ProcessInfo.processInfo.environment[name]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(),
            !value.isEmpty
        else {
            return defaultValue
        }
        if ["1", "true", "yes", "on"].contains(value) {
            return true
        }
        if ["0", "false", "no", "off"].contains(value) {
            return false
        }
        return defaultValue
    }

    private static func environmentInt(_ name: String) -> Int? {
        guard let value = ProcessInfo.processInfo.environment[name]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        else {
            return nil
        }
        return Int(value)
    }
}
