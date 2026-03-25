#if os(macOS)
import AppKit

/// Shared state between MacHotkeyMonitor and its CGEventTap C callback.
/// All access occurs on the main thread (tap is on the main run loop),
/// but the class must be nonisolated because the C callback is nonisolated.
private final class TapContext: @unchecked Sendable {
    weak var monitor: MacHotkeyMonitor?
    var hotkey: HandsFreeHotkey?
    var onToggle: (() -> Void)?
    var onSubmit: (() -> Void)?
    var aiFinishHotkey: HandsFreeHotkey?
    var aiWorkflowFinishHotkeys: [HandsFreeHotkey] = []
    var onAIFinish: ((HandsFreeHotkey?) -> Void)?
    var isSubmitEnabled = false
    var isAIFinishEnabled = false
    var machPort: CFMachPort?
    /// Monotonic timestamp of the last tap re-enable, used to debounce rapid
    /// disable/re-enable cycles that can occur when the system times out the tap.
    var lastReenableTime: CFAbsoluteTime = 0
}

@MainActor
public final class MacHotkeyMonitor: HotkeyService {
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
    public var onRegistrationStatusChanged: ((HotkeyRegistrationStatus) -> Void)?

    public var isOptionPressToTalkEnabled: Bool = true
    public var pressToTalkHotkey: PressToTalkHotkey = .default {
        didSet {
            isPressToTalkHeld = false
            toggleModifierGate.reset()
            isGlobalToggleModifierHeld = false
        }
    }
    public var globalToggleHotkey: HandsFreeHotkey? = .keyCode(79) {
        didSet {
            tapContext.hotkey = globalToggleHotkey
            toggleModifierGate.reset()
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
    private var isPressToTalkHeld = false
    private var isGlobalToggleModifierHeld = false
    private var toggleModifierGate = HotkeyToggleGate()
    private var callbackGeneration: UInt64 = 0
    private var lastActiveRecordingKeyCode: UInt16?
    private var lastActiveRecordingKeyTime: CFAbsoluteTime = 0

    private var hasStarted = false

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private let tapContext = TapContext()
    public init() {
        tapContext.monitor = self
        tapContext.hotkey = globalToggleHotkey
        tapContext.isSubmitEnabled = isSubmitActiveRecordingEnabled
        tapContext.aiFinishHotkey = aiFinishHotkey
        tapContext.aiWorkflowFinishHotkeys = aiWorkflowFinishHotkeys
        tapContext.isAIFinishEnabled = isAIFinishEnabled
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
        isGlobalToggleModifierHeld = false
        toggleModifierGate.reset()
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
        handlePressToTalkFlagsChanged(modifiers)
        handleModifierToggleFlagsChanged(modifiers)
    }

    private func handlePressToTalkFlagsChanged(_ modifiers: NSEvent.ModifierFlags) {
        guard isOptionPressToTalkEnabled else { return }

        let effectiveModifiers = modifiers.subtracting(.capsLock)
        let hotkeyIsNowHeld = effectiveModifiers == pressToTalkHotkey.eventFlags
        guard hotkeyIsNowHeld != isPressToTalkHeld else { return }

        isPressToTalkHeld = hotkeyIsNowHeld
        let generation = callbackGeneration

        if hotkeyIsNowHeld {
            Task { @MainActor [weak self] in
                guard let self,
                      self.hasStarted,
                      self.callbackGeneration == generation else {
                    return
                }
                self.onPressToTalkStart?()
            }
        } else {
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

    private func handleModifierToggleFlagsChanged(_ modifiers: NSEvent.ModifierFlags) {
        guard case .modifier(let modifier)? = globalToggleHotkey else { return }

        let modifierIsNowHeld = modifiers.contains(modifier.eventFlags)
        guard modifierIsNowHeld != isGlobalToggleModifierHeld else { return }

        isGlobalToggleModifierHeld = modifierIsNowHeld
        let generation = callbackGeneration
        let signal: HotkeySignal = modifierIsNowHeld ? .pressed : .released

        guard toggleModifierGate.consume(signal) else { return }

        Task { @MainActor [weak self] in
            guard let self,
                  self.hasStarted,
                  self.callbackGeneration == generation else {
                return
            }
            self.onToggleHandsFree?()
        }
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
            onRegistrationStatusChanged?(
                .unavailable(reason: "Accessibility permission required for global hotkey.")
            )
            return
        }

        // Keep this assignment immediately after tap creation so callback re-enable
        // logic can always find the live mach port.
        eventTap = tap
        tapContext.machPort = tap

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)

        onRegistrationStatusChanged?(.registered)
    }

    private func uninstallEventTap() {
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            runLoopSource = nil
        }
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
            eventTap = nil
        }
        tapContext.machPort = nil
    }

    private func updateHandsFreeStatus() {
        if isOptionPressToTalkEnabled,
           case .modifier(let modifier)? = globalToggleHotkey,
           pressToTalkHotkey.contains(modifier.asPressToTalkModifier) {
            uninstallEventTap()
            onRegistrationStatusChanged?(
                .unavailable(reason: "Hands-free key can't be part of the hold-to-talk key.")
            )
            return
        }

        if isSubmitActiveRecordingEnabled,
           case .keyCode(let keyCode)? = globalToggleHotkey,
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

                if case .keyCode(let toggleKeyCode)? = globalToggleHotkey, toggleKeyCode == aiKeyCode {
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

        switch globalToggleHotkey {
        case .keyCode?:
            installEventTap()
        case .modifier?:
            if isSubmitActiveRecordingEnabled || isAIFinishEnabled {
                installEventTap()
            } else {
                uninstallEventTap()
                onRegistrationStatusChanged?(.registered)
            }
        case nil:
            if isSubmitActiveRecordingEnabled || isAIFinishEnabled {
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

    /// C-compatible callback for the CGEventTap. Runs on the main thread
    /// (tap is installed on the main run loop). Accesses TapContext via userInfo
    /// to avoid @MainActor isolation issues.
    /// Minimum interval between tap re-enables to prevent rapid disable/enable cycling.
    private static let reenableDebounceInterval: CFAbsoluteTime = 0.1

    private static let eventTapCallback: CGEventTapCallBack = { _, type, event, userInfo in
        // Re-enable tap if macOS disabled it due to timeout or user input,
        // with a debounce to avoid rapid re-enable cycling.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let userInfo {
                let ctx = Unmanaged<TapContext>.fromOpaque(userInfo).takeUnretainedValue()
                let now = CFAbsoluteTimeGetCurrent()
                if let machPort = ctx.machPort,
                   now - ctx.lastReenableTime >= reenableDebounceInterval {
                    ctx.lastReenableTime = now
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

        guard case .keyCode(let targetKey)? = ctx.hotkey,
              keyCode == targetKey,
              flags.intersection(userMods).isEmpty,
              event.getIntegerValueField(.keyboardEventAutorepeat) == 0
        else {
            return Unmanaged.passUnretained(event)
        }

        // Callback already runs on the main run loop; dispatch async to avoid
        // re-entrancy while the tap callback is still unwinding.
        DispatchQueue.main.async { ctx.onToggle?() }
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
            tapContext.hotkey = nil
            tapContext.aiFinishHotkey = nil
            tapContext.monitor = nil
        }
    }

    private func markHandledActiveRecordingKey(_ keyCode: UInt16) {
        lastActiveRecordingKeyCode = keyCode
        lastActiveRecordingKeyTime = CFAbsoluteTimeGetCurrent()
    }

    private static func matchingAIWorkflowHotkey(
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
#endif
