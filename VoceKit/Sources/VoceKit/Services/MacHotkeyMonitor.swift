#if os(macOS)
import AppKit
import os

/// Shared state between MacHotkeyMonitor and its CGEventTap C callback.
///
/// The tap callback runs on a dedicated event-tap thread (see
/// `HotkeyEventTapThread`) while configuration writes arrive from the main
/// actor, so every field is guarded by a lock. Fields are individually
/// atomic; the callback needs no cross-field invariants — a settings write
/// racing a keystroke simply takes effect on the next event.
private final class TapContext: @unchecked Sendable {
    private let lock = NSLock()

    private weak var _monitor: MacHotkeyMonitor?
    private var _hotkey: HandsFreeToggleHotkey?
    private var _onToggle: (() -> Void)?
    private var _onSubmit: (() -> Void)?
    private var _aiFinishHotkey: HandsFreeHotkey?
    private var _aiWorkflowFinishHotkeys: [HandsFreeHotkey] = []
    private var _onAIFinish: ((HandsFreeHotkey?) -> Void)?
    private var _onCaptureSelectionCorrection: (() -> Void)?
    private var _onCaptureSelectionSnippet: (() -> Void)?
    private var _selectionCorrectionHotkey: VoceKeyboardShortcut = .dictionaryCorrectionDefault
    private var _selectionSnippetHotkey: VoceKeyboardShortcut = .snippetCreationDefault
    private var _isSubmitEnabled = false
    private var _isAIFinishEnabled = false
    private var _machPort: CFMachPort?
    /// Monotonic timestamp of the last tap re-enable, used to debounce rapid
    /// disable/re-enable cycles that can occur when the system times out the tap.
    private var _lastReenableTime: CFAbsoluteTime = 0

    var monitor: MacHotkeyMonitor? {
        get { lock.withLock { _monitor } }
        set { lock.withLock { _monitor = newValue } }
    }
    var hotkey: HandsFreeToggleHotkey? {
        get { lock.withLock { _hotkey } }
        set { lock.withLock { _hotkey = newValue } }
    }
    var onToggle: (() -> Void)? {
        get { lock.withLock { _onToggle } }
        set { lock.withLock { _onToggle = newValue } }
    }
    var onSubmit: (() -> Void)? {
        get { lock.withLock { _onSubmit } }
        set { lock.withLock { _onSubmit = newValue } }
    }
    var aiFinishHotkey: HandsFreeHotkey? {
        get { lock.withLock { _aiFinishHotkey } }
        set { lock.withLock { _aiFinishHotkey = newValue } }
    }
    var aiWorkflowFinishHotkeys: [HandsFreeHotkey] {
        get { lock.withLock { _aiWorkflowFinishHotkeys } }
        set { lock.withLock { _aiWorkflowFinishHotkeys = newValue } }
    }
    var onAIFinish: ((HandsFreeHotkey?) -> Void)? {
        get { lock.withLock { _onAIFinish } }
        set { lock.withLock { _onAIFinish = newValue } }
    }
    var onCaptureSelectionCorrection: (() -> Void)? {
        get { lock.withLock { _onCaptureSelectionCorrection } }
        set { lock.withLock { _onCaptureSelectionCorrection = newValue } }
    }
    var onCaptureSelectionSnippet: (() -> Void)? {
        get { lock.withLock { _onCaptureSelectionSnippet } }
        set { lock.withLock { _onCaptureSelectionSnippet = newValue } }
    }
    var selectionCorrectionHotkey: VoceKeyboardShortcut {
        get { lock.withLock { _selectionCorrectionHotkey } }
        set { lock.withLock { _selectionCorrectionHotkey = newValue } }
    }
    var selectionSnippetHotkey: VoceKeyboardShortcut {
        get { lock.withLock { _selectionSnippetHotkey } }
        set { lock.withLock { _selectionSnippetHotkey = newValue } }
    }
    var isSubmitEnabled: Bool {
        get { lock.withLock { _isSubmitEnabled } }
        set { lock.withLock { _isSubmitEnabled = newValue } }
    }
    var isAIFinishEnabled: Bool {
        get { lock.withLock { _isAIFinishEnabled } }
        set { lock.withLock { _isAIFinishEnabled = newValue } }
    }
    var machPort: CFMachPort? {
        get { lock.withLock { _machPort } }
        set { lock.withLock { _machPort = newValue } }
    }

    /// Atomically applies the re-enable debounce and claims the port.
    /// Returns the mach port to re-enable, or nil when debounced or when the
    /// tap is being torn down (`machPort` already cleared by uninstall).
    func claimReenablePort(debounce: CFAbsoluteTime) -> CFMachPort? {
        lock.withLock {
            let now = CFAbsoluteTimeGetCurrent()
            guard let port = _machPort, now - _lastReenableTime >= debounce else { return nil }
            _lastReenableTime = now
            return port
        }
    }
}

/// Owns the run loop that services the CGEventTap.
///
/// The tap is an *active* tap (`.defaultTap`) on every keyDown in the login
/// session: the window server holds each keystroke — in every app — until
/// our callback returns. Servicing it on the main run loop couples
/// system-wide typing latency to the app's main-thread health (busy UI,
/// App Nap throttling, transcription work), which users experience as
/// keyboard lag in other apps whenever Voce is running. This dedicated
/// `.userInteractive` thread does nothing but pump the tap's run-loop
/// source, so keystrokes flow through in microseconds regardless of what
/// the rest of the app is doing.
///
/// Lifecycle: `shutdown()` may be called from any thread. It disables the
/// tap immediately, then performs invalidation and the run-loop stop *on
/// this thread*, serialized behind any in-flight callback. The thread also
/// retains the `TapContext`, so the tap's unretained refcon pointer stays
/// valid for the last possible callback even if the owning monitor
/// deallocates first.
private final class HotkeyEventTapThread: Thread {
    private let tap: CFMachPort
    private let source: CFRunLoopSource
    private let contextRetainer: AnyObject
    private let lock = NSLock()
    private var runLoop: CFRunLoop?
    private var shutdownRequested = false

    init(tap: CFMachPort, source: CFRunLoopSource, retaining context: AnyObject) {
        self.tap = tap
        self.source = source
        self.contextRetainer = context
        super.init()
        name = "com.voce.hotkey-event-tap"
        qualityOfService = .userInteractive
    }

    override func main() {
        let currentRunLoop = CFRunLoopGetCurrent()
        let shouldRun: Bool = lock.withLock {
            runLoop = currentRunLoop
            return !shutdownRequested
        }
        guard shouldRun else {
            // shutdown() won the race before this run loop existed, so it
            // couldn't queue the teardown block. Tear down here instead.
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
            return
        }

        CFRunLoopAddSource(currentRunLoop, source, .commonModes)
        // Runs until the shutdown block calls CFRunLoopStop. If shutdown()
        // queued its block before this line, the loop executes it on the
        // first turn and exits immediately — it never spins empty.
        CFRunLoopRun()
    }

    func shutdown() {
        // Stop event delivery immediately (tapEnable is thread-safe) so a
        // replacement tap installed right after this call can't briefly
        // double-handle the same keystroke.
        CGEvent.tapEnable(tap: tap, enable: false)

        let capturedRunLoop: CFRunLoop? = lock.withLock {
            shutdownRequested = true
            return runLoop
        }
        // Thread hasn't reached main() yet; it will observe
        // shutdownRequested and tear down on its own.
        guard let capturedRunLoop else { return }

        CFRunLoopPerformBlock(capturedRunLoop, CFRunLoopMode.commonModes.rawValue) { [tap, source] in
            CFMachPortInvalidate(tap)
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)
            CFRunLoopStop(CFRunLoopGetCurrent())
        }
        CFRunLoopWakeUp(capturedRunLoop)
    }
}

@MainActor
public final class MacHotkeyMonitor: HotkeyService {
    nonisolated static let logger = Logger(subsystem: "io.voceapp.vocekit", category: "HotkeyMonitor")

    public var onPressToTalkStart: (() -> Void)?
    public var onPressToTalkStop: (() -> Void)?
    public var onToggleHandsFree: (() -> Void)? {
        didSet { tapContext.onToggle = onToggleHandsFree }
    }
    public var onSubmitActiveRecording: (() -> Void)? {
        didSet { tapContext.onSubmit = onSubmitActiveRecording }
    }
    public var onFinishActiveRecordingWithAI: ((HandsFreeHotkey?) -> Void)? {
        didSet { tapContext.onAIFinish = onFinishActiveRecordingWithAI }
    }
    public var onCaptureSelectionCorrection: (() -> Void)? {
        didSet {
            tapContext.onCaptureSelectionCorrection = onCaptureSelectionCorrection
            guard hasStarted else { return }
            updateHandsFreeStatus()
        }
    }
    public var onCaptureSelectionSnippet: (() -> Void)? {
        didSet {
            tapContext.onCaptureSelectionSnippet = onCaptureSelectionSnippet
            guard hasStarted else { return }
            updateHandsFreeStatus()
        }
    }
    /// Fired when the user taps Cmd+Option together (both pressed and released
    /// within `voceActionsTapMaxDuration`, no other key or modifier in between).
    /// Used to surface the Voce action picker (dictionary fix / snippet creation).
    public var onVoceActionsTap: (() -> Void)?
    /// Gate for the Cmd+Option-tap detector. When false the detector is fully
    /// dormant and incurs no per-event cost beyond the existing flagsChanged
    /// dispatch.
    public var isVoceActionsTapEnabled: Bool = false {
        didSet {
            if !isVoceActionsTapEnabled {
                voceActionsTapStartedAt = nil
                voceActionsTapInterrupted = false
                // If the user just disabled the gate while a PTT start was
                // being held back to disambiguate, fire it immediately so we
                // don't strand the modifier in a perpetually-deferred state.
                if pendingPressToTalkStartTask != nil, isPressToTalkHeld {
                    cancelPendingPressToTalkStart()
                    didEmitPressToTalkStart = true
                    let generation = callbackGeneration
                    Task { @MainActor [weak self] in
                        guard let self,
                              self.hasStarted,
                              self.callbackGeneration == generation else {
                            return
                        }
                        self.onPressToTalkStart?()
                    }
                }
            }
        }
    }
    public var onRegistrationStatusChanged: ((HotkeyRegistrationStatus) -> Void)?
    public var selectionCorrectionHotkey: VoceKeyboardShortcut = .dictionaryCorrectionDefault {
        didSet {
            tapContext.selectionCorrectionHotkey = selectionCorrectionHotkey
            guard hasStarted else { return }
            updateHandsFreeStatus()
        }
    }
    public var selectionSnippetHotkey: VoceKeyboardShortcut = .snippetCreationDefault {
        didSet {
            tapContext.selectionSnippetHotkey = selectionSnippetHotkey
            guard hasStarted else { return }
            updateHandsFreeStatus()
        }
    }

    public var isOptionPressToTalkEnabled: Bool = true
    public var pressToTalkHotkey: PressToTalkHotkey = .default {
        didSet {
            isPressToTalkHeld = false
            cancelPendingPressToTalkStart()
            didEmitPressToTalkStart = false
            pressToTalkEmittedThisGesture = false
            toggleModifierGate.reset()
            toggleDoubleTapGate.reset()
            isGlobalToggleModifierHeld = false
        }
    }
    public var globalToggleHotkey: HandsFreeToggleHotkey? = .init(hotkey: .keyCode(79)) {
        didSet {
            tapContext.hotkey = globalToggleHotkey
            toggleModifierGate.reset()
            toggleDoubleTapGate.reset()
            isGlobalToggleModifierHeld = false
            guard hasStarted else { return }
            updateHandsFreeStatus()
        }
    }
    public var isSubmitActiveRecordingEnabled: Bool = false {
        didSet {
            tapContext.isSubmitEnabled = isSubmitActiveRecordingEnabled
            guard hasStarted else { return }
            updateHandsFreeStatus()
        }
    }
    public var aiFinishHotkey: HandsFreeHotkey? {
        didSet {
            tapContext.aiFinishHotkey = aiFinishHotkey
            guard hasStarted else { return }
            updateHandsFreeStatus()
        }
    }
    public var aiWorkflowFinishHotkeys: [HandsFreeHotkey] = [] {
        didSet {
            tapContext.aiWorkflowFinishHotkeys = aiWorkflowFinishHotkeys
            guard hasStarted else { return }
            updateHandsFreeStatus()
        }
    }
    public var isAIFinishEnabled: Bool = false {
        didSet {
            tapContext.isAIFinishEnabled = isAIFinishEnabled
            guard hasStarted else { return }
            updateHandsFreeStatus()
        }
    }

    private var globalFlagsMonitor: Any?
    private var localFlagsMonitor: Any?
    private var globalKeyDownMonitor: Any?
    private var localKeyDownMonitor: Any?
    /// Tracks the *intent* state (the configured modifier set is currently
    /// pressed). May be true even when no `onPressToTalkStart` has fired yet,
    /// because the deferral path waits for the Voce-actions-tap window to
    /// resolve before emitting start. Pair with `didEmitPressToTalkStart` to
    /// know whether a stop should fire on release.
    private var isPressToTalkHeld = false
    /// True between an actually-emitted `onPressToTalkStart` and the matching
    /// `onPressToTalkStop`. The deferred-start path only flips this once the
    /// timer fires, so a user who taps Cmd+Option (cancelling the deferral)
    /// never sees a phantom stop.
    private var didEmitPressToTalkStart = false
    /// Live timer for a deferred PTT start. Cancelled if the modifier set
    /// changes (user added Cmd, released Option, etc) before the deferral
    /// elapses.
    private var pendingPressToTalkStartTask: Task<Void, Never>?
    /// True when `onPressToTalkStart` has actually emitted somewhere inside
    /// the current modifier gesture (the span between modifiers transitioning
    /// from empty → non-empty and returning to empty). Used by the Voce-
    /// actions tap detector to suppress its fire if the slow-tap race
    /// produced a phantom PTT cycle — otherwise the picker would race the
    /// controller's transcription/finalisation of the just-stopped recording
    /// and could insert a stale transcript over the user's selection.
    /// Cleared at every gesture boundary (see `handleFlagsChanged`) so it
    /// can't leak across an unrelated PTT session into a later tap.
    private var pressToTalkEmittedThisGesture: Bool = false
    /// Snapshot of the modifier flags from the previous `flagsChanged`, used
    /// to detect the empty → non-empty transition that marks the start of a
    /// fresh modifier gesture.
    private var previousModifierFlags: NSEvent.ModifierFlags = []
    private var isGlobalToggleModifierHeld = false
    private var toggleModifierGate = HotkeyToggleGate()
    private var toggleDoubleTapGate = HotkeyDoubleTapGate()
    private var callbackGeneration: UInt64 = 0
    private var lastActiveRecordingKeyCode: UInt16?
    private var lastActiveRecordingKeyTime: CFAbsoluteTime = 0

    // MARK: - Cmd+Option Tap (Voce Actions Picker)
    /// Timestamp at which the user transitioned to *exactly* Cmd+Option held
    /// (no other modifiers, no other keys). Cleared when the window resolves
    /// (fire / abort) or when the gate is disabled.
    private var voceActionsTapStartedAt: CFAbsoluteTime?
    /// Set when any keyDown arrives while the tap window is open — kills the
    /// fire so chords like Cmd+Option+T stay normal chords.
    private var voceActionsTapInterrupted: Bool = false
    /// Maximum elapsed time from "both pressed" to "both released" that still
    /// counts as a tap. Past this, the user is *holding* Cmd+Option (likely
    /// for some other purpose) and we don't fire.
    private static let voceActionsTapMaxDuration: CFAbsoluteTime = 0.3
    /// Delay before emitting `onPressToTalkStart` when the configured PTT
    /// modifier set overlaps with Cmd+Option (the Voce-actions tap chord).
    ///
    /// Tuned to be just long enough to catch a fast same-frame Cmd+Option
    /// press — empirically the gap between two simultaneous-feeling modifier
    /// presses is 30–80 ms — but short enough that hold-to-talk on the
    /// default Option chord still feels instant. ~70 ms is below the human
    /// perception threshold for press latency.
    ///
    /// A "slow tap" with a gap >70 ms will briefly start PTT then stop it
    /// when Cmd joins; the resulting recording is too short to produce a
    /// useful transcript and the empty/no-speech path swallows it. Users
    /// who can't tolerate any phantom recordings can disable Voce actions
    /// in Recording Settings, which removes the deferral entirely.
    private static let pressToTalkVoceTapDeferral: TimeInterval = 0.07

    private var hasStarted = false

    private var eventTap: CFMachPort?
    private var tapThread: HotkeyEventTapThread?
    /// App Nap opt-out token, held while the event tap is installed.
    private var eventTapActivityToken: NSObjectProtocol?
    private let tapContext = TapContext()
    public init() {
        tapContext.monitor = self
        tapContext.hotkey = globalToggleHotkey
        tapContext.isSubmitEnabled = isSubmitActiveRecordingEnabled
        tapContext.aiFinishHotkey = aiFinishHotkey
        tapContext.aiWorkflowFinishHotkeys = aiWorkflowFinishHotkeys
        tapContext.isAIFinishEnabled = isAIFinishEnabled
        tapContext.onCaptureSelectionCorrection = onCaptureSelectionCorrection
        tapContext.onCaptureSelectionSnippet = onCaptureSelectionSnippet
        tapContext.selectionCorrectionHotkey = selectionCorrectionHotkey
        tapContext.selectionSnippetHotkey = selectionSnippetHotkey
    }

    public func start() {
        guard !hasStarted else { return }
        callbackGeneration &+= 1
        hasStarted = true
        installPressToTalkMonitors()
        installActiveRecordingKeyMonitors()
        updateHandsFreeStatus()
    }

    public func stop() {
        callbackGeneration &+= 1
        hasStarted = false
        uninstallEventTap()
        uninstallPressToTalkMonitors()
        uninstallActiveRecordingKeyMonitors()
        isPressToTalkHeld = false
        cancelPendingPressToTalkStart()
        didEmitPressToTalkStart = false
        pressToTalkEmittedThisGesture = false
        previousModifierFlags = []
        isGlobalToggleModifierHeld = false
        toggleModifierGate.reset()
        toggleDoubleTapGate.reset()
        voceActionsTapStartedAt = nil
        voceActionsTapInterrupted = false
    }

    // MARK: - Press-to-Talk Monitors

    private func installPressToTalkMonitors() {
        guard globalFlagsMonitor == nil, localFlagsMonitor == nil else { return }

        globalFlagsMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handleFlagsChanged(event)
        }

        localFlagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handleFlagsChanged(event)
            return event
        }
    }

    private func uninstallPressToTalkMonitors() {
        if let globalFlagsMonitor {
            NSEvent.removeMonitor(globalFlagsMonitor)
            self.globalFlagsMonitor = nil
        }
        if let localFlagsMonitor {
            NSEvent.removeMonitor(localFlagsMonitor)
            self.localFlagsMonitor = nil
        }
    }

    private func installActiveRecordingKeyMonitors() {
        guard globalKeyDownMonitor == nil, localKeyDownMonitor == nil else { return }

        globalKeyDownMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handleActiveRecordingKeyDown(event, canSuppress: false)
        }

        localKeyDownMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            let shouldSuppress = self.handleActiveRecordingKeyDown(event, canSuppress: true)
            return shouldSuppress ? nil : event
        }
    }

    private func uninstallActiveRecordingKeyMonitors() {
        if let globalKeyDownMonitor {
            NSEvent.removeMonitor(globalKeyDownMonitor)
            self.globalKeyDownMonitor = nil
        }
        if let localKeyDownMonitor {
            NSEvent.removeMonitor(localKeyDownMonitor)
            self.localKeyDownMonitor = nil
        }
    }

    @discardableResult
    private func handleActiveRecordingKeyDown(_ event: NSEvent, canSuppress: Bool) -> Bool {
        // Any keyDown during an open Cmd+Option tap window means the user is
        // building a chord (Cmd+Option+T, etc.), not tapping. Mark interrupted
        // so the upcoming release won't fire the picker. This runs regardless
        // of modifier state because the pure modifiers-only release path is
        // what the tap detector cares about, not the keyDown's own modifiers.
        if voceActionsTapStartedAt != nil {
            voceActionsTapInterrupted = true
        }

        let keyCode = event.keyCode
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard modifiers.subtracting(.capsLock).isEmpty, !event.isARepeat else {
            return false
        }

        if isSubmitActiveRecordingEnabled, isReturnKeyCode(keyCode) {
            guard shouldHandleActiveRecordingKey(keyCode) else { return false }
            onSubmitActiveRecording?()
            return canSuppress
        }

        if isAIFinishEnabled,
           let matchedHotkey = matchingAIWorkflowHotkey(for: keyCode) {
            guard shouldHandleActiveRecordingKey(keyCode) else { return false }
            onFinishActiveRecordingWithAI?(matchedHotkey)
            return canSuppress
        }

        return false
    }

    private func matchingAIWorkflowHotkey(for keyCode: UInt16) -> HandsFreeHotkey? {
        if let matchedCustom = aiWorkflowFinishHotkeys.first(where: {
            if case .keyCode(let customKeyCode) = $0 {
                return customKeyCode == keyCode
            }
            return false
        }) {
            return matchedCustom
        }

        if case .keyCode(let aiKeyCode)? = aiFinishHotkey, aiKeyCode == keyCode {
            return nil
        }

        return nil
    }

    private func shouldHandleActiveRecordingKey(_ keyCode: UInt16) -> Bool {
        let now = CFAbsoluteTimeGetCurrent()
        if lastActiveRecordingKeyCode == keyCode, now - lastActiveRecordingKeyTime < 0.15 {
            return false
        }
        lastActiveRecordingKeyCode = keyCode
        lastActiveRecordingKeyTime = now
        return true
    }

    private func handleFlagsChanged(_ event: NSEvent) {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        // Gesture boundary: every time the *user-pressed* modifiers go from
        // fully empty to any held state, a brand-new physical gesture is
        // beginning. Clear any gesture-scoped flags so state from a prior PTT
        // session can't leak into the new gesture's tap evaluation.
        //
        // Caps Lock has to be stripped here — PTT matching ignores it (see
        // `handlePressToTalkFlagsChanged`), so leaving it in would mean a
        // user with Caps Lock on never returns to "empty" between gestures
        // and the boundary reset never fires. (Reading `previousModifier-
        // Flags` before the per-handler dispatch keeps the boundary stable
        // across all three handlers in this tick.)
        let effectiveModifiers = modifiers.subtracting(.capsLock)
        if previousModifierFlags.isEmpty && !effectiveModifiers.isEmpty {
            pressToTalkEmittedThisGesture = false
        }
        previousModifierFlags = effectiveModifiers

        handlePressToTalkFlagsChanged(modifiers)
        handleModifierToggleFlagsChanged(modifiers)
        handleVoceActionsTapFlagsChanged(modifiers)
    }

    /// Detect a deliberate "tap Cmd+Option" gesture: both modifiers pressed,
    /// then both released, within ~300ms, with no other key or modifier in
    /// between. Fires `onVoceActionsTap` once on the second-modifier release.
    ///
    /// Why a release-driven detector and not Carbon RegisterEventHotKey:
    /// Carbon hotkeys require a non-modifier key. We watch flagsChanged
    /// instead so the modifier-only chord doesn't shadow normal usage of Cmd
    /// or Option as prefixes — chords like Cmd+Option+T abort via the keyDown
    /// hook in `handleActiveRecordingKeyDown`.
    private func handleVoceActionsTapFlagsChanged(_ modifiers: NSEvent.ModifierFlags) {
        guard isVoceActionsTapEnabled else {
            voceActionsTapStartedAt = nil
            voceActionsTapInterrupted = false
            return
        }

        let cmdHeld = modifiers.contains(.command)
        let optionHeld = modifiers.contains(.option)
        // Anything outside the Cmd+Option pair disqualifies the tap. capsLock
        // is already stripped upstream; .numericPad/.help can transient-fire
        // on some keyboards so we ignore them.
        let extraModsHeld = !modifiers
            .intersection([.control, .shift, .function])
            .isEmpty

        if voceActionsTapStartedAt == nil {
            // Idle: open a tap window the moment the user enters *exactly*
            // Cmd+Option with nothing else held.
            if cmdHeld, optionHeld, !extraModsHeld {
                voceActionsTapStartedAt = CFAbsoluteTimeGetCurrent()
                voceActionsTapInterrupted = false
            }
            return
        }

        // Tap window is open.
        if extraModsHeld {
            // User added Shift/Control/etc — they're starting a real chord,
            // not tapping. Abort cleanly.
            voceActionsTapStartedAt = nil
            voceActionsTapInterrupted = false
            return
        }

        if !cmdHeld, !optionHeld {
            // Both released — terminal state. Decide whether to fire.
            let started = voceActionsTapStartedAt ?? CFAbsoluteTimeGetCurrent()
            let duration = CFAbsoluteTimeGetCurrent() - started
            // Slow-tap safety: if PTT actually emitted during this gesture,
            // a recording was started and stopped while the tap window was
            // open. The controller is now mid-finalise/transcribe of that
            // phantom clip; presenting the picker on top of that races
            // selection capture against the in-flight transcript and can
            // insert it over the user's selection. Suppress the picker —
            // the user can re-tap once the phantom clip clears (it's too
            // short to produce a useful transcript anyway).
            let shouldFire = !voceActionsTapInterrupted
                && !pressToTalkEmittedThisGesture
                && duration <= Self.voceActionsTapMaxDuration
            voceActionsTapStartedAt = nil
            voceActionsTapInterrupted = false

            guard shouldFire else { return }
            let generation = callbackGeneration
            Task { @MainActor [weak self] in
                guard let self,
                      self.hasStarted,
                      self.callbackGeneration == generation else {
                    return
                }
                self.onVoceActionsTap?()
            }
            return
        }

        // Partial release (one of Cmd/Option still held) — keep waiting.
        // The tap can still complete when the second modifier releases, as
        // long as the cumulative duration stays under the threshold.
    }

    private func handlePressToTalkFlagsChanged(_ modifiers: NSEvent.ModifierFlags) {
        guard isOptionPressToTalkEnabled else { return }

        let effectiveModifiers = modifiers.subtracting(.capsLock)
        let hotkeyIsNowHeld = effectiveModifiers == pressToTalkHotkey.eventFlags
        guard hotkeyIsNowHeld != isPressToTalkHeld else { return }

        isPressToTalkHeld = hotkeyIsNowHeld
        let generation = callbackGeneration

        if hotkeyIsNowHeld {
            // Modifier set just became the configured PTT chord. If it
            // overlaps with Cmd+Option we have to wait out the tap window
            // before emitting start — otherwise tapping Cmd+Option to open
            // the action picker would briefly start (and then stop) PTT
            // dictation as the second modifier joins the first.
            cancelPendingPressToTalkStart()
            // Fresh PTT engagement — reset the gesture-scoped "did we emit"
            // flag so the upcoming voce-tap evaluation only sees emits from
            // *this* press cycle.
            pressToTalkEmittedThisGesture = false

            if shouldDeferPressToTalkForVoceTap {
                let task = Task { @MainActor [weak self] in
                    let nanoseconds = UInt64(Self.pressToTalkVoceTapDeferral * 1_000_000_000)
                    try? await Task.sleep(nanoseconds: nanoseconds)
                    guard !Task.isCancelled,
                          let self,
                          self.hasStarted,
                          self.callbackGeneration == generation,
                          self.isPressToTalkHeld,
                          self.pendingPressToTalkStartTask != nil else {
                        return
                    }
                    self.pendingPressToTalkStartTask = nil
                    self.didEmitPressToTalkStart = true
                    self.pressToTalkEmittedThisGesture = true
                    self.onPressToTalkStart?()
                }
                pendingPressToTalkStartTask = task
            } else {
                didEmitPressToTalkStart = true
                pressToTalkEmittedThisGesture = true
                Task { @MainActor [weak self] in
                    guard let self,
                          self.hasStarted,
                          self.callbackGeneration == generation else {
                        return
                    }
                    self.onPressToTalkStart?()
                }
            }
        } else {
            // Modifier set fell off the PTT chord. If we never actually
            // emitted start (deferral timer was still pending), suppress the
            // matching stop so callers don't see a phantom toggle pair.
            cancelPendingPressToTalkStart()

            guard didEmitPressToTalkStart else { return }
            didEmitPressToTalkStart = false

            Task { @MainActor [weak self] in
                guard let self,
                      self.hasStarted,
                      self.callbackGeneration == generation else {
                    return
                }
                self.onPressToTalkStop?()
            }
        }
    }

    /// True when the configured PTT chord is non-empty and is a subset of
    /// `[.command, .option]` — exactly the cases where engaging part of the
    /// chord is indistinguishable from the user beginning a Voce-actions tap.
    private var shouldDeferPressToTalkForVoceTap: Bool {
        guard isVoceActionsTapEnabled else { return false }
        let pttFlags = pressToTalkHotkey.eventFlags
        guard !pttFlags.isEmpty else { return false }
        let voceTapFlags: NSEvent.ModifierFlags = [.command, .option]
        return pttFlags.isSubset(of: voceTapFlags)
    }

    private func cancelPendingPressToTalkStart() {
        pendingPressToTalkStartTask?.cancel()
        pendingPressToTalkStartTask = nil
    }

    private func handleModifierToggleFlagsChanged(_ modifiers: NSEvent.ModifierFlags) {
        guard let globalToggleHotkey else { return }
        guard case .modifier(let modifier) = globalToggleHotkey.hotkey else { return }

        let modifierIsNowHeld = modifiers.contains(modifier.eventFlags)
        guard modifierIsNowHeld != isGlobalToggleModifierHeld else { return }

        isGlobalToggleModifierHeld = modifierIsNowHeld
        let generation = callbackGeneration
        let signal: HotkeySignal = modifierIsNowHeld ? .pressed : .released

        let shouldToggle: Bool
        switch globalToggleHotkey.triggerStyle {
        case .singleTap:
            shouldToggle = toggleModifierGate.consume(signal)
        case .doubleTap:
            shouldToggle = toggleDoubleTapGate.consume(signal)
        }

        guard shouldToggle else { return }

        Task { @MainActor [weak self] in
            guard let self,
                  self.hasStarted,
                  self.callbackGeneration == generation else {
                return
            }
            self.onToggleHandsFree?()
        }
    }

    private func handleKeyCodeToggleTap(triggerStyle: HandsFreeToggleHotkey.TriggerStyle) {
        let shouldToggle: Bool
        switch triggerStyle {
        case .singleTap:
            shouldToggle = true
        case .doubleTap:
            shouldToggle = toggleDoubleTapGate.registerTap()
        }

        guard shouldToggle else { return }
        onToggleHandsFree?()
    }

    // MARK: - CGEventTap (Hands-Free Toggle)

    private func installEventTap() {
        guard eventTap == nil else { return }

        let refcon = Unmanaged.passUnretained(tapContext).toOpaque()
        let eventMask: CGEventMask = 1 << CGEventType.keyDown.rawValue

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: Self.eventTapCallback,
            userInfo: refcon
        ) else {
            Self.logger.error("CGEvent.tapCreate failed — Input Monitoring/Accessibility not granted for this binary")
            onRegistrationStatusChanged?(
                .unavailable(reason: "Input Monitoring permission required for shortcuts.")
            )
            return
        }

        // Keep this assignment immediately after tap creation so callback re-enable
        // logic can always find the live mach port.
        eventTap = tap
        tapContext.machPort = tap

        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            tapContext.machPort = nil
            CFMachPortInvalidate(tap)
            eventTap = nil
            onRegistrationStatusChanged?(
                .unavailable(reason: "Could not install the keyboard shortcut listener.")
            )
            return
        }

        // Service the tap on a dedicated thread — never the main run loop.
        // An active tap makes the window server hold every keystroke until
        // the callback returns; tying that to the main run loop couples
        // system-wide typing latency to main-thread health and App Nap.
        let thread = HotkeyEventTapThread(tap: tap, source: source, retaining: tapContext)
        tapThread = thread
        thread.start()

        beginEventTapActivity()
        Self.logger.notice("Event tap installed on dedicated thread; App Nap disabled")
        onRegistrationStatusChanged?(.registered)
    }

    private func uninstallEventTap() {
        // Clear the port first so the callback's timeout re-enable path
        // can't race the teardown and revive a dying tap.
        tapContext.machPort = nil
        if let tapThread {
            tapThread.shutdown()
            self.tapThread = nil
            Self.logger.notice("Event tap uninstalled; tap thread shutting down")
        }
        eventTap = nil
        endEventTapActivity()
    }

    // MARK: - App Nap

    /// While the event tap is installed, opt out of App Nap. A napped app's
    /// threads get coalesced timers and lowered priority; with an active tap
    /// in the keystroke path that shows up as system-wide keyboard lag
    /// whenever Voce sits idle in the background. `.latencyCritical` asks for
    /// full timer/scheduling precision; `.userInitiatedAllowingIdleSystemSleep`
    /// prevents the nap without keeping the Mac awake.
    private func beginEventTapActivity() {
        guard eventTapActivityToken == nil else { return }
        eventTapActivityToken = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiatedAllowingIdleSystemSleep, .latencyCritical],
            reason: "Keyboard shortcut event tap must stay responsive"
        )
    }

    private func endEventTapActivity() {
        guard let token = eventTapActivityToken else { return }
        ProcessInfo.processInfo.endActivity(token)
        eventTapActivityToken = nil
    }

    private func updateHandsFreeStatus() {
        let needsEventTap = tapContext.onCaptureSelectionCorrection != nil
            || tapContext.onCaptureSelectionSnippet != nil
            || isSubmitActiveRecordingEnabled
            || isAIFinishEnabled

        if isOptionPressToTalkEnabled,
           let globalToggleHotkey,
           case .modifier(let modifier) = globalToggleHotkey.hotkey,
           pressToTalkHotkey.contains(modifier.asPressToTalkModifier) {
            uninstallEventTap()
            onRegistrationStatusChanged?(
                .unavailable(reason: "Hands-free key can't be part of the hold-to-talk key.")
            )
            return
        }

        if isSubmitActiveRecordingEnabled,
           let globalToggleHotkey,
           case .keyCode(let keyCode) = globalToggleHotkey.hotkey,
           isReturnKeyCode(keyCode) {
            uninstallEventTap()
            onRegistrationStatusChanged?(
                .unavailable(reason: "Return can't be both the hands-free key and the end-and-submit key.")
            )
            return
        }

        if isAIFinishEnabled {
            let allAIHotkeys = ([aiFinishHotkey].compactMap { $0 } + aiWorkflowFinishHotkeys)
            if allAIHotkeys.isEmpty {
                uninstallEventTap()
                onRegistrationStatusChanged?(
                    .unavailable(reason: "Set an AI finish key on at least one AI workflow.")
                )
                return
            }

            var seenAIKeyCodes: Set<UInt16> = []
            for hotkey in allAIHotkeys {
                guard case .keyCode(let aiKeyCode) = hotkey else {
                    uninstallEventTap()
                    onRegistrationStatusChanged?(
                        .unavailable(reason: "AI finish keys must be single keys, not modifiers.")
                    )
                    return
                }

                if !seenAIKeyCodes.insert(aiKeyCode).inserted {
                    uninstallEventTap()
                    onRegistrationStatusChanged?(
                        .unavailable(reason: "Each AI finish key must be unique.")
                    )
                    return
                }

                if let globalToggleHotkey,
                   case .keyCode(let toggleKeyCode) = globalToggleHotkey.hotkey,
                   toggleKeyCode == aiKeyCode {
                    uninstallEventTap()
                    onRegistrationStatusChanged?(
                        .unavailable(reason: "AI finish keys can't match the hands-free key.")
                    )
                    return
                }

                if isSubmitActiveRecordingEnabled, isReturnKeyCode(aiKeyCode) {
                    uninstallEventTap()
                    onRegistrationStatusChanged?(
                        .unavailable(reason: "Return can't be both the end-and-submit key and an AI finish key.")
                    )
                    return
                }
            }
        }

        switch globalToggleHotkey?.hotkey {
        case .keyCode?:
            installEventTap()
        case .modifier?:
            if needsEventTap {
                installEventTap()
            } else {
                uninstallEventTap()
                onRegistrationStatusChanged?(.registered)
            }
        case nil:
            if needsEventTap {
                installEventTap()
            } else {
                uninstallEventTap()
                onRegistrationStatusChanged?(
                    .unavailable(reason: "Global hands-free key disabled in settings.")
                )
            }
        }
    }

    // MARK: - CGEventTap Callback

    /// C-compatible callback for the CGEventTap. Runs on the dedicated
    /// event-tap thread (`HotkeyEventTapThread`), NOT the main thread — the
    /// window server is holding the keystroke for every app until this
    /// returns, so it must stay fast and must never wait on the main actor.
    /// All real work is dispatched to the main queue; TapContext reads are
    /// lock-guarded.
    /// Minimum interval between tap re-enables to prevent rapid disable/enable cycling.
    private nonisolated static let reenableDebounceInterval: CFAbsoluteTime = 0.1

    // `nonisolated` is load-bearing on the callback and every helper it
    // calls: MacHotkeyMonitor is @MainActor, so un-annotated statics are
    // MainActor-isolated and carry a runtime executor assertion — which
    // traps (SIGTRAP) when the callback fires on the event-tap thread.
    private nonisolated static let eventTapCallback: CGEventTapCallBack = { _, type, event, userInfo in
        // Re-enable tap if macOS disabled it due to timeout or user input,
        // with a debounce to avoid rapid re-enable cycling.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let userInfo {
                let ctx = Unmanaged<TapContext>.fromOpaque(userInfo).takeUnretainedValue()
                if let machPort = ctx.claimReenablePort(debounce: reenableDebounceInterval) {
                    // Timeout disables mean the system considered us too slow
                    // to service the keystroke path — exactly the signal
                    // behind "typing lags while Voce runs" reports.
                    logger.warning("Event tap disabled by system (\(type == .tapDisabledByTimeout ? "timeout" : "user input", privacy: .public)) — re-enabling")
                    CGEvent.tapEnable(tap: machPort, enable: true)
                }
            }
            return Unmanaged.passUnretained(event)
        }

        guard type == .keyDown, let userInfo else {
            return Unmanaged.passUnretained(event)
        }

        let ctx = Unmanaged<TapContext>.fromOpaque(userInfo).takeUnretainedValue()
        let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        let flags = event.flags
        let userMods: CGEventFlags = [.maskCommand, .maskAlternate, .maskControl, .maskShift]

        if ctx.onCaptureSelectionCorrection != nil,
           matchesSelectionCorrectionHotkey(keyCode: keyCode, flags: flags, shortcut: ctx.selectionCorrectionHotkey),
           event.getIntegerValueField(.keyboardEventAutorepeat) == 0 {
            DispatchQueue.main.async {
                ctx.onCaptureSelectionCorrection?()
            }
            return nil
        }

        if ctx.onCaptureSelectionSnippet != nil,
           matchesSelectionCorrectionHotkey(keyCode: keyCode, flags: flags, shortcut: ctx.selectionSnippetHotkey),
           event.getIntegerValueField(.keyboardEventAutorepeat) == 0 {
            DispatchQueue.main.async {
                ctx.onCaptureSelectionSnippet?()
            }
            return nil
        }

        if ctx.isSubmitEnabled,
           isReturnKeyCode(keyCode),
           flags.intersection(userMods).isEmpty,
           event.getIntegerValueField(.keyboardEventAutorepeat) == 0 {
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    let monitor = ctx.monitor
                    monitor?.markHandledActiveRecordingKey(keyCode)
                }
                ctx.onSubmit?()
            }
            return nil
        }

        if ctx.isAIFinishEnabled,
           flags.intersection(userMods).isEmpty,
           event.getIntegerValueField(.keyboardEventAutorepeat) == 0,
           let matchedHotkey = matchingAIWorkflowHotkey(
                keyCode: keyCode,
                defaultHotkey: ctx.aiFinishHotkey,
                workflowHotkeys: ctx.aiWorkflowFinishHotkeys
           ) {
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    let monitor = ctx.monitor
                    monitor?.markHandledActiveRecordingKey(keyCode)
                }
                ctx.onAIFinish?(matchedHotkey)
            }
            return nil
        }

        guard let configuredHotkey = ctx.hotkey,
              case .keyCode(let targetKey) = configuredHotkey.hotkey,
              keyCode == targetKey,
              flags.intersection(userMods).isEmpty,
              event.getIntegerValueField(.keyboardEventAutorepeat) == 0
        else {
            return Unmanaged.passUnretained(event)
        }

        // Hop to the main queue: handlers are MainActor and this callback
        // runs on the event-tap thread.
        let triggerStyle = configuredHotkey.triggerStyle
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                ctx.monitor?.handleKeyCodeToggleTap(triggerStyle: triggerStyle)
            }
        }
        return nil // For .defaultTap, nil suppresses delivery to downstream apps.
    }

    deinit {
        MainActor.assumeIsolated {
            uninstallEventTap()
            uninstallPressToTalkMonitors()
            uninstallActiveRecordingKeyMonitors()
            // Clear callback state defensively after uninstall.
            tapContext.machPort = nil
            tapContext.onToggle = nil
            tapContext.onSubmit = nil
            tapContext.onAIFinish = nil
            tapContext.onCaptureSelectionCorrection = nil
            tapContext.onCaptureSelectionSnippet = nil
            tapContext.hotkey = nil
            tapContext.aiFinishHotkey = nil
            tapContext.monitor = nil
        }
    }

    private func markHandledActiveRecordingKey(_ keyCode: UInt16) {
        lastActiveRecordingKeyCode = keyCode
        lastActiveRecordingKeyTime = CFAbsoluteTimeGetCurrent()
    }

    private nonisolated static func matchingAIWorkflowHotkey(
        keyCode: UInt16,
        defaultHotkey: HandsFreeHotkey?,
        workflowHotkeys: [HandsFreeHotkey]
    ) -> HandsFreeHotkey? {
        if let matchedCustom = workflowHotkeys.first(where: {
            if case .keyCode(let customKeyCode) = $0 {
                return customKeyCode == keyCode
            }
            return false
        }) {
            return matchedCustom
        }

        if case .keyCode(let aiKeyCode)? = defaultHotkey, aiKeyCode == keyCode {
            return nil
        }

        return nil
    }

    private nonisolated static func matchesSelectionCorrectionHotkey(
        keyCode: UInt16,
        flags: CGEventFlags,
        shortcut: VoceKeyboardShortcut
    ) -> Bool {
        // Empty modifier set is the `disabledSentinel` — guard against falling
        // through to "matches any plain `keyCode` press with no mods", which
        // would fire on every typed `A` (keyCode 0) etc.
        guard shortcut.isBound else { return false }
        let userMods: CGEventFlags = [.maskCommand, .maskAlternate, .maskControl, .maskShift]
        return keyCode == shortcut.keyCode
            && flags.intersection(userMods) == cgFlags(for: shortcut.modifiers)
    }

    private nonisolated static func cgFlags(for modifiers: [VoceKeyboardShortcut.Modifier]) -> CGEventFlags {
        modifiers.reduce(into: CGEventFlags()) { partialResult, modifier in
            partialResult.insert(modifier.cgFlag)
        }
    }

    // MARK: - Utilities

    static func functionKeyName(for keyCode: UInt16) -> String? {
        switch keyCode {
        case 105: return "F13"
        case 107: return "F14"
        case 113: return "F15"
        case 106: return "F16"
        case 64:  return "F17"
        case 79:  return "F18"
        case 80:  return "F19"
        case 90:  return "F20"
        default:  return nil
        }
    }
}

private func isReturnKeyCode(_ keyCode: UInt16) -> Bool {
    keyCode == 36 || keyCode == 76
}
private extension PressToTalkHotkey {
    var eventFlags: NSEvent.ModifierFlags {
        modifiers.reduce(into: NSEvent.ModifierFlags()) { partialResult, modifier in
            partialResult.insert(modifier.eventFlags)
        }
    }
}

private extension PressToTalkHotkey.Modifier {
    var eventFlags: NSEvent.ModifierFlags {
        switch self {
        case .option: return .option
        case .control: return .control
        case .command: return .command
        case .shift: return .shift
        case .function: return .function
        }
    }
}

private extension HandsFreeHotkey.Modifier {
    var eventFlags: NSEvent.ModifierFlags {
        switch self {
        case .option: return .option
        case .control: return .control
        case .command: return .command
        case .shift: return .shift
        case .function: return .function
        }
    }

    var asPressToTalkModifier: PressToTalkHotkey.Modifier {
        switch self {
        case .option: return .option
        case .control: return .control
        case .command: return .command
        case .shift: return .shift
        case .function: return .function
        }
    }
}

private extension VoceKeyboardShortcut.Modifier {
    var cgFlag: CGEventFlags {
        switch self {
        case .control: return .maskControl
        case .option: return .maskAlternate
        case .command: return .maskCommand
        case .shift: return .maskShift
        }
    }
}
#endif
