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
    .settingsCardAnchor(title)
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
    .settingsCardAnchor(title)
}

// MARK: - Settings card anchors (search jump target + highlight)

/// Title of the settings card the user just jumped to from search, if any. Cards
/// matching this value briefly glow so the eye lands on the right card after the
/// scroll.
private struct HighlightedSettingsCardKey: EnvironmentKey {
    static let defaultValue: String? = nil
}

extension EnvironmentValues {
    var highlightedSettingsCard: String? {
        get { self[HighlightedSettingsCardKey.self] }
        set { self[HighlightedSettingsCardKey.self] = newValue }
    }
}

/// Tags a settings card with a stable scroll anchor (its title) and renders the
/// brief search-jump highlight. Applied automatically by `settingsCard` and
/// `settingsCardWithSubtitle`; apply manually to custom card containers (the AI
/// section builds its own card). Search result anchors in `SettingsView` must
/// match these titles exactly, or the jump degrades to plain group navigation.
private struct SettingsCardAnchorModifier: ViewModifier {
    let title: String
    @Environment(\.highlightedSettingsCard) private var highlightedCard
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var isHighlighted: Bool { highlightedCard == title }

    func body(content: Content) -> some View {
        content
            .overlay(
                // Matches CardStyle's corner geometry so the glow hugs the card.
                RoundedRectangle(cornerRadius: VoceDesign.radiusMedium)
                    .stroke(VoceDesign.accent.opacity(isHighlighted ? 0.85 : 0), lineWidth: 2)
            )
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.35), value: isHighlighted)
            .id(title)
    }
}

extension View {
    func settingsCardAnchor(_ title: String) -> some View {
        modifier(SettingsCardAnchorModifier(title: title))
    }

    /// Tags an individual settings row as a search jump target. Row anchors are
    /// "\(card) › \(row)" so they can never collide with card anchors. Search
    /// entries with a `parent` in `SettingsView` must match these exactly —
    /// the coverage test in VoceTests cross-checks both directions.
    func settingsRowAnchor(_ card: String, _ row: String) -> some View {
        modifier(SettingsRowAnchorModifier(anchor: "\(card) › \(row)"))
    }
}

/// Row twin of `SettingsCardAnchorModifier`: a scroll `.id` plus a brief
/// highlight wash when the user jumps here from search. Backgrounds are drawn
/// slightly outset (negative padding on the shapes) so the glow hugs the row
/// without changing layout.
private struct SettingsRowAnchorModifier: ViewModifier {
    let anchor: String
    @Environment(\.highlightedSettingsCard) private var highlighted
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var isHighlighted: Bool { highlighted == anchor }

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: VoceDesign.radiusSmall)
                    .fill(VoceDesign.accent.opacity(isHighlighted ? 0.10 : 0))
                    .padding(-VoceDesign.xs)
            )
            .overlay(
                RoundedRectangle(cornerRadius: VoceDesign.radiusSmall)
                    .stroke(VoceDesign.accent.opacity(isHighlighted ? 0.8 : 0), lineWidth: 1.5)
                    .padding(-VoceDesign.xs)
            )
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.35), value: isHighlighted)
            .id(anchor)
    }
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

extension View {
    func settingsModalPanel() -> some View {
        self
            .background(VoceDesign.windowBackground)
            .clipShape(RoundedRectangle(cornerRadius: VoceDesign.radiusLarge, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: VoceDesign.radiusLarge, style: .continuous)
                    .stroke(VoceDesign.border, lineWidth: VoceDesign.borderThin)
            )
            .shadow(color: .black.opacity(0.12), radius: 24, x: 0, y: 12)
    }

    func dismissOnOutsideClick(_ onDismiss: @escaping () -> Void) -> some View {
        background(OutsideClickDismissMonitor(onDismiss: onDismiss))
    }
}

private struct OutsideClickDismissMonitor: NSViewRepresentable {
    let onDismiss: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onDismiss: onDismiss)
    }

    func makeNSView(context: Context) -> NSView {
        let view = OutsideClickDismissView(frame: .zero)
        view.coordinator = context.coordinator
        context.coordinator.attach(to: view)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.onDismiss = onDismiss
        context.coordinator.attach(to: nsView)
    }

    final class Coordinator {
        var onDismiss: () -> Void
        private weak var view: NSView?
        private var windowNumber: Int?
        private var frameInWindow: CGRect = .zero
        private var monitor: Any?

        init(onDismiss: @escaping () -> Void) {
            self.onDismiss = onDismiss
        }

        deinit {
            if let monitor {
                NSEvent.removeMonitor(monitor)
            }
        }

        @MainActor
        func attach(to view: NSView) {
            self.view = view
            refreshGeometry(from: view)
            guard monitor == nil else { return }

            monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
                guard let self,
                      let windowNumber = self.windowNumber,
                      event.windowNumber == windowNumber else {
                    return event
                }

                guard !self.frameInWindow.contains(event.locationInWindow) else {
                    return event
                }

                self.onDismiss()
                return nil
            }
        }

        @MainActor
        func refreshGeometry(from view: NSView) {
            windowNumber = view.window?.windowNumber
            frameInWindow = view.convert(view.bounds, to: nil)
        }
    }

    private final class OutsideClickDismissView: NSView {
        weak var coordinator: Coordinator?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            coordinator?.refreshGeometry(from: self)
        }

        override func layout() {
            super.layout()
            coordinator?.refreshGeometry(from: self)
        }
    }
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

func keyboardShortcutDisplayName(for shortcut: VoceKeyboardShortcut) -> String {
    // The disabled sentinel (empty modifier set) represents an unbound
    // shortcut — historically this fell through to "A" because keyCode 0 is
    // "A". Render it explicitly instead so neither settings rows nor
    // walkthrough copy ever mistakes the dormant state for the literal A key.
    guard shortcut.isBound else { return "Unassigned" }
    let modifierNames = shortcut.modifiers.map(\.displayName)
    return (modifierNames + [hotkeyDisplayName(for: shortcut.keyCode)]).joined(separator: " + ")
}

// MARK: - Preferences draft committing

extension Notification.Name {
    /// Post synchronously on the main thread to push every pending preferences
    /// draft (and a complete Settings email draft) into the controller right
    /// away, e.g. before the app quits. Observers handle it synchronously.
    static let voceFlushPendingPreferenceDrafts = Notification.Name("VoceFlushPendingPreferenceDrafts")
}

/// Moves a view's local `AppPreferences` draft into the controller without
/// doing so on every keystroke.
///
/// Each committed draft normalizes, deep-compares, publishes
/// `controller.preferences` (re-rendering every tab and the menu bar) and
/// writes the whole preferences file, and runtime-relevant edits also rebuild
/// the dictation runtime. Committing on every keystroke in the Scratchpad or a
/// settings text field made typing visibly laggy.
///
/// The first edit after a quiet period commits immediately, so discrete
/// changes (toggles, pickers, recorded hotkeys) still feel instant. Edits that
/// follow within `quietPeriod` are coalesced and committed once the user
/// pauses. Owners call `flush()` when the edit context ends (tab switch, app
/// resign, termination) so nothing is left pending.
///
/// If `controller.preferences` changes from elsewhere while an edit is pending
/// (metrics updated when dictation stops, the other draft in Settings, a
/// dictation into the Scratchpad), `reconcile` merges per top-level field:
/// fields the user edited keep the local value, everything else takes the
/// controller's value. That keeps the ContentView and SettingsView drafts from
/// clobbering each other or the controller's own updates.
@MainActor
final class PreferencesDraftCommitter {
    static let quietPeriod: Duration = .milliseconds(400)

    private weak var controller: DictationController?
    /// The controller value the owning draft was last reconciled with.
    private var base: AppPreferences?
    private var pendingDraft: AppPreferences?
    /// The last draft value fully accounted for: committed, adopted from the
    /// controller, or edited back to it. A draft that differs from this holds
    /// an edit whose onChange hasn't been delivered yet.
    private var settledDraft: AppPreferences?
    private var pendingCommitTask: Task<Void, Never>?
    private var lastEditAt: ContinuousClock.Instant?
    /// Registered on first use rather than in init: SwiftUI re-runs `@State`
    /// initial-value expressions on every parent re-init and discards the
    /// extra instances, which shouldn't each register an observer.
    nonisolated(unsafe) private var flushObserver: NSObjectProtocol?

    deinit {
        if let flushObserver {
            NotificationCenter.default.removeObserver(flushObserver)
        }
    }

    private func observeFlushRequestsIfNeeded() {
        guard flushObserver == nil else { return }
        // queue: nil delivers synchronously on the posting thread, so a flush
        // posted on main has reached the controller by the time post returns.
        flushObserver = NotificationCenter.default.addObserver(
            forName: .voceFlushPendingPreferenceDrafts,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.flush()
            }
        }
    }

    /// Call on appear and whenever `controller.preferences` changes. Returns the
    /// value the draft should hold: the controller's value, or a merge of it
    /// with the pending local edits.
    func reconcile(draft: AppPreferences, with controller: DictationController) -> AppPreferences {
        self.controller = controller
        observeFlushRequestsIfNeeded()
        let remote = controller.preferences
        defer { base = remote }

        // Also merge when an edit landed after the debounced commit cleared
        // `pendingDraft` but before the draft's onChange reported it;
        // returning `remote` then would silently revert that keystroke.
        let hasUnreportedEdit = settledDraft.map { draft != $0 } ?? false
        guard let base, pendingDraft != nil || hasUnreportedEdit else {
            settledDraft = remote
            return remote
        }

        let merged = Self.merge(base: base, local: draft, remote: remote)
        if pendingDraft != nil {
            pendingDraft = merged
        }
        return merged
    }

    /// Call from the draft's `onChange`.
    func draftDidChange(_ draft: AppPreferences, controller: DictationController) {
        self.controller = controller
        observeFlushRequestsIfNeeded()
        if base == nil {
            base = controller.preferences
        }

        guard draft != controller.preferences else {
            // Adopted from the controller, or edited back to the saved value.
            cancelPendingCommit()
            settledDraft = draft
            return
        }

        let now = ContinuousClock.now
        let isWithinEditBurst = pendingDraft != nil
            || lastEditAt.map { now - $0 < Self.quietPeriod } == true
        lastEditAt = now
        pendingDraft = draft

        if isWithinEditBurst {
            scheduleCommit()
        } else {
            commitPendingDraft()
        }
    }

    /// Commits `draft` right away, bypassing the quiet period, for edits that a
    /// following action depends on (e.g. saving the subscriber email before
    /// requesting an access code). The owner should also assign `draft` to its
    /// draft state; the resulting `onChange` then finds nothing left to commit.
    func commitImmediately(_ draft: AppPreferences, controller: DictationController) {
        self.controller = controller
        if base == nil {
            base = controller.preferences
        }
        pendingDraft = draft
        commitPendingDraft()
    }

    /// Commits any pending edit to the controller right away, synchronously.
    /// Also triggered by `.voceFlushPendingPreferenceDrafts`.
    func flush() {
        guard pendingDraft != nil else { return }
        commitPendingDraft()
    }

    private func scheduleCommit() {
        pendingCommitTask?.cancel()
        // Strong capture on purpose: a pending edit must still land if the
        // owning view goes away before the quiet period ends.
        pendingCommitTask = Task { @MainActor in
            try? await Task.sleep(for: Self.quietPeriod)
            guard !Task.isCancelled else { return }
            self.commitPendingDraft()
        }
    }

    private func cancelPendingCommit() {
        pendingCommitTask?.cancel()
        pendingCommitTask = nil
        pendingDraft = nil
    }

    private func commitPendingDraft() {
        guard let draft = pendingDraft, let controller else {
            cancelPendingCommit()
            return
        }
        cancelPendingCommit()
        settledDraft = draft

        let current = controller.preferences
        var snapshot = draft
        if let base, base != current {
            // The controller moved on since the draft was last reconciled and
            // the view hasn't seen it yet; don't overwrite those changes.
            snapshot = Self.merge(base: base, local: draft, remote: current)
        }

        var normalized = snapshot
        normalized.normalize()
        guard normalized != current else {
            base = current
            return
        }

        if normalized.requiresRuntimeRebuild(comparedTo: current) {
            controller.applySettingsDraft(preferences: snapshot, announceImmediateSave: false)
        } else {
            controller.savePreferencesQuietly(preferences: snapshot)
        }
        base = controller.preferences
    }

    /// Three-way merge. Scalar and struct fields merge at top-level field
    /// granularity (the user's edit wins on conflict). Collections the
    /// controller adds to on its own (dictionary corrections and snippets
    /// promoted from a selection or by voice, per-app overrides, bubble
    /// anchors) merge per element, so an addition that lands during an edit
    /// burst isn't dropped. Starts from the local draft so a field this list
    /// doesn't know about keeps the user's value.
    static func merge(
        base: AppPreferences,
        local: AppPreferences,
        remote: AppPreferences
    ) -> AppPreferences {
        var result = local

        func adoptRemoteIfUnedited<Value: Equatable>(_ keyPath: WritableKeyPath<AppPreferences, Value>) {
            if local[keyPath: keyPath] == base[keyPath: keyPath] {
                result[keyPath: keyPath] = remote[keyPath: keyPath]
            }
        }

        // General merges per field: the controller writes showOnboarding
        // (reset/complete onboarding), so a burst of edits to the profile name
        // mustn't write back a stale value for it.
        func adoptRemoteGeneralFieldIfUnedited<Value: Equatable>(_ keyPath: WritableKeyPath<AppPreferences.General, Value>) {
            if local.general[keyPath: keyPath] == base.general[keyPath: keyPath] {
                result.general[keyPath: keyPath] = remote.general[keyPath: keyPath]
            }
        }
        adoptRemoteGeneralFieldIfUnedited(\.launchAtLoginEnabled)
        adoptRemoteGeneralFieldIfUnedited(\.showDockIcon)
        adoptRemoteGeneralFieldIfUnedited(\.showOnboarding)
        adoptRemoteGeneralFieldIfUnedited(\.userName)
        adoptRemoteGeneralFieldIfUnedited(\.appearancePreference)
        adoptRemoteGeneralFieldIfUnedited(\.bubbleAppearance)

        adoptRemoteIfUnedited(\.hotkeys)
        adoptRemoteIfUnedited(\.dictation)
        // Usage counters the controller maintains; no view edits them, so the
        // controller's values always win over a draft's stale copy.
        result.dictation.cloud.directUsagePeriodKey = remote.dictation.cloud.directUsagePeriodKey
        result.dictation.cloud.directUsageSeconds = remote.dictation.cloud.directUsageSeconds
        adoptRemoteIfUnedited(\.insertion)
        adoptRemoteIfUnedited(\.media)
        adoptRemoteIfUnedited(\.ai)
        adoptRemoteIfUnedited(\.billing)
        adoptRemoteIfUnedited(\.globalStyleProfile)

        // LexiconEntry has no ID; an entry's value is its identity.
        result.lexiconEntries = mergeElementsByValue(
            base: base.lexiconEntries,
            local: local.lexiconEntries,
            remote: remote.lexiconEntries
        )
        result.snippets = mergeElements(
            base: base.snippets,
            local: local.snippets,
            remote: remote.snippets,
            id: \.id
        )
        // The controller replaces corrections and snippets with new values or
        // IDs (saving a selection correction, accepting a suggestion), so the
        // element merge can surface both the user's edit and the controller's
        // replacement for the same term or trigger. Keep one.
        result.lexiconEntries = dedupeMergedElements(
            result.lexiconEntries,
            base: base.lexiconEntries,
            local: local.lexiconEntries,
            remote: remote.lexiconEntries,
            key: { TextScopeMergeKey(text: $0.term.lowercased(), scope: $0.scope) }
        )
        result.snippets = dedupeMergedElements(
            result.snippets,
            base: base.snippets,
            local: local.snippets,
            remote: remote.snippets,
            key: { TextScopeMergeKey(text: $0.trigger.lowercased(), scope: $0.scope) }
        )
        result.voiceCommands = mergeElements(
            base: base.voiceCommands,
            local: local.voiceCommands,
            remote: remote.voiceCommands,
            id: \.id
        )
        result.appStyleProfiles = mergeEntries(
            base: base.appStyleProfiles,
            local: local.appStyleProfiles,
            remote: remote.appStyleProfiles
        )
        result.appDictationEnginePreferences = mergeEntries(
            base: base.appDictationEnginePreferences,
            local: local.appDictationEnginePreferences,
            remote: remote.appDictationEnginePreferences
        )
        result.appAnchorOverrides = mergeEntries(
            base: base.appAnchorOverrides,
            local: local.appAnchorOverrides,
            remote: remote.appAnchorOverrides
        )
        adoptRemoteIfUnedited(\.scratchPadContent)
        adoptRemoteIfUnedited(\.metricsRecordingSecondsToday)
        adoptRemoteIfUnedited(\.metricsRecordingSecondsLifetime)
        adoptRemoteIfUnedited(\.metricsLifetimeTrackingStartedAt)
        adoptRemoteIfUnedited(\.metricsLastRecordingDate)
        adoptRemoteIfUnedited(\.metricsBestTypingWordsPerMinute)

        return result
    }

    /// Per-element three-way merge of an ID-keyed array, in local order:
    /// - an element only the user changed (vs. base) keeps the local version,
    ///   otherwise it takes the remote version;
    /// - removed locally (in base, not local): stays removed;
    /// - removed remotely: dropped unless the user edited it;
    /// - added remotely (in neither base nor local): appended.
    /// Duplicate IDs are tolerated: only the first occurrence is merged, later
    /// local duplicates are kept as they are.
    static func mergeElements<Element: Equatable, ID: Hashable>(
        base: [Element],
        local: [Element],
        remote: [Element],
        id: (Element) -> ID
    ) -> [Element] {
        if local == base { return remote }
        if remote == base { return local }

        let baseByID = Dictionary(base.map { (id($0), $0) }, uniquingKeysWith: { first, _ in first })
        let remoteByID = Dictionary(remote.map { (id($0), $0) }, uniquingKeysWith: { first, _ in first })

        var result: [Element] = []
        var seenIDs = Set<ID>()

        for element in local {
            let key = id(element)
            guard seenIDs.insert(key).inserted else {
                result.append(element)
                continue
            }

            switch (baseByID[key], remoteByID[key]) {
            case (nil, _):
                // Added locally (or added on both sides): keep the user's.
                result.append(element)
            case (let baseElement?, nil):
                // Deleted remotely: keep only if the user edited it.
                if element != baseElement {
                    result.append(element)
                }
            case (let baseElement?, let remoteElement?):
                result.append(element != baseElement ? element : remoteElement)
            }
        }

        for element in remote {
            let key = id(element)
            guard baseByID[key] == nil, seenIDs.insert(key).inserted else { continue }
            result.append(element)
        }

        return result
    }

    /// Term/trigger identity used to collapse merge duplicates.
    struct TextScopeMergeKey: Hashable {
        let text: String
        let scopeID: String

        init(text: String, scope: Scope) {
            self.text = text
            switch scope {
            case .global:
                scopeID = "global"
            case .app(let bundleID):
                scopeID = "app:\(bundleID)"
            }
        }
    }

    /// Collapses elements of `merged` that share a key into one, at the first
    /// occurrence's position: the user's edited version (in local, not in
    /// base) if there is one, otherwise the controller's version (in remote,
    /// not in base), otherwise the first. Keys the user's own draft already
    /// duplicated are left alone, so stored data isn't rewritten.
    static func dedupeMergedElements<Element: Equatable, Key: Hashable>(
        _ merged: [Element],
        base: [Element],
        local: [Element],
        remote: [Element],
        key: (Element) -> Key
    ) -> [Element] {
        var localCounts: [Key: Int] = [:]
        for element in local {
            localCounts[key(element), default: 0] += 1
        }
        var mergedCounts: [Key: Int] = [:]
        for element in merged {
            mergedCounts[key(element), default: 0] += 1
        }
        guard mergedCounts.contains(where: { $0.value > 1 && localCounts[$0.key, default: 0] <= 1 }) else {
            return merged
        }

        func rank(_ element: Element) -> Int {
            if local.contains(element) && !base.contains(element) { return 0 }
            if remote.contains(element) && !base.contains(element) { return 1 }
            return 2
        }

        var chosen: [Key: Element] = [:]
        for element in merged {
            let elementKey = key(element)
            guard mergedCounts[elementKey, default: 0] > 1,
                  localCounts[elementKey, default: 0] <= 1 else { continue }
            if let current = chosen[elementKey], rank(current) <= rank(element) {
                continue
            }
            chosen[elementKey] = element
        }

        var emitted = Set<Key>()
        var result: [Element] = []
        for element in merged {
            let elementKey = key(element)
            if let winner = chosen[elementKey] {
                if emitted.insert(elementKey).inserted {
                    result.append(winner)
                }
            } else {
                result.append(element)
            }
        }
        return result
    }

    /// Value-identity variant of `mergeElements` for element types without an
    /// ID: keeps local elements the controller didn't remove and appends the
    /// controller's additions. Removing locally wins over keeping remotely.
    static func mergeElementsByValue<Element: Equatable>(
        base: [Element],
        local: [Element],
        remote: [Element]
    ) -> [Element] {
        if local == base { return remote }
        if remote == base { return local }

        var result = local.filter { element in
            !(base.contains(element) && !remote.contains(element))
        }
        for element in remote where !base.contains(element) && !result.contains(element) {
            result.append(element)
        }
        return result
    }

    /// Per-key three-way merge of a dictionary: a key the user changed (or
    /// removed) keeps the local state, otherwise it takes the remote state.
    static func mergeEntries<Key: Hashable, Value: Equatable>(
        base: [Key: Value],
        local: [Key: Value],
        remote: [Key: Value]
    ) -> [Key: Value] {
        if local == base { return remote }
        if remote == base { return local }

        var result: [Key: Value] = [:]
        for key in Set(base.keys).union(local.keys).union(remote.keys) {
            let value = local[key] != base[key] ? local[key] : remote[key]
            if let value {
                result[key] = value
            }
        }
        return result
    }
}

// MARK: - Tab activity

/// Whether the tab (or settings pane) hosting a view is currently the one the
/// user is looking at. ContentView keeps every tab alive in a ZStack and hides
/// inactive ones with opacity, so `onDisappear` never fires when switching
/// tabs; views that hold global state (key capture monitors, keyboard
/// shortcuts, refresh-on-show work) observe this instead. Defaults to true so
/// views hosted outside ContentView (onboarding, sheets) behave as before.
private struct VoceTabIsActiveKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    var voceTabIsActive: Bool {
        get { self[VoceTabIsActiveKey.self] }
        set { self[VoceTabIsActiveKey.self] = newValue }
    }
}

/// Ends an in-progress hotkey capture when the user leaves the place they
/// started it: the app resigning active, or the window that was key when the
/// capture began resigning key. Without this, a capture started in Settings
/// keeps swallowing key-downs after the user clicks elsewhere, and the next
/// keystroke silently becomes a global hotkey.
@MainActor
final class HotkeyCaptureInterruptionObserver {
    private var tokens: [NSObjectProtocol] = []
    /// Bumped on every install and remove. The interrupt hops through a Task,
    /// so a notification from an earlier capture could otherwise arrive after
    /// a new capture started and stop it.
    private var generation = 0

    func install(onInterrupt: @escaping @MainActor () -> Void) {
        remove()
        let installedGeneration = generation
        let center = NotificationCenter.default
        let handler: @Sendable (Notification) -> Void = { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.generation == installedGeneration else { return }
                onInterrupt()
            }
        }
        tokens.append(center.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil,
            queue: .main,
            using: handler
        ))
        if let keyWindow = NSApp.keyWindow {
            tokens.append(center.addObserver(
                forName: NSWindow.didResignKeyNotification,
                object: keyWindow,
                queue: .main,
                using: handler
            ))
        } else {
            // No key window to watch (`object: nil` would match every
            // window's resign-key). Stop instead when some other window
            // becomes key, treating the main window as the capture's own.
            let captureWindowID = NSApp.mainWindow.map(ObjectIdentifier.init)
            tokens.append(center.addObserver(
                forName: NSWindow.didBecomeKeyNotification,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                let becameKeyID = (notification.object as? NSWindow).map(ObjectIdentifier.init)
                guard captureWindowID == nil || becameKeyID != captureWindowID else { return }
                Task { @MainActor [weak self] in
                    guard let self, self.generation == installedGeneration else { return }
                    onInterrupt()
                }
            })
        }
    }

    func remove() {
        generation &+= 1
        for token in tokens {
            NotificationCenter.default.removeObserver(token)
        }
        tokens.removeAll()
    }
}

/// The event-monitor plumbing every capture coordinator shares: local key-down
/// and flags-changed monitors plus the interruption observer, installed and
/// torn down together. Each coordinator keeps its own capture rules.
@MainActor
final class HotkeyCaptureEventMonitors {
    private var keyMonitor: Any?
    private var flagsMonitor: Any?
    private let interruptionObserver = HotkeyCaptureInterruptionObserver()

    func install(
        keyDown: @escaping (NSEvent) -> NSEvent?,
        flagsChanged: ((NSEvent) -> NSEvent?)? = nil,
        onInterrupt: @escaping @MainActor () -> Void
    ) {
        remove()

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: keyDown)

        if let flagsChanged {
            flagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged, handler: flagsChanged)
        }

        interruptionObserver.install(onInterrupt: onInterrupt)
    }

    func remove() {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }

        if let flagsMonitor {
            NSEvent.removeMonitor(flagsMonitor)
            self.flagsMonitor = nil
        }

        interruptionObserver.remove()
    }
}

@MainActor
final class HotkeyCaptureCoordinator: ObservableObject {
    @Published var isCapturing = false
    @Published var helperText: String?

    private let monitors = HotkeyCaptureEventMonitors()
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

        monitors.install(
            keyDown: { [weak self] event in
                guard let self else { return event }
                return self.handleKeyDown(event, onCapture: onCapture)
            },
            flagsChanged: { [weak self] event in
                guard let self else { return event }
                return self.handleFlagsChanged(event, onCapture: onCapture)
            },
            onInterrupt: { [weak self] in
                self?.stopCapture()
            }
        )
    }

    func stopCapture(clearHelperText: Bool = true) {
        monitors.remove()

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
final class KeyboardShortcutCaptureCoordinator: ObservableObject {
    @Published var isCapturing = false
    @Published var helperText: String?

    private let monitors = HotkeyCaptureEventMonitors()

    func startCapture(onCapture: @escaping (VoceKeyboardShortcut) -> Void) {
        stopCapture(clearHelperText: false)
        isCapturing = true
        helperText = "Press a key combination. Esc cancels."

        monitors.install(
            keyDown: { [weak self] event in
                guard let self else { return event }
                return self.handleKeyDown(event, onCapture: onCapture)
            },
            onInterrupt: { [weak self] in
                self?.stopCapture()
            }
        )
    }

    func stopCapture(clearHelperText: Bool = true) {
        monitors.remove()

        isCapturing = false
        if clearHelperText {
            helperText = nil
        }
    }

    private func handleKeyDown(_ event: NSEvent, onCapture: @escaping (VoceKeyboardShortcut) -> Void) -> NSEvent? {
        guard isCapturing else { return event }

        if event.keyCode == 53 {
            stopCapture()
            return nil
        }

        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let supportedModifiers = VoceKeyboardShortcut.Modifier.allCases.filter { modifiers.contains($0.eventFlags) }
        guard !supportedModifiers.isEmpty else {
            helperText = "Hold at least one modifier with the key."
            return nil
        }

        onCapture(VoceKeyboardShortcut(keyCode: UInt16(event.keyCode), modifiers: supportedModifiers))
        helperText = nil
        stopCapture(clearHelperText: false)
        return nil
    }
}

@MainActor
final class HandsFreeToggleHotkeyCaptureCoordinator: ObservableObject {
    @Published var isCapturing = false
    @Published var helperText: String?

    private let monitors = HotkeyCaptureEventMonitors()
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

        monitors.install(
            keyDown: { [weak self] event in
                guard let self else { return event }
                return self.handleKeyDown(event, onCapture: onCapture)
            },
            flagsChanged: { [weak self] event in
                guard let self else { return event }
                return self.handleFlagsChanged(event, onCapture: onCapture)
            },
            onInterrupt: { [weak self] in
                self?.stopCapture()
            }
        )
    }

    func stopCapture(clearHelperText: Bool = true) {
        monitors.remove()

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

    private let monitors = HotkeyCaptureEventMonitors()
    private var pendingHotkey: PressToTalkHotkey?

    func startCapture(onCapture: @escaping (PressToTalkHotkey) -> Void) {
        stopCapture(clearHelperText: false)
        isCapturing = true
        pendingHotkey = nil
        helperText = "Hold one or more modifier keys together, then release to save. Esc cancels."

        monitors.install(
            keyDown: { [weak self] event in
                guard let self else { return event }
                return self.handleKeyDown(event)
            },
            flagsChanged: { [weak self] event in
                guard let self else { return event }
                return self.handleFlagsChanged(event, onCapture: onCapture)
            },
            onInterrupt: { [weak self] in
                self?.stopCapture()
            }
        )
    }

    func stopCapture(clearHelperText: Bool = true) {
        monitors.remove()

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
                HotkeyRecorderFieldButton(
                    idleSystemImage: "mic.badge.plus",
                    title: fieldTitle,
                    accessibilityLabel: "Hold-to-talk hotkey",
                    isCapturing: coordinator.isCapturing
                ) {
                    if coordinator.isCapturing {
                        coordinator.stopCapture()
                    } else {
                        coordinator.startCapture { capturedHotkey in
                            hotkey = capturedHotkey
                        }
                    }
                }

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
                HotkeyRecorderHelperText(text: helperText)
            }
        }
        .endsHotkeyCaptureWhenHidden {
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
                HotkeyRecorderFieldButton(
                    idleSystemImage: "keyboard",
                    title: fieldTitle,
                    accessibilityLabel: "Global hands-free hotkey",
                    isCapturing: coordinator.isCapturing
                ) {
                    if coordinator.isCapturing {
                        coordinator.stopCapture()
                    } else {
                        coordinator.startCapture(allowModifierCapture: allowModifierCapture) { capturedHotkey in
                            hotkey = capturedHotkey
                        }
                    }
                }

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
                HotkeyRecorderHelperText(text: helperText)
            }
        }
        .endsHotkeyCaptureWhenHidden {
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

struct KeyboardShortcutRecorderField: View {
    @Binding var shortcut: VoceKeyboardShortcut
    let defaultShortcut: VoceKeyboardShortcut
    let accessibilityLabel: String
    @StateObject private var coordinator = KeyboardShortcutCaptureCoordinator()

    var body: some View {
        VStack(alignment: .leading, spacing: VoceDesign.xs) {
            HStack(spacing: VoceDesign.sm) {
                HotkeyRecorderFieldButton(
                    idleSystemImage: "keyboard",
                    title: fieldTitle,
                    accessibilityLabel: accessibilityLabel,
                    isCapturing: coordinator.isCapturing
                ) {
                    if coordinator.isCapturing {
                        coordinator.stopCapture()
                    } else {
                        coordinator.startCapture { capturedShortcut in
                            shortcut = capturedShortcut
                        }
                    }
                }

                Button("Clear") {
                    shortcut = .disabledSentinel
                    coordinator.stopCapture()
                }
                .buttonStyle(.plain)
                .font(VoceDesign.captionEmphasis())
                .foregroundStyle(
                    shortcut.isBound
                    ? VoceDesign.textSecondary
                    : VoceDesign.textSecondary.opacity(0.5)
                )
                .disabled(!shortcut.isBound)
                .help("Disable this direct shortcut. The Voce-actions tap above stays available.")

                Button("Reset") {
                    shortcut = defaultShortcut
                    coordinator.stopCapture()
                }
                .buttonStyle(.plain)
                .font(VoceDesign.captionEmphasis())
                .foregroundStyle(
                    shortcut == defaultShortcut
                    ? VoceDesign.textSecondary.opacity(0.5)
                    : VoceDesign.textSecondary
                )
                .disabled(shortcut == defaultShortcut)
            }

            if let helperText = coordinator.helperText {
                HotkeyRecorderHelperText(text: helperText)
            }
        }
        .endsHotkeyCaptureWhenHidden {
            coordinator.stopCapture()
        }
    }

    private var fieldTitle: String {
        if coordinator.isCapturing {
            return "Press a key combination..."
        }

        return keyboardShortcutDisplayName(for: shortcut)
    }
}

struct HandsFreeToggleHotkeyRecorderField: View {
    @Binding var hotkey: HandsFreeToggleHotkey?
    var allowModifierCapture: Bool = true
    var autoStartCapture: Bool = false
    @StateObject private var coordinator = HandsFreeToggleHotkeyCaptureCoordinator()
    @State private var didAutoStartCapture = false
    @Environment(\.voceTabIsActive) private var tabIsActive

    var body: some View {
        VStack(alignment: .leading, spacing: VoceDesign.xs) {
            HStack(spacing: VoceDesign.sm) {
                HotkeyRecorderFieldButton(
                    idleSystemImage: "keyboard",
                    title: fieldTitle,
                    accessibilityLabel: "Global hands-free hotkey",
                    isCapturing: coordinator.isCapturing
                ) {
                    if coordinator.isCapturing {
                        coordinator.stopCapture()
                    } else {
                        coordinator.startCapture(allowModifierCapture: allowModifierCapture) { capturedHotkey in
                            hotkey = capturedHotkey
                        }
                    }
                }

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
                HotkeyRecorderHelperText(text: helperText)
            }
        }
        .endsHotkeyCaptureWhenHidden {
            coordinator.stopCapture()
        }
        .onAppear {
            triggerAutoCaptureIfNeeded()
        }
        .onChange(of: autoStartCapture) { _, shouldAutoStart in
            if shouldAutoStart {
                triggerAutoCaptureIfNeeded()
            } else {
                // The request was withdrawn (Settings closed or the user moved
                // on); re-arm so the next request starts a capture again.
                didAutoStartCapture = false
            }
        }
        .onChange(of: tabIsActive) { _, isActive in
            if isActive {
                triggerAutoCaptureIfNeeded()
            }
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
        guard autoStartCapture, tabIsActive, !didAutoStartCapture, !coordinator.isCapturing else { return }
        didAutoStartCapture = true
        coordinator.startCapture(allowModifierCapture: allowModifierCapture) { capturedHotkey in
            hotkey = capturedHotkey
        }
    }
}

/// Field chrome shared by the hotkey recorders. Light mode keeps the original
/// near-white key-cap look; dark mode previously drew the same near-white fill
/// under off-white text, leaving the recorded key unreadable, so it now uses
/// the dark input surface `settingsInputChrome()` uses.
private struct HotkeyRecorderChromeModifier: ViewModifier {
    let isCapturing: Bool
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        content
            .background {
                RoundedRectangle(cornerRadius: VoceDesign.radiusSmall, style: .continuous)
                    .fill(colorScheme == .dark ? VoceDesign.surfaceSolid : Color.white.opacity(0.82))
                    .overlay(
                        RoundedRectangle(cornerRadius: VoceDesign.radiusSmall, style: .continuous)
                            .fill(
                                colorScheme == .dark
                                    ? AnyShapeStyle(Color.white.opacity(0.03))
                                    : AnyShapeStyle(.thinMaterial.opacity(0.06))
                            )
                    )
            }
            .overlay(
                RoundedRectangle(cornerRadius: VoceDesign.radiusSmall, style: .continuous)
                    .stroke(
                        isCapturing ? VoceDesign.accent.opacity(0.6) : VoceDesign.border.opacity(0.95),
                        lineWidth: isCapturing ? VoceDesign.borderNormal : VoceDesign.borderThin
                    )
            )
            .shadow(color: .black.opacity(0.025), radius: 2, x: 0, y: 1)
    }
}

private extension View {
    func hotkeyRecorderChrome(isCapturing: Bool) -> some View {
        modifier(HotkeyRecorderChromeModifier(isCapturing: isCapturing))
    }
}

/// The recorder button shared by all hotkey fields: an icon, a divider, the
/// current value (or capture prompt), in the shared recorder chrome.
private struct HotkeyRecorderFieldButton: View {
    let idleSystemImage: String
    let title: String
    let accessibilityLabel: String
    let isCapturing: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: VoceDesign.sm) {
                Image(systemName: isCapturing ? "keyboard.badge.ellipsis" : idleSystemImage)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(isCapturing ? VoceDesign.accent : VoceDesign.textSecondary)

                Rectangle()
                    .fill(VoceDesign.border.opacity(0.95))
                    .frame(width: 1, height: 18)

                Text(title)
                    .font(VoceDesign.callout())
                    .foregroundStyle(VoceDesign.textPrimary)

                Spacer(minLength: 0)
            }
            .padding(.horizontal, VoceDesign.md)
            .padding(.vertical, VoceDesign.sm + VoceDesign.xxs)
            .frame(maxWidth: .infinity, alignment: .leading)
            .hotkeyRecorderChrome(isCapturing: isCapturing)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(title)
    }
}

private struct HotkeyRecorderHelperText: View {
    let text: String

    var body: some View {
        Text(text)
            .font(VoceDesign.caption())
            .foregroundStyle(VoceDesign.textSecondary)
    }
}

/// Ends a capture when the recorder goes away or its tab is hidden. Tabs are
/// hidden rather than removed, so `onDisappear` alone doesn't fire when the
/// user switches away.
private struct EndHotkeyCaptureWhenHiddenModifier: ViewModifier {
    @Environment(\.voceTabIsActive) private var tabIsActive
    let stopCapture: () -> Void

    func body(content: Content) -> some View {
        content
            .onDisappear {
                stopCapture()
            }
            .onChange(of: tabIsActive) { _, isActive in
                if !isActive {
                    stopCapture()
                }
            }
    }
}

private extension View {
    func endsHotkeyCaptureWhenHidden(_ stopCapture: @escaping () -> Void) -> some View {
        modifier(EndHotkeyCaptureWhenHiddenModifier(stopCapture: stopCapture))
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

private extension VoceKeyboardShortcut.Modifier {
    var eventFlags: NSEvent.ModifierFlags {
        switch self {
        case .control: return .control
        case .option: return .option
        case .command: return .command
        case .shift: return .shift
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

// MARK: - App metadata

/// Bundle ID → app URL, name and icon, resolved once per bundle ID.
///
/// Home and the Settings app pickers used to call
/// `NSWorkspace.urlForApplication`, read the app bundle and load its icon from
/// disk for every row on every render — including inside sort comparators and
/// for icons that were hidden until hover. Entries for an app are dropped
/// when it launches or quits (it may have been installed, moved or updated),
/// and "not installed" results expire after a minute.
@MainActor
enum AppMetadataCache {
    private static var urlsByBundleID: [String: URL?] = [:]
    private static var negativeLookupDates: [String: Date] = [:]
    private static var bundleNamesByBundleID: [String: String] = [:]
    private static var fileNamesByBundleID: [String: String] = [:]
    private static var iconsByKey: [String: NSImage?] = [:]
    private static var workspaceObservers: [NSObjectProtocol] = []
    private static let negativeEntryLifetime: TimeInterval = 60

    /// Every other lookup goes through this first, so an expired or
    /// invalidated URL also drops the names and icons derived from it.
    static func applicationURL(for bundleID: String) -> URL? {
        guard !bundleID.isEmpty else { return nil }
        observeWorkspaceIfNeeded()

        if let cached = urlsByBundleID[bundleID] {
            if let url = cached {
                return url
            }
            if let checkedAt = negativeLookupDates[bundleID],
               Date().timeIntervalSince(checkedAt) < negativeEntryLifetime {
                return nil
            }
            invalidate(bundleID)
        }

        let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
        urlsByBundleID[bundleID] = url
        negativeLookupDates[bundleID] = url == nil ? Date() : nil
        return url
    }

    private static func invalidate(_ bundleID: String) {
        urlsByBundleID.removeValue(forKey: bundleID)
        negativeLookupDates.removeValue(forKey: bundleID)
        bundleNamesByBundleID.removeValue(forKey: bundleID)
        fileNamesByBundleID.removeValue(forKey: bundleID)
        let iconKeyPrefix = "\(bundleID)#"
        iconsByKey = iconsByKey.filter { !$0.key.hasPrefix(iconKeyPrefix) }
    }

    private static func invalidateNegativeEntries() {
        for bundleID in Array(negativeLookupDates.keys) {
            invalidate(bundleID)
        }
    }

    private static func observeWorkspaceIfNeeded() {
        guard workspaceObservers.isEmpty else { return }
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            workspaceObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { notification in
                let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                let bundleID = app?.bundleIdentifier
                MainActor.assumeIsolated {
                    if let bundleID {
                        invalidate(bundleID)
                    }
                    invalidateNegativeEntries()
                }
            })
        }
    }

    /// The app's CFBundleName (e.g. "Code"), falling back to the capitalized
    /// last bundle-ID component. Used by the Settings app lists.
    static func bundleName(for bundleID: String) -> String {
        let url = applicationURL(for: bundleID)
        if let cached = bundleNamesByBundleID[bundleID] {
            return cached
        }
        let name: String
        if let url,
           let bundle = Bundle(url: url),
           let bundleName = bundle.object(forInfoDictionaryKey: "CFBundleName") as? String {
            name = bundleName
        } else {
            name = bundleID.components(separatedBy: ".").last?.capitalized ?? bundleID
        }
        bundleNamesByBundleID[bundleID] = name
        return name
    }

    /// The app's file name without extension (e.g. "Visual Studio Code"),
    /// falling back to the last bundle-ID component. Used by Home.
    static func fileName(for bundleID: String) -> String {
        guard !bundleID.isEmpty else { return "Unknown" }
        let url = applicationURL(for: bundleID)
        if let cached = fileNamesByBundleID[bundleID] {
            return cached
        }
        let name: String
        if let url {
            name = url.deletingPathExtension().lastPathComponent
        } else {
            name = bundleID.components(separatedBy: ".").last ?? bundleID
        }
        fileNamesByBundleID[bundleID] = name
        return name
    }

    static func icon(for bundleID: String, size: CGFloat) -> NSImage? {
        let url = applicationURL(for: bundleID)
        let key = "\(bundleID)#\(size)"
        if let cached = iconsByKey[key] {
            return cached
        }
        var icon: NSImage?
        if let url {
            let image = NSWorkspace.shared.icon(forFile: url.path)
            image.size = NSSize(width: size, height: size)
            icon = image
        }
        iconsByKey[key] = icon
        return icon
    }
}

/// App icon as shown in the Settings app lists (Speech overrides, Style
/// overrides, Dictionary scopes), with a symbol fallback for apps that aren't
/// installed.
@MainActor
@ViewBuilder
func settingsAppIconView(for bundleID: String, size: CGFloat = 16) -> some View {
    if let icon = AppMetadataCache.icon(for: bundleID, size: 18) {
        Image(nsImage: icon)
            .resizable()
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: max(4, size * 0.22), style: .continuous))
    } else {
        Image(systemName: "app")
            .font(.system(size: max(11, size * 0.72), weight: .medium))
            .foregroundStyle(VoceDesign.textSecondary.opacity(0.75))
            .frame(width: size, height: size)
    }
}

/// Bundle ID of the most recently active app other than Voce.
///
/// "Use current app" in the per-app override pickers read
/// `NSWorkspace.frontmostApplication`, but Voce is frontmost while the user
/// clicks it, so the picker chose Voce itself. Started from ContentView at
/// launch so the app the user came from is already known.
@MainActor
enum ExternalFrontmostAppTracker {
    private static var lastExternalBundleIDStorage: String?
    private static var activationObserver: NSObjectProtocol?

    static var lastExternalBundleID: String? {
        startIfNeeded()
        return lastExternalBundleIDStorage
    }

    static func startIfNeeded() {
        guard activationObserver == nil else { return }
        record(NSWorkspace.shared.frontmostApplication?.bundleIdentifier)
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { notification in
            let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            let bundleID = app?.bundleIdentifier
            Task { @MainActor in
                record(bundleID)
            }
        }
    }

    private static func record(_ bundleID: String?) {
        guard let bundleID,
              !bundleID.isEmpty,
              bundleID != "unknown",
              bundleID != Bundle.main.bundleIdentifier else {
            return
        }
        lastExternalBundleIDStorage = bundleID
    }
}
