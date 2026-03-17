#if os(macOS)
import AppKit

/// Shared state between MacHotkeyMonitor and its CGEventTap C callback.
/// All access occurs on the main thread (tap is on the main run loop),
/// but the class must be nonisolated because the C callback is nonisolated.
private final class TapContext: @unchecked Sendable {
    var hotkey: HandsFreeHotkey?
    var onToggle: (() -> Void)?
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
    public var onRegistrationStatusChanged: ((HotkeyRegistrationStatus) -> Void)?

    public var isOptionPressToTalkEnabled: Bool = true
    public var pressToTalkModifier: PressToTalkModifier = .option {
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

    private var globalFlagsMonitor: Any?
    private var localFlagsMonitor: Any?
    private var isPressToTalkHeld = false
    private var isGlobalToggleModifierHeld = false
    private var toggleModifierGate = HotkeyToggleGate()
    private var callbackGeneration: UInt64 = 0

    private var hasStarted = false

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private let tapContext = TapContext()
    public init() {
        tapContext.hotkey = globalToggleHotkey
    }

    public func start() {
        guard !hasStarted else { return }
        callbackGeneration &+= 1
        hasStarted = true
        installOptionMonitors()
        updateHandsFreeStatus()
    }

    public func stop() {
        callbackGeneration &+= 1
        hasStarted = false
        uninstallEventTap()
        uninstallOptionMonitors()
        isPressToTalkHeld = false
        isGlobalToggleModifierHeld = false
        toggleModifierGate.reset()
    }

    // MARK: - Press-to-Talk Monitors

    private func installOptionMonitors() {
        guard globalFlagsMonitor == nil, localFlagsMonitor == nil else { return }

        globalFlagsMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handleFlagsChanged(event)
        }

        localFlagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handleFlagsChanged(event)
            return event
        }
    }

    private func uninstallOptionMonitors() {
        if let globalFlagsMonitor {
            NSEvent.removeMonitor(globalFlagsMonitor)
            self.globalFlagsMonitor = nil
        }
        if let localFlagsMonitor {
            NSEvent.removeMonitor(localFlagsMonitor)
            self.localFlagsMonitor = nil
        }
    }

    private func handleFlagsChanged(_ event: NSEvent) {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        handlePressToTalkFlagsChanged(modifiers)
        handleModifierToggleFlagsChanged(modifiers)
    }

    private func handlePressToTalkFlagsChanged(_ modifiers: NSEvent.ModifierFlags) {
        guard isOptionPressToTalkEnabled else { return }

        let modifierIsNowHeld = modifiers.contains(pressToTalkModifier.eventFlags)
        guard modifierIsNowHeld != isPressToTalkHeld else { return }

        isPressToTalkHeld = modifierIsNowHeld
        let generation = callbackGeneration

        if modifierIsNowHeld {
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
        guard let globalToggleHotkey else {
            uninstallEventTap()
            onRegistrationStatusChanged?(
                .unavailable(reason: "Global hands-free key disabled in settings.")
            )
            return
        }

        if isOptionPressToTalkEnabled,
           case .modifier(let modifier) = globalToggleHotkey,
           modifier.eventFlags == pressToTalkModifier.eventFlags {
            uninstallEventTap()
            onRegistrationStatusChanged?(
                .unavailable(reason: "Hands-free key can't match the hold-to-talk key.")
            )
            return
        }

        switch globalToggleHotkey {
        case .keyCode:
            installEventTap()
        case .modifier:
            uninstallEventTap()
            onRegistrationStatusChanged?(.registered)
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
            uninstallOptionMonitors()
            // Clear callback state defensively after uninstall.
            tapContext.machPort = nil
            tapContext.onToggle = nil
            tapContext.hotkey = nil
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
private extension PressToTalkModifier {
    var eventFlags: NSEvent.ModifierFlags {
        switch self {
        case .option: return .option
        case .control: return .control
        case .command: return .command
        case .shift: return .shift
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
}
#endif
