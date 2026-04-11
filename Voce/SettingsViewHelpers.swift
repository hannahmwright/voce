import AppKit
import SwiftUI
import VoceKit

enum SettingGlyphStyle {
    case holdKey
    case tapKey
}

@MainActor
func settingsCard<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
    VStack(alignment: .leading, spacing: VoceDesign.md) {
        settingTitleRow(title)
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
        settingTitleRow(title, help: subtitle)
        content()
    }
    .cardStyle()
}

@MainActor
func settingsSubcard<Content: View>(
    padding: CGFloat = VoceDesign.md,
    @ViewBuilder content: () -> Content
) -> some View {
    VStack(alignment: .leading, spacing: VoceDesign.sm) {
        content()
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(padding)
    .background {
        RoundedRectangle(cornerRadius: VoceDesign.radiusMedium)
            .fill(VoceDesign.surfaceSecondary)
            .overlay(
                RoundedRectangle(cornerRadius: VoceDesign.radiusMedium)
                    .fill(.regularMaterial.opacity(0.16))
            )
    }
    .overlay(
        RoundedRectangle(cornerRadius: VoceDesign.radiusMedium)
            .stroke(VoceDesign.border, lineWidth: VoceDesign.borderThin)
    )
    .clipShape(RoundedRectangle(cornerRadius: VoceDesign.radiusMedium))
}

@MainActor
func settingTitleRow(_ title: String, help: String? = nil) -> some View {
    HStack(spacing: VoceDesign.xs) {
        Text(title)
            .font(VoceDesign.heading3())
            .foregroundStyle(VoceDesign.textPrimary)
            .accessibilityAddTraits(.isHeader)

        if let help, !help.isEmpty {
            HelpBubbleButton(text: help)
        }

        Spacer(minLength: 0)
    }
}

@MainActor
func settingInlineLabel(
    _ title: String,
    glyphStyle: SettingGlyphStyle? = nil,
    systemImage: String? = nil,
    leadingText: String? = nil,
    help: String? = nil
) -> some View {
    HStack(spacing: VoceDesign.xs) {
        if let glyphStyle {
            SettingGlyph(style: glyphStyle)
        } else if let systemImage, !systemImage.isEmpty {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(VoceDesign.textSecondary)
        } else if let leadingText, !leadingText.isEmpty {
            Text(leadingText)
                .font(VoceDesign.callout())
        }

        Text(title)
            .font(VoceDesign.callout())
            .foregroundStyle(VoceDesign.textPrimary)

        if let help, !help.isEmpty {
            HelpBubbleButton(text: help)
        }

        Spacer(minLength: 0)
    }
}

struct SettingGlyph: View {
    let style: SettingGlyphStyle

    var body: some View {
        ZStack {
            if style == .holdKey {
                RoundedRectangle(cornerRadius: 3.5, style: .continuous)
                    .fill(VoceDesign.textSecondary.opacity(0.78))
                    .frame(width: 13, height: 2.3)
                    .offset(y: -5.6)

                keycapBody(offsetY: 1.7, shadowOpacity: 0.035, topHighlightOpacity: 0.34)
            } else {
                keycapBody(offsetY: 0, shadowOpacity: 0.055, topHighlightOpacity: 0.56)

                RoundedRectangle(cornerRadius: 1.4, style: .continuous)
                    .fill(VoceDesign.textSecondary.opacity(0.88))
                    .frame(width: 5.5, height: 2.6)
                    .offset(y: 0.8)
            }
        }
        .frame(width: 19, height: 19)
        .accessibilityHidden(true)
    }

    private func keycapBody(
        offsetY: CGFloat,
        shadowOpacity: Double,
        topHighlightOpacity: Double
    ) -> some View {
        RoundedRectangle(cornerRadius: 4.5, style: .continuous)
            .fill(VoceDesign.surfaceSecondary)
            .frame(width: 15.5, height: 13.5)
            .overlay(
                RoundedRectangle(cornerRadius: 4.5, style: .continuous)
                    .stroke(VoceDesign.textSecondary.opacity(0.92), lineWidth: 1)
            )
            .overlay(alignment: .top) {
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(.white.opacity(topHighlightOpacity))
                    .frame(width: 10, height: 1.4)
                    .offset(y: 2.2)
            }
            .shadow(color: .black.opacity(shadowOpacity), radius: 1.8, x: 0, y: 1)
            .offset(y: offsetY)
    }
}

@MainActor
func keyboardKeyCap(
    _ title: String,
    systemImage: String? = nil
) -> some View {
    HStack(spacing: 4) {
        if let systemImage {
            Image(systemName: systemImage)
                .font(.system(size: 9, weight: .semibold))
        }

        Text(title)
            .font(VoceDesign.font(size: 11, weight: .semibold))
            .textCase(.uppercase)
    }
    .foregroundStyle(VoceDesign.textPrimary)
    .padding(.horizontal, VoceDesign.sm)
    .padding(.vertical, VoceDesign.xs)
    .background(
        RoundedRectangle(cornerRadius: VoceDesign.radiusSmall - 2, style: .continuous)
            .fill(VoceDesign.surfaceSecondary)
            .overlay(
                RoundedRectangle(cornerRadius: VoceDesign.radiusSmall - 2, style: .continuous)
                    .fill(.regularMaterial.opacity(0.18))
            )
    )
    .overlay(
        RoundedRectangle(cornerRadius: VoceDesign.radiusSmall - 2, style: .continuous)
            .stroke(VoceDesign.border, lineWidth: VoceDesign.borderThin)
    )
    .fixedSize(horizontal: true, vertical: false)
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

@MainActor
func describedPicker<T: Hashable & CaseIterable & RawRepresentable>(
    _ label: String,
    description: String,
    selection: Binding<T>
) -> some View where T.RawValue == String {
    VStack(alignment: .leading, spacing: VoceDesign.xs) {
        settingInlineLabel(label, help: description)

        Picker("", selection: selection) {
            ForEach(Array(T.allCases), id: \.self) { value in
                Text(value.rawValue.capitalized).tag(value)
            }
        }
        .pickerStyle(.menu)
        .labelsHidden()
    }
}

struct HelpBubbleButton: View {
    let text: String
    @State private var isPresented = false

    var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            Image(systemName: "questionmark.circle")
                .font(VoceDesign.label())
                .foregroundStyle(VoceDesign.textSecondary)
        }
        .buttonStyle(.plain)
        .popover(isPresented: $isPresented, arrowEdge: .top) {
            Text(text)
                .font(VoceDesign.caption())
                .foregroundStyle(VoceDesign.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: 220, alignment: .leading)
                .padding(VoceDesign.md)
                .background(VoceDesign.surfaceSolid)
        }
        .accessibilityLabel("More information")
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
                    .textFieldStyle(.plain)
                    .settingsInputChrome()
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

func handsFreeToggleDisplayName(for hotkey: HandsFreeToggleHotkey) -> String {
    switch hotkey.triggerStyle {
    case .singleTap:
        return hotkeyDisplayName(for: hotkey.hotkey)
    case .doubleTap:
        return "\(handsFreeToggleCompactLabel(for: hotkey.hotkey)) x2"
    }
}

func handsFreeToggleCompactLabel(for hotkey: HandsFreeHotkey) -> String {
    switch hotkey {
    case .keyCode(let keyCode):
        return hotkeyDisplayName(for: keyCode)
    case .modifier(let modifier):
        switch modifier {
        case .option:
            return "OPT"
        case .control:
            return "CTRL"
        case .command:
            return "CMD"
        case .shift:
            return "SHIFT"
        case .function:
            return "FN"
        }
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
final class HandsFreeToggleHotkeyCaptureCoordinator: ObservableObject {
    @Published var isCapturing = false
    @Published var helperText: String?

    private var keyMonitor: Any?
    private var flagsMonitor: Any?
    private var resignObserver: NSObjectProtocol?
    private var allowModifierCapture = true
    private var pendingHotkey: HandsFreeHotkey?
    private var pendingCommitTask: Task<Void, Never>?
    private let doubleTapWindowNanoseconds: UInt64 = 350_000_000

    func startCapture(
        allowModifierCapture: Bool = true,
        onCapture: @escaping (HandsFreeToggleHotkey) -> Void
    ) {
        stopCapture(clearHelperText: false)
        isCapturing = true
        self.allowModifierCapture = allowModifierCapture
        helperText = allowModifierCapture
            ? "Press a key or modifier. Tap twice quickly for x2."
            : "Press a single key. Tap twice quickly for x2."

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

        pendingCommitTask?.cancel()
        pendingCommitTask = nil
        pendingHotkey = nil
        isCapturing = false
        if clearHelperText {
            helperText = nil
        }
    }

    private func handleKeyDown(
        _ event: NSEvent,
        onCapture: @escaping (HandsFreeToggleHotkey) -> Void
    ) -> NSEvent? {
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

        capture(.keyCode(UInt16(event.keyCode)), onCapture: onCapture)
        return nil
    }

    private func handleFlagsChanged(
        _ event: NSEvent,
        onCapture: @escaping (HandsFreeToggleHotkey) -> Void
    ) -> NSEvent? {
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

        capture(.modifier(supportedModifiers[0]), onCapture: onCapture)
        return nil
    }

    private func capture(
        _ hotkey: HandsFreeHotkey,
        onCapture: @escaping (HandsFreeToggleHotkey) -> Void
    ) {
        if pendingHotkey == hotkey {
            pendingCommitTask?.cancel()
            pendingCommitTask = nil
            pendingHotkey = nil
            helperText = nil
            onCapture(.init(hotkey: hotkey, triggerStyle: .doubleTap))
            stopCapture(clearHelperText: false)
            return
        }

        pendingCommitTask?.cancel()
        pendingHotkey = hotkey
        helperText = "Press again for \(handsFreeToggleCompactLabel(for: hotkey)) x2."

        pendingCommitTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: self.doubleTapWindowNanoseconds)
            await MainActor.run {
                guard self.isCapturing,
                      self.pendingHotkey == hotkey else {
                    return
                }

                self.pendingHotkey = nil
                self.pendingCommitTask = nil
                self.helperText = nil
                onCapture(.init(hotkey: hotkey, triggerStyle: .singleTap))
                self.stopCapture(clearHelperText: false)
            }
        }
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
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(coordinator.isCapturing ? VoceDesign.accent : VoceDesign.textSecondary)

                        Rectangle()
                            .fill(VoceDesign.border.opacity(0.95))
                            .frame(width: 1, height: 18)

                        Text(fieldTitle)
                            .font(VoceDesign.callout())
                            .foregroundStyle(VoceDesign.textPrimary)

                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, VoceDesign.md)
                    .padding(.vertical, VoceDesign.sm + VoceDesign.xxs)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background {
                        RoundedRectangle(cornerRadius: VoceDesign.radiusSmall, style: .continuous)
                            .fill(Color.white.opacity(0.82))
                            .overlay(
                                RoundedRectangle(cornerRadius: VoceDesign.radiusSmall, style: .continuous)
                                    .fill(.thinMaterial.opacity(0.06))
                            )
                    }
                    .overlay(
                        RoundedRectangle(cornerRadius: VoceDesign.radiusSmall, style: .continuous)
                            .stroke(
                                coordinator.isCapturing ? VoceDesign.accent.opacity(0.6) : VoceDesign.border.opacity(0.95),
                                lineWidth: coordinator.isCapturing ? VoceDesign.borderNormal : VoceDesign.borderThin
                            )
                    )
                    .shadow(color: .black.opacity(0.025), radius: 2, x: 0, y: 1)
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
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(coordinator.isCapturing ? VoceDesign.accent : VoceDesign.textSecondary)

                        Rectangle()
                            .fill(VoceDesign.border.opacity(0.95))
                            .frame(width: 1, height: 18)

                        Text(fieldTitle)
                            .font(VoceDesign.callout())
                            .foregroundStyle(VoceDesign.textPrimary)

                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, VoceDesign.md)
                    .padding(.vertical, VoceDesign.sm + VoceDesign.xxs)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background {
                        RoundedRectangle(cornerRadius: VoceDesign.radiusSmall, style: .continuous)
                            .fill(Color.white.opacity(0.82))
                            .overlay(
                                RoundedRectangle(cornerRadius: VoceDesign.radiusSmall, style: .continuous)
                                    .fill(.thinMaterial.opacity(0.06))
                            )
                    }
                    .overlay(
                        RoundedRectangle(cornerRadius: VoceDesign.radiusSmall, style: .continuous)
                            .stroke(
                                coordinator.isCapturing ? VoceDesign.accent.opacity(0.6) : VoceDesign.border.opacity(0.95),
                                lineWidth: coordinator.isCapturing ? VoceDesign.borderNormal : VoceDesign.borderThin
                            )
                    )
                    .shadow(color: .black.opacity(0.025), radius: 2, x: 0, y: 1)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Global hands-free hotkey")
                .accessibilityValue(fieldTitle)

                Button("Reset") {
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

struct HandsFreeToggleHotkeyRecorderField: View {
    @Binding var hotkey: HandsFreeToggleHotkey?
    var allowModifierCapture: Bool = true
    var autoStartCapture: Bool = false
    @StateObject private var coordinator = HandsFreeToggleHotkeyCaptureCoordinator()
    @State private var didAutoStartCapture = false

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
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(coordinator.isCapturing ? VoceDesign.accent : VoceDesign.textSecondary)

                        Rectangle()
                            .fill(VoceDesign.border.opacity(0.95))
                            .frame(width: 1, height: 18)

                        Text(fieldTitle)
                            .font(VoceDesign.callout())
                            .foregroundStyle(VoceDesign.textPrimary)

                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, VoceDesign.md)
                    .padding(.vertical, VoceDesign.sm + VoceDesign.xxs)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background {
                        RoundedRectangle(cornerRadius: VoceDesign.radiusSmall, style: .continuous)
                            .fill(Color.white.opacity(0.82))
                            .overlay(
                                RoundedRectangle(cornerRadius: VoceDesign.radiusSmall, style: .continuous)
                                    .fill(.thinMaterial.opacity(0.06))
                            )
                    }
                    .overlay(
                        RoundedRectangle(cornerRadius: VoceDesign.radiusSmall, style: .continuous)
                            .stroke(
                                coordinator.isCapturing ? VoceDesign.accent.opacity(0.6) : VoceDesign.border.opacity(0.95),
                                lineWidth: coordinator.isCapturing ? VoceDesign.borderNormal : VoceDesign.borderThin
                            )
                    )
                    .shadow(color: .black.opacity(0.025), radius: 2, x: 0, y: 1)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Global hands-free hotkey")
                .accessibilityValue(fieldTitle)

                Button("Reset") {
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
        .onAppear {
            triggerAutoCaptureIfNeeded()
        }
        .onChange(of: autoStartCapture) { _, _ in
            triggerAutoCaptureIfNeeded()
        }
    }

    private var fieldTitle: String {
        if coordinator.isCapturing {
            return allowModifierCapture ? "Press a key..." : "Press a single key..."
        }

        guard let hotkey else {
            return "Click to record a key"
        }

        return handsFreeToggleDisplayName(for: hotkey)
    }

    private func triggerAutoCaptureIfNeeded() {
        guard autoStartCapture, !didAutoStartCapture, !coordinator.isCapturing else { return }
        didAutoStartCapture = true
        coordinator.startCapture(allowModifierCapture: allowModifierCapture) { capturedHotkey in
            hotkey = capturedHotkey
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
