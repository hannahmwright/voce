import AppKit
import SwiftUI
import VoceKit

@MainActor
func settingsCard<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
    VStack(alignment: .leading, spacing: VoceDesign.md) {
        Text(title)
            .font(VoceDesign.heading3())
            .foregroundStyle(VoceDesign.textPrimary)
            .accessibilityAddTraits(.isHeader)
        content()
    }
    .cardStyle()
}

@MainActor
func settingsCardWithSubtitle<Content: View>(
    _ title: String,
    subtitle: String,
    @ViewBuilder content: () -> Content
) -> some View {
    VStack(alignment: .leading, spacing: VoceDesign.md) {
        VStack(alignment: .leading, spacing: VoceDesign.xs) {
            Text(title)
                .font(VoceDesign.heading3())
                .foregroundStyle(VoceDesign.textPrimary)
                .accessibilityAddTraits(.isHeader)
            Text(subtitle)
                .font(VoceDesign.subheadline())
                .foregroundStyle(VoceDesign.textSecondary)
        }
        content()
    }
    .cardStyle()
}

@MainActor
func entryRow(
    leading: String,
    trailing: String? = nil,
    scope: Scope? = nil,
    onRemove: @escaping () -> Void
) -> some View {
    HStack(spacing: VoceDesign.sm) {
        Text(leading)
            .font(VoceDesign.callout())
            .lineLimit(1)
        Spacer()
        if let trailing = trailing {
            Text(trailing)
                .font(VoceDesign.caption())
                .foregroundStyle(VoceDesign.textSecondary)
        }
        if let scope = scope {
            scopeBadge(scope)
        }
        Button("Remove", role: .destructive, action: onRemove)
            .buttonStyle(.link)
            .accessibilityLabel("Remove entry")
            .accessibilityValue(leading)
    }
    .padding(.vertical, VoceDesign.xs)
    .padding(.horizontal, VoceDesign.sm)
    .background(VoceDesign.surfaceSecondary)
    .clipShape(RoundedRectangle(cornerRadius: VoceDesign.radiusSmall))
}

func scopeBadge(_ scope: Scope) -> some View {
    Text(scopeLabel(scope))
        .font(VoceDesign.label())
        .padding(.horizontal, VoceDesign.sm)
        .padding(.vertical, VoceDesign.xxs)
        .background(VoceDesign.accent.opacity(VoceDesign.opacitySubtle))
        .foregroundStyle(VoceDesign.accent)
        .clipShape(Capsule())
}

func scopeLabel(_ scope: Scope) -> String {
    switch scope {
    case .global:
        return "Global"
    case .app(let bundleID):
        return bundleID
    }
}

func describedPicker<T: Hashable & CaseIterable & RawRepresentable>(
    _ label: String,
    description: String,
    selection: Binding<T>
) -> some View where T.RawValue == String {
    VStack(alignment: .leading, spacing: VoceDesign.xxs) {
        Picker(label, selection: selection) {
            ForEach(Array(T.allCases), id: \.self) { value in
                Text(value.rawValue.capitalized).tag(value)
            }
        }
        .pickerStyle(.menu)

        Text(description)
            .font(VoceDesign.caption())
            .foregroundStyle(VoceDesign.textSecondary)
            .padding(.leading, VoceDesign.xxs)
    }
}

func enumPicker<T: Hashable & CaseIterable & RawRepresentable>(
    _ label: String,
    selection: Binding<T>
) -> some View where T.RawValue == String {
    Picker(label, selection: selection) {
        ForEach(Array(T.allCases), id: \.self) { value in
            Text(value.rawValue.capitalized).tag(value)
        }
    }
    .pickerStyle(.menu)
}

struct ScopePickerRow: View {
    @Binding var isGlobal: Bool
    @Binding var bundleID: String

    var body: some View {
        HStack {
            Toggle("All apps", isOn: $isGlobal)
                .fixedSize()
            if !isGlobal {
                TextField("Bundle ID", text: $bundleID)
                    .textFieldStyle(.roundedBorder)
            }
        }
    }
}

func hotkeyDisplayName(for keyCode: UInt16) -> String {
    switch keyCode {
    case 0: return "A"
    case 1: return "S"
    case 2: return "D"
    case 3: return "F"
    case 4: return "H"
    case 5: return "G"
    case 6: return "Z"
    case 7: return "X"
    case 8: return "C"
    case 9: return "V"
    case 11: return "B"
    case 12: return "Q"
    case 13: return "W"
    case 14: return "E"
    case 15: return "R"
    case 16: return "Y"
    case 17: return "T"
    case 18: return "1"
    case 19: return "2"
    case 20: return "3"
    case 21: return "4"
    case 22: return "6"
    case 23: return "5"
    case 24: return "="
    case 25: return "9"
    case 26: return "7"
    case 27: return "-"
    case 28: return "8"
    case 29: return "0"
    case 30: return "]"
    case 31: return "O"
    case 32: return "U"
    case 33: return "["
    case 34: return "I"
    case 35: return "P"
    case 37: return "L"
    case 38: return "J"
    case 39: return "'"
    case 40: return "K"
    case 41: return ";"
    case 42: return "\\"
    case 43: return ","
    case 44: return "/"
    case 45: return "N"
    case 46: return "M"
    case 47: return "."
    case 50: return "`"
    case 36: return "Return"
    case 48: return "Tab"
    case 49: return "Space"
    case 51: return "Delete"
    case 53: return "Escape"
    case 115: return "Home"
    case 116: return "Page Up"
    case 117: return "Forward Delete"
    case 118: return "F4"
    case 119: return "End"
    case 120: return "F2"
    case 121: return "Page Down"
    case 122: return "F1"
    case 123: return "Left Arrow"
    case 124: return "Right Arrow"
    case 125: return "Down Arrow"
    case 126: return "Up Arrow"
    case 96: return "F5"
    case 97: return "F6"
    case 98: return "F7"
    case 99: return "F3"
    case 100: return "F8"
    case 101: return "F9"
    case 103: return "F11"
    case 105: return "F13"
    case 106: return "F16"
    case 107: return "F14"
    case 109: return "F10"
    case 111: return "F12"
    case 113: return "F15"
    case 64: return "F17"
    case 79: return "F18"
    case 80: return "F19"
    case 90: return "F20"
    default: return "Key \(keyCode)"
    }
}

func hotkeyDisplayName(for hotkey: HandsFreeHotkey) -> String {
    switch hotkey {
    case .keyCode(let keyCode):
        return hotkeyDisplayName(for: keyCode)
    case .modifier(let modifier):
        return modifier.displayName
    }
}

func hotkeyDisplayName(for hotkey: PressToTalkHotkey) -> String {
    hotkey.displayName
}

@MainActor
final class HotkeyCaptureCoordinator: ObservableObject {
    @Published var isCapturing = false
    @Published var helperText: String?

    private var keyMonitor: Any?
    private var flagsMonitor: Any?
    private var resignObserver: NSObjectProtocol?
    private var allowModifierCapture = true

    func startCapture(
        allowModifierCapture: Bool = true,
        onCapture: @escaping (HandsFreeHotkey) -> Void
    ) {
        stopCapture(clearHelperText: false)
        isCapturing = true
        self.allowModifierCapture = allowModifierCapture
        helperText = allowModifierCapture
            ? "Press a single key or modifier. Esc cancels."
            : "Press a single key. Esc cancels."

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            return self.handleKeyDown(event, onCapture: onCapture)
        }

        flagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            guard let self else { return event }
            return self.handleFlagsChanged(event, onCapture: onCapture)
        }

        resignObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.stopCapture()
            }
        }
    }

    func stopCapture(clearHelperText: Bool = true) {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }

        if let flagsMonitor {
            NSEvent.removeMonitor(flagsMonitor)
            self.flagsMonitor = nil
        }

        if let resignObserver {
            NotificationCenter.default.removeObserver(resignObserver)
            self.resignObserver = nil
        }

        isCapturing = false
        if clearHelperText {
            helperText = nil
        }
    }

    private func handleKeyDown(_ event: NSEvent, onCapture: @escaping (HandsFreeHotkey) -> Void) -> NSEvent? {
        guard isCapturing else { return event }

        if event.keyCode == 53 {
            stopCapture()
            return nil
        }

        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var unsupportedModifiers = modifiers
        unsupportedModifiers.remove(.capsLock)
        unsupportedModifiers.remove(.function)

        if !unsupportedModifiers.isEmpty {
            helperText = "Key combinations aren't supported yet. Press one key or one modifier."
            return nil
        }

        onCapture(.keyCode(UInt16(event.keyCode)))
        helperText = nil
        stopCapture(clearHelperText: false)
        return nil
    }

    private func handleFlagsChanged(_ event: NSEvent, onCapture: @escaping (HandsFreeHotkey) -> Void) -> NSEvent? {
        guard isCapturing else { return event }

        if event.keyCode == 53 {
            stopCapture()
            return nil
        }

        if !allowModifierCapture {
            helperText = "Modifier-only keys aren't supported here. Press a single key."
            return nil
        }

        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let supportedModifiers = HandsFreeHotkey.Modifier.allCases.filter { modifiers.contains($0.eventFlags) }

        guard !supportedModifiers.isEmpty else {
            return event
        }

        let effectiveModifiers = modifiers.subtracting(.capsLock)

        guard supportedModifiers.count == 1,
              effectiveModifiers == supportedModifiers[0].eventFlags else {
            helperText = "Key combinations aren't supported yet. Press one key or one modifier."
            return nil
        }

        onCapture(.modifier(supportedModifiers[0]))
        helperText = nil
        stopCapture(clearHelperText: false)
        return nil
    }
}

@MainActor
final class PressToTalkHotkeyCaptureCoordinator: ObservableObject {
    @Published var isCapturing = false
    @Published var helperText: String?

    private var keyMonitor: Any?
    private var flagsMonitor: Any?
    private var resignObserver: NSObjectProtocol?
    private var pendingHotkey: PressToTalkHotkey?

    func startCapture(onCapture: @escaping (PressToTalkHotkey) -> Void) {
        stopCapture(clearHelperText: false)
        isCapturing = true
        pendingHotkey = nil
        helperText = "Hold one or more modifier keys together, then release to save. Esc cancels."

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            return self.handleKeyDown(event)
        }

        flagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            guard let self else { return event }
            return self.handleFlagsChanged(event, onCapture: onCapture)
        }

        resignObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.stopCapture()
            }
        }
    }

    func stopCapture(clearHelperText: Bool = true) {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }

        if let flagsMonitor {
            NSEvent.removeMonitor(flagsMonitor)
            self.flagsMonitor = nil
        }

        if let resignObserver {
            NotificationCenter.default.removeObserver(resignObserver)
            self.resignObserver = nil
        }

        pendingHotkey = nil
        isCapturing = false
        if clearHelperText {
            helperText = nil
        }
    }

    private func handleKeyDown(_ event: NSEvent) -> NSEvent? {
        guard isCapturing else { return event }

        if event.keyCode == 53 {
            stopCapture()
            return nil
        }

        helperText = "Use modifier keys only for hold-to-talk, like Control+Option."
        return nil
    }

    private func handleFlagsChanged(_ event: NSEvent, onCapture: @escaping (PressToTalkHotkey) -> Void) -> NSEvent? {
        guard isCapturing else { return event }

        let modifiers = event.modifierFlags
            .intersection(.deviceIndependentFlagsMask)
            .subtracting(.capsLock)
        let supportedModifiers = PressToTalkHotkey.Modifier.allCases.filter { modifiers.contains($0.eventFlags) }

        guard !supportedModifiers.isEmpty else {
            if let pendingHotkey {
                onCapture(pendingHotkey)
                helperText = nil
                stopCapture(clearHelperText: false)
                return nil
            }
            return event
        }

        let capturedHotkey = PressToTalkHotkey(modifiers: supportedModifiers)
        if let pendingHotkey, pendingHotkey.modifiers.count > capturedHotkey.modifiers.count {
            helperText = "Release to save \(pendingHotkey.displayName)."
            return nil
        }

        pendingHotkey = capturedHotkey
        helperText = "Release to save \(capturedHotkey.displayName)."
        return nil
    }
}

struct PressToTalkHotkeyRecorderField: View {
    @Binding var hotkey: PressToTalkHotkey
    @StateObject private var coordinator = PressToTalkHotkeyCaptureCoordinator()

    var body: some View {
        VStack(alignment: .leading, spacing: VoceDesign.xs) {
            HStack(spacing: VoceDesign.sm) {
                Button {
                    if coordinator.isCapturing {
                        coordinator.stopCapture()
                    } else {
                        coordinator.startCapture { capturedHotkey in
                            hotkey = capturedHotkey
                        }
                    }
                } label: {
                    HStack(spacing: VoceDesign.sm) {
                        Image(systemName: coordinator.isCapturing ? "keyboard.badge.ellipsis" : "mic.badge.plus")
                            .foregroundStyle(coordinator.isCapturing ? VoceDesign.accent : VoceDesign.textSecondary)

                        Text(fieldTitle)
                            .font(VoceDesign.callout())
                            .foregroundStyle(coordinator.isCapturing ? VoceDesign.textPrimary : VoceDesign.textSecondary)

                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, VoceDesign.md)
                    .padding(.vertical, VoceDesign.sm + VoceDesign.xxs)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background {
                        RoundedRectangle(cornerRadius: VoceDesign.radiusSmall, style: .continuous)
                            .fill(VoceDesign.surfaceSecondary)
                            .overlay(
                                RoundedRectangle(cornerRadius: VoceDesign.radiusSmall, style: .continuous)
                                    .fill(.regularMaterial.opacity(0.28))
                            )
                    }
                    .overlay(
                        RoundedRectangle(cornerRadius: VoceDesign.radiusSmall, style: .continuous)
                            .stroke(
                                coordinator.isCapturing ? VoceDesign.accent.opacity(0.45) : VoceDesign.border,
                                lineWidth: VoceDesign.borderThin
                            )
                    )
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Hold-to-talk hotkey")
                .accessibilityValue(fieldTitle)

                Button("Reset") {
                    hotkey = .default
                    coordinator.stopCapture()
                }
                .buttonStyle(.plain)
                .font(VoceDesign.captionEmphasis())
                .foregroundStyle(
                    hotkey == .default
                    ? VoceDesign.textSecondary.opacity(0.5)
                    : VoceDesign.textSecondary
                )
                .disabled(hotkey == .default)
            }

            if let helperText = coordinator.helperText {
                Text(helperText)
                    .font(VoceDesign.caption())
                    .foregroundStyle(VoceDesign.textSecondary)
            }
        }
        .onDisappear {
            coordinator.stopCapture()
        }
    }

    private var fieldTitle: String {
        if coordinator.isCapturing {
            return "Hold modifier keys..."
        }

        return hotkeyDisplayName(for: hotkey)
    }
}

struct HotkeyRecorderField: View {
    @Binding var hotkey: HandsFreeHotkey?
    var allowModifierCapture: Bool = true
    @StateObject private var coordinator = HotkeyCaptureCoordinator()

    var body: some View {
        VStack(alignment: .leading, spacing: VoceDesign.xs) {
            HStack(spacing: VoceDesign.sm) {
                Button {
                    if coordinator.isCapturing {
                        coordinator.stopCapture()
                    } else {
                        coordinator.startCapture(allowModifierCapture: allowModifierCapture) { capturedHotkey in
                            hotkey = capturedHotkey
                        }
                    }
                } label: {
                    HStack(spacing: VoceDesign.sm) {
                        Image(systemName: coordinator.isCapturing ? "keyboard.badge.ellipsis" : "keyboard")
                            .foregroundStyle(coordinator.isCapturing ? VoceDesign.accent : VoceDesign.textSecondary)

                        Text(fieldTitle)
                            .font(VoceDesign.callout())
                            .foregroundStyle(coordinator.isCapturing ? VoceDesign.textPrimary : VoceDesign.textSecondary)

                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, VoceDesign.md)
                    .padding(.vertical, VoceDesign.sm + VoceDesign.xxs)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background {
                        RoundedRectangle(cornerRadius: VoceDesign.radiusSmall, style: .continuous)
                            .fill(VoceDesign.surfaceSecondary)
                            .overlay(
                                RoundedRectangle(cornerRadius: VoceDesign.radiusSmall, style: .continuous)
                                    .fill(.regularMaterial.opacity(0.28))
                            )
                    }
                    .overlay(
                        RoundedRectangle(cornerRadius: VoceDesign.radiusSmall, style: .continuous)
                            .stroke(
                                coordinator.isCapturing ? VoceDesign.accent.opacity(0.45) : VoceDesign.border,
                                lineWidth: VoceDesign.borderThin
                            )
                    )
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Global hands-free hotkey")
                .accessibilityValue(fieldTitle)

                Button("Clear") {
                    hotkey = nil
                    coordinator.stopCapture()
                }
                .buttonStyle(.plain)
                .font(VoceDesign.captionEmphasis())
                .foregroundStyle(hotkey == nil ? VoceDesign.textSecondary.opacity(0.5) : VoceDesign.textSecondary)
                .disabled(hotkey == nil)
            }

            if let helperText = coordinator.helperText {
                Text(helperText)
                    .font(VoceDesign.caption())
                    .foregroundStyle(VoceDesign.textSecondary)
            }
        }
        .onDisappear {
            coordinator.stopCapture()
        }
    }

    private var fieldTitle: String {
        if coordinator.isCapturing {
            return allowModifierCapture ? "Press a key..." : "Press a single key..."
        }

        guard let hotkey else {
            return "Click to record a key"
        }

        return hotkeyDisplayName(for: hotkey)
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
