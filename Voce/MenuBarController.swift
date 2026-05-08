import AppKit
import SwiftUI

@MainActor
private final class VoceBubblePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class MenuBarController: NSObject, NSPopoverDelegate {
    private var statusItem: NSStatusItem?
    private weak var controller: DictationController?
    private let popover = NSPopover()
    private lazy var statusContextMenu = makeStatusContextMenu()
    private let statusSymbolConfiguration = NSImage.SymbolConfiguration(pointSize: 14, weight: .semibold)
    private var localEventMonitor: Any?
    private var globalEventMonitor: Any?

    /// Free-floating panel that hosts the action picker, dictionary-fix, and
    /// snippet-creation surfaces. We use an NSPanel rather than the shared
    /// popover so these surfaces can appear at the dictation-bubble location
    /// (bottom-center of the focused screen) instead of being anchored to a
    /// Voce window the user often isn't looking at.
    private var bubblePanel: NSPanel?
    private var bubblePanelLocalMonitor: Any?
    private var bubblePanelGlobalMonitor: Any?

    func setup(controller: DictationController) {
        self.controller = controller
        configureDefaultPopover(controller: controller)

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.image = statusImage(symbolName: "mic", description: "Voce")
            button.target = self
            button.action = #selector(statusBarButtonClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        statusItem = item
    }

    func updateIcon(isRecording: Bool, handsFreeOn: Bool) {
        guard let button = statusItem?.button else { return }

        let symbolName: String
        if isRecording {
            symbolName = "waveform"
        } else if handsFreeOn {
            symbolName = "mic.fill"
        } else {
            symbolName = "mic"
        }

        let description = isRecording ? "Voce recording" : (handsFreeOn ? "Voce hands-free" : "Voce")
        button.image = statusImage(symbolName: symbolName, description: description)
    }

    private func statusImage(symbolName: String, description: String) -> NSImage? {
        let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: description)?
            .withSymbolConfiguration(statusSymbolConfiguration)
        image?.isTemplate = true
        return image
    }

    @objc private func statusBarButtonClicked(_ sender: NSStatusBarButton) {
        if NSApp.currentEvent?.type == .rightMouseUp {
            showStatusContextMenu(relativeTo: sender)
            return
        }

        togglePopover(relativeTo: sender)
    }

    private func makeStatusContextMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false

        let openItem = NSMenuItem(title: "Open Voce", action: #selector(showWindowAction), keyEquivalent: "")
        openItem.target = self
        menu.addItem(openItem)

        let updatesItem = NSMenuItem(title: "Check for Updates…", action: #selector(checkForUpdatesAction), keyEquivalent: "")
        updatesItem.target = self
        menu.addItem(updatesItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Force Quit Voce", action: #selector(forceQuitAction), keyEquivalent: "")
        quitItem.target = self
        menu.addItem(quitItem)

        return menu
    }

    private func showStatusContextMenu(relativeTo button: NSStatusBarButton) {
        closePopover()
        statusContextMenu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.minY), in: button)
    }

    private func showWindow() {
        if #available(macOS 14.0, *) {
            NSApp.activate()
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }

        if let appDelegate = NSApp.delegate as? AppDelegate {
            appDelegate.showPrimaryWindow()
        } else {
            let primaryWindow = NSApp.windows
                .first { !($0 is NSPanel) && $0.title == "Voce" }
            primaryWindow?.makeKeyAndOrderFront(nil)
        }
    }

    private func configureDefaultPopover(controller: DictationController) {
        popover.delegate = self
        popover.behavior = .transient
        popover.animates = true
        popover.contentSize = NSSize(width: 320, height: 310)
        popover.contentViewController = NSHostingController(
            rootView: MenuBarPopoverView(
                controller: controller,
                onOpenVoce: { [weak self] in self?.handleOpenVoce() },
                onCopyLastDictation: { [weak self] in self?.handleCopyLastDictation() },
                onCreateSnippet: { [weak self] in self?.handleCreateSnippet() },
                onCreateDictionaryItem: { [weak self] in self?.handleCreateDictionaryItem() },
                onToggleTranscription: { [weak self] in self?.handleToggleTranscription() }
            )
        )
    }

    func showSelectionCorrection(
        term: String,
        sourceAppName: String?,
        onSave: @escaping (String) -> Void
    ) {
        guard let controller else { return }

        presentBubblePanel(
            size: NSSize(width: 360, height: 292),
            rootView: SelectionCorrectionPopoverView(
                term: term,
                sourceAppName: sourceAppName,
                appearancePreference: controller.preferences.general.appearancePreference,
                onCancel: { [weak self] in
                    self?.closeBubblePanel()
                },
                onSave: { [weak self] replacement in
                    self?.closeBubblePanel()
                    onSave(replacement)
                }
            )
        )
    }

    func showSelectionSnippet(
        expansion: String,
        onSave: @escaping (String) -> Void
    ) {
        guard let controller else { return }

        presentBubblePanel(
            size: NSSize(width: 360, height: 300),
            rootView: SelectionSnippetPopoverView(
                expansion: expansion,
                appearancePreference: controller.preferences.general.appearancePreference,
                onCancel: { [weak self] in
                    self?.closeBubblePanel()
                },
                onSave: { [weak self] trigger in
                    self?.closeBubblePanel()
                    onSave(trigger)
                }
            )
        )
    }

    /// Surface the action picker after the user taps Cmd+Option. The selected
    /// text has already been captured (we have to capture before showing the
    /// surface, otherwise our window steals focus and the host app's selection
    /// is no longer copyable). The picker's job is to disambiguate intent —
    /// dictionary fix vs snippet creation — and then route to the matching
    /// follow-up surface (correction or snippet).
    ///
    /// All three surfaces are rendered in the same free-floating NSPanel at
    /// the dictation-bubble's home position (bottom-center of the focused
    /// screen), so the user sees them where they're already looking — not
    /// anchored to a Voce window in the background.
    func showVoceActionPicker(
        selection: String,
        sourceAppName: String?,
        onPick: @escaping (VoceAction) -> Void
    ) {
        guard let controller else { return }

        presentBubblePanel(
            size: NSSize(width: 360, height: 320),
            rootView: VoceActionPickerView(
                selection: selection,
                sourceAppName: sourceAppName,
                appearancePreference: controller.preferences.general.appearancePreference,
                onCancel: { [weak self] in
                    self?.closeBubblePanel()
                },
                onPick: { [weak self] action in
                    self?.closeBubblePanel()
                    onPick(action)
                }
            )
        )
    }

    /// Builds and shows a free-floating NSPanel at the dictation-bubble's
    /// home position. Used by all three Voce-action surfaces (picker,
    /// correction, snippet).
    private func presentBubblePanel<Content: View>(
        size: NSSize,
        rootView: Content
    ) {
        if popover.isShown {
            popover.performClose(nil)
        }
        closeBubblePanel()

        let panel = VoceBubblePanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = false
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]

        let hosting = NSHostingView(rootView: rootView)
        hosting.frame = NSRect(origin: .zero, size: size)
        hosting.autoresizingMask = [.width, .height]
        panel.contentView = hosting

        panel.setFrameOrigin(bubblePanelOrigin(for: size))
        panel.orderFrontRegardless()
        panel.makeKey()
        panel.makeFirstResponder(hosting)

        bubblePanel = panel
        installBubblePanelOutsideMonitors()
    }

    /// Computes the panel's origin to mirror the dictation bubble's default
    /// resting position — bottom-center of the screen the user is looking at.
    /// Multi-display setups land the panel on the display that contains the
    /// cursor.
    private func bubblePanelOrigin(for size: NSSize) -> NSPoint {
        let mouseLocation = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouseLocation, $0.frame, false) }
            ?? NSScreen.main
            ?? NSScreen.screens.first

        guard let screen else { return .zero }
        let visibleFrame = screen.visibleFrame
        let margin: CGFloat = 12
        let unclampedX = visibleFrame.origin.x + (visibleFrame.width - size.width) / 2
        let unclampedY = visibleFrame.origin.y + margin
        let x = min(
            max(unclampedX, visibleFrame.minX + margin),
            visibleFrame.maxX - size.width - margin
        )
        let y = min(
            max(unclampedY, visibleFrame.minY + margin),
            visibleFrame.maxY - size.height - margin
        )
        return NSPoint(x: x, y: y)
    }

    private func closeBubblePanel() {
        if let panel = bubblePanel {
            panel.orderOut(nil)
            bubblePanel = nil
        }
        removeBubblePanelOutsideMonitors()
    }

    private func installBubblePanelOutsideMonitors() {
        removeBubblePanelOutsideMonitors()

        bubblePanelLocalMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] event in
            guard let self else { return event }
            self.handleBubblePanelOutsideEvent(event)
            return event
        }

        bubblePanelGlobalMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.closeBubblePanel()
            }
        }
    }

    private func removeBubblePanelOutsideMonitors() {
        if let monitor = bubblePanelLocalMonitor {
            NSEvent.removeMonitor(monitor)
            bubblePanelLocalMonitor = nil
        }
        if let monitor = bubblePanelGlobalMonitor {
            NSEvent.removeMonitor(monitor)
            bubblePanelGlobalMonitor = nil
        }
    }

    private func handleBubblePanelOutsideEvent(_ event: NSEvent) {
        guard let panel = bubblePanel else { return }
        if event.window === panel { return }
        closeBubblePanel()
    }

    private func togglePopover(relativeTo button: NSStatusBarButton) {
        // If a bubble-style surface (picker / correction / snippet) is up, the
        // menu-bar button click should close it cleanly before we toggle the
        // standard popover.
        closeBubblePanel()

        if popover.isShown {
            popover.performClose(nil)
        } else {
            if let controller {
                configureDefaultPopover(controller: controller)
            }
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            installOutsideClickMonitors()
        }
    }

    private func showPopoverUsingBestAnchor() {
        if let contentView = preferredAnchorContentView() {
            let anchorRect = NSRect(
                x: max(0, contentView.bounds.midX - 1),
                y: max(0, min(contentView.bounds.maxY - 40, contentView.bounds.midY + 120)),
                width: 2,
                height: 2
            )
            popover.show(relativeTo: anchorRect, of: contentView, preferredEdge: .minY)
            return
        }

        if let button = statusItem?.button {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }

    private func preferredAnchorContentView() -> NSView? {
        let popoverWindow = popover.contentViewController?.view.window
        let preferredWindow = NSApp.keyWindow
            ?? NSApp.mainWindow
            ?? NSApp.orderedWindows.first {
                $0.isVisible &&
                !($0 is NSPanel) &&
                $0 !== popoverWindow
            }

        guard let preferredWindow,
              preferredWindow !== statusItem?.button?.window else {
            return nil
        }

        return preferredWindow.contentView
    }

    private func closePopover() {
        popover.performClose(nil)
        removeOutsideClickMonitors()
    }

    private func installOutsideClickMonitors() {
        removeOutsideClickMonitors()

        localEventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self else { return event }
            self.handleOutsideInteraction(for: event)
            return event
        }

        globalEventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.closePopover()
            }
        }
    }

    private func removeOutsideClickMonitors() {
        if let localEventMonitor {
            NSEvent.removeMonitor(localEventMonitor)
            self.localEventMonitor = nil
        }
        if let globalEventMonitor {
            NSEvent.removeMonitor(globalEventMonitor)
            self.globalEventMonitor = nil
        }
    }

    private func handleOutsideInteraction(for event: NSEvent) {
        guard popover.isShown else { return }

        let popoverWindow = popover.contentViewController?.view.window
        let statusButtonWindow = statusItem?.button?.window
        if event.window === popoverWindow || event.window === statusButtonWindow {
            return
        }

        closePopover()
    }

    private func handleOpenVoce() {
        closePopover()
        showWindow()
    }

    private func handleCopyLastDictation() {
        controller?.copyCurrentTranscript()
    }

    private func handleToggleTranscription() {
        controller?.toggleMenuBarTranscription()
    }

    private func handleCreateSnippet() {
        closePopover()
        controller?.createSnippetFromCurrentTranscript()
    }

    private func handleCreateDictionaryItem() {
        closePopover()
        controller?.createCorrectionFromCurrentTranscript()
    }

    @objc private func showWindowAction() {
        showWindow()
    }

    @objc private func toggleHandsFreeAction() {
        controller?.toggleHandsFree()
    }

    @objc private func repositionOverlayAction() {
        controller?.beginOverlayRepositionMode()
    }

    @objc private func checkForUpdatesAction() {
        NotificationCenter.default.post(name: .voceCheckForUpdatesRequested, object: nil)
    }

    @objc private func forceQuitAction() {
        closePopover()
        controller?.teardown()
        NSApp.terminate(nil)
    }

    func popoverDidClose(_ notification: Notification) {
        removeOutsideClickMonitors()
    }
}

private struct SelectionCorrectionPopoverView: View {
    let term: String
    let sourceAppName: String?
    let appearancePreference: AppAppearancePreference
    let onCancel: () -> Void
    let onSave: (String) -> Void

    @State private var replacement = ""
    @FocusState private var isReplacementFocused: Bool

    private var trimmedReplacement: String {
        replacement.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var preferredColorScheme: ColorScheme? {
        switch appearancePreference {
        case .system:
            return nil
        case .light:
            return .light
        case .dark:
            return .dark
        }
    }

    var body: some View {
        ZStack {
            Image("RecordBackground")
                .resizable()
                .aspectRatio(contentMode: .fill)
                .saturation(0.94)
                .overlay {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(Color.white.opacity(0.10))
                }
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))

            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.ultraThinMaterial.opacity(0.72))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(VoceDesign.border.opacity(0.9), lineWidth: 1)
                )
                .padding(10)

            VStack(alignment: .leading, spacing: VoceDesign.md) {
                HStack(spacing: VoceDesign.sm) {
                    Image(systemName: "text.badge.checkmark")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(VoceDesign.warmAccentText)
                        .frame(width: 30, height: 30)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(VoceDesign.warmAccentFill)
                        )

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Teach Voce")
                            .font(VoceDesign.bodyEmphasis())
                            .foregroundStyle(VoceDesign.textPrimary)
                        Text(sourceAppName.map { "Fix selected text in \($0)" } ?? "Create a dictionary quick fix")
                            .font(VoceDesign.caption())
                            .foregroundStyle(VoceDesign.textSecondary)
                    }

                    Spacer(minLength: 0)

                    Button(action: onCancel) {
                        Image(systemName: "xmark")
                            .font(.system(size: 11, weight: .bold))
                            .frame(width: 28, height: 28)
                    }
                    .buttonStyle(MenuBarIconButtonStyle())
                    .help("Cancel")
                }

                VStack(alignment: .leading, spacing: VoceDesign.sm) {
                    Text("Voce heard")
                        .font(VoceDesign.labelEmphasis())
                        .foregroundStyle(VoceDesign.textSecondary)

                    Text(term)
                        .font(VoceDesign.bodyEmphasis())
                        .foregroundStyle(VoceDesign.textPrimary)
                        .lineLimit(2)
                        .truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(VoceDesign.md)
                .background(
                    RoundedRectangle(cornerRadius: VoceDesign.radiusMedium, style: .continuous)
                        .fill(VoceDesign.surfaceSecondary.opacity(0.88))
                        .overlay(
                            RoundedRectangle(cornerRadius: VoceDesign.radiusMedium, style: .continuous)
                                .stroke(VoceDesign.border, lineWidth: 1)
                        )
                )

                VStack(alignment: .leading, spacing: VoceDesign.xs) {
                    Text("Replace with")
                        .font(VoceDesign.labelEmphasis())
                        .foregroundStyle(VoceDesign.textSecondary)

                    TextField("Correct spelling or phrase", text: $replacement)
                        .textFieldStyle(.plain)
                        .font(VoceDesign.body())
                        .foregroundStyle(VoceDesign.textPrimary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(VoceDesign.surface.opacity(0.92))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .stroke(VoceDesign.warmAccentText.opacity(isReplacementFocused ? 0.28 : 0.10), lineWidth: 1)
                                )
                        )
                        .focused($isReplacementFocused)
                        .onSubmit(save)
                }

                HStack(spacing: VoceDesign.sm) {
                    Button("Cancel", action: onCancel)
                        .buttonStyle(MenuBarActionButtonStyle())

                    Button("Save and replace", action: save)
                        .buttonStyle(MenuBarPrimaryActionButtonStyle())
                        .disabled(trimmedReplacement.isEmpty)
                }
            }
            .padding(VoceDesign.lg)
            .padding(10)
        }
        .frame(width: 360)
        .preferredColorScheme(preferredColorScheme)
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                isReplacementFocused = true
            }
        }
    }

    private func save() {
        let value = trimmedReplacement
        guard !value.isEmpty else { return }
        onSave(value)
    }
}

private struct SelectionSnippetPopoverView: View {
    let expansion: String
    let appearancePreference: AppAppearancePreference
    let onCancel: () -> Void
    let onSave: (String) -> Void

    @State private var trigger = ""
    @FocusState private var isTriggerFocused: Bool

    private var trimmedTrigger: String {
        trigger.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var preferredColorScheme: ColorScheme? {
        switch appearancePreference {
        case .system:
            return nil
        case .light:
            return .light
        case .dark:
            return .dark
        }
    }

    var body: some View {
        ZStack {
            Image("RecordBackground")
                .resizable()
                .aspectRatio(contentMode: .fill)
                .saturation(0.94)
                .overlay {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(Color.white.opacity(0.10))
                }
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))

            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.ultraThinMaterial.opacity(0.72))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(VoceDesign.border.opacity(0.9), lineWidth: 1)
                )
                .padding(10)

            VStack(alignment: .leading, spacing: VoceDesign.md) {
                HStack(spacing: VoceDesign.sm) {
                    Image(systemName: "text.quote")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(VoceDesign.warmAccentText)
                        .frame(width: 30, height: 30)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(VoceDesign.warmAccentFill)
                        )

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Create snippet")
                            .font(VoceDesign.bodyEmphasis())
                            .foregroundStyle(VoceDesign.textPrimary)
                        Text("Give selected text a spoken trigger")
                            .font(VoceDesign.caption())
                            .foregroundStyle(VoceDesign.textSecondary)
                    }

                    Spacer(minLength: 0)

                    Button(action: onCancel) {
                        Image(systemName: "xmark")
                            .font(.system(size: 11, weight: .bold))
                            .frame(width: 28, height: 28)
                    }
                    .buttonStyle(MenuBarIconButtonStyle())
                    .help("Cancel")
                }

                VStack(alignment: .leading, spacing: VoceDesign.sm) {
                    Text("Insert")
                        .font(VoceDesign.labelEmphasis())
                        .foregroundStyle(VoceDesign.textSecondary)

                    Text(expansion)
                        .font(VoceDesign.bodyEmphasis())
                        .foregroundStyle(VoceDesign.textPrimary)
                        .lineLimit(3)
                        .truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(VoceDesign.md)
                .background(
                    RoundedRectangle(cornerRadius: VoceDesign.radiusMedium, style: .continuous)
                        .fill(VoceDesign.surfaceSecondary.opacity(0.88))
                        .overlay(
                            RoundedRectangle(cornerRadius: VoceDesign.radiusMedium, style: .continuous)
                                .stroke(VoceDesign.border, lineWidth: 1)
                        )
                )

                VStack(alignment: .leading, spacing: VoceDesign.xs) {
                    Text("Say")
                        .font(VoceDesign.labelEmphasis())
                        .foregroundStyle(VoceDesign.textSecondary)

                    TextField("Shortcut phrase", text: $trigger)
                        .textFieldStyle(.plain)
                        .font(VoceDesign.body())
                        .foregroundStyle(VoceDesign.textPrimary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(VoceDesign.surface.opacity(0.92))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .stroke(VoceDesign.warmAccentText.opacity(isTriggerFocused ? 0.28 : 0.10), lineWidth: 1)
                                )
                        )
                        .focused($isTriggerFocused)
                        .onSubmit(save)
                }

                HStack(spacing: VoceDesign.sm) {
                    Button("Cancel", action: onCancel)
                        .buttonStyle(MenuBarActionButtonStyle())

                    Button("Save shortcut", action: save)
                        .buttonStyle(MenuBarPrimaryActionButtonStyle())
                        .disabled(trimmedTrigger.isEmpty)
                }
            }
            .padding(VoceDesign.lg)
            .padding(10)
        }
        .frame(width: 360)
        .preferredColorScheme(preferredColorScheme)
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                isTriggerFocused = true
            }
        }
    }

    private func save() {
        let value = trimmedTrigger
        guard !value.isEmpty else { return }
        onSave(value)
    }
}

private struct MenuBarPopoverView: View {
    @ObservedObject var controller: DictationController
    let onOpenVoce: () -> Void
    let onCopyLastDictation: () -> Void
    let onCreateSnippet: () -> Void
    let onCreateDictionaryItem: () -> Void
    let onToggleTranscription: () -> Void

    @State private var isHoveringLastDictation = false
    @State private var copyToastMessage: String?
    @State private var copyToastToken = UUID()

    private var previewText: String {
        if !controller.lastTranscript.isEmpty {
            return controller.lastTranscript
        }
        if let latest = controller.recentEntries.first {
            return latest.cleanText.isEmpty ? latest.rawText : latest.cleanText
        }
        return ""
    }

    private var statusLabel: String {
        if accessIsBlocked {
            return "Access required"
        }
        if controller.isRecording {
            return "Listening"
        }
        if controller.handsFreeOn {
            return "Hands-free on"
        }
        return "Ready"
    }

    private var accessIsBlocked: Bool {
        switch controller.voceProEntitlementStatus {
        case .entitled:
            return false
        case .missingEmail, .needsVerification, .checking, .notEntitled, .failed:
            return true
        }
    }

    private var accessDetail: String {
        switch controller.voceProEntitlementStatus {
        case .missingEmail:
            return "Enter your email to start dictating."
        case .needsVerification:
            return "Verify your email to start dictating."
        case .checking:
            return "Voce is checking your access."
        case .notEntitled:
            return "Monthly free time is used. Subscribe to keep dictating."
        case .failed:
            return controller.voceProEntitlementStatus.message
        case .entitled:
            return ""
        }
    }

    private var preferredColorScheme: ColorScheme? {
        switch controller.preferences.general.appearancePreference {
        case .system:
            return nil
        case .light:
            return .light
        case .dark:
            return .dark
        }
    }

    var body: some View {
        ZStack {
            Image("RecordBackground")
                .resizable()
                .aspectRatio(contentMode: .fill)
                .saturation(0.94)
                .overlay {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(Color.white.opacity(0.10))
                }
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))

            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.ultraThinMaterial.opacity(0.58))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(VoceDesign.border.opacity(0.9), lineWidth: 1)
                )
                .padding(10)

            VStack(alignment: .leading, spacing: VoceDesign.md) {
                HStack(alignment: .center, spacing: VoceDesign.sm) {
                    Button(action: accessIsBlocked ? onOpenVoce : onToggleTranscription) {
                        Image(systemName: controller.isRecording ? "waveform" : (controller.handsFreeOn ? "mic.fill" : "mic"))
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(accessIsBlocked ? VoceDesign.textSecondary : VoceDesign.warmAccentText)
                            .frame(width: 28, height: 28)
                            .background(
                                RoundedRectangle(cornerRadius: 9, style: .continuous)
                                    .fill(accessIsBlocked ? VoceDesign.surfaceSecondary : VoceDesign.warmAccentFill)
                            )
                    }
                    .buttonStyle(.plain)
                    .help(accessIsBlocked ? "Open Voce to verify access" : (controller.isRecording ? "Stop transcription" : "Start transcription"))

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Voce")
                            .font(VoceDesign.bodyEmphasis())
                            .foregroundStyle(VoceDesign.textPrimary)
                        Text(statusLabel)
                            .font(VoceDesign.caption())
                            .foregroundStyle(VoceDesign.textSecondary)
                    }

                    Spacer(minLength: 0)

                    Button(action: onOpenVoce) {
                        Image(systemName: "macwindow")
                            .font(.system(size: 13, weight: .semibold))
                            .frame(width: 30, height: 30)
                    }
                    .buttonStyle(MenuBarIconButtonStyle())
                    .help("Open Voce")
                }

                if accessIsBlocked {
                    HStack(alignment: .top, spacing: VoceDesign.sm) {
                        Image(systemName: "person.badge.key.fill")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(VoceDesign.warmAccentText)
                            .frame(width: 24, height: 24)
                            .background(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(VoceDesign.warmAccentFill)
                            )

                        VStack(alignment: .leading, spacing: 2) {
                            Text("Finish access setup")
                                .font(VoceDesign.captionEmphasis())
                                .foregroundStyle(VoceDesign.textPrimary)

                            Text(accessDetail)
                                .font(VoceDesign.caption())
                                .foregroundStyle(VoceDesign.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        Spacer(minLength: 0)
                    }
                    .padding(VoceDesign.sm)
                    .background(
                        RoundedRectangle(cornerRadius: VoceDesign.radiusSmall, style: .continuous)
                            .fill(VoceDesign.surfaceSecondary.opacity(0.88))
                            .overlay(
                                RoundedRectangle(cornerRadius: VoceDesign.radiusSmall, style: .continuous)
                                    .stroke(VoceDesign.warmAccentText.opacity(0.14), lineWidth: 1)
                            )
                    )
                }

                VStack(alignment: .leading, spacing: VoceDesign.sm) {
                    Text("Last dictation")
                        .font(VoceDesign.labelEmphasis())
                        .foregroundStyle(VoceDesign.textSecondary)

                    ZStack(alignment: .topTrailing) {
                        Group {
                            if previewText.isEmpty {
                                Text("Nothing yet")
                                    .font(VoceDesign.body())
                                    .foregroundStyle(VoceDesign.textSecondary)
                            } else {
                                Text(previewText)
                                    .font(VoceDesign.body())
                                    .foregroundStyle(VoceDesign.textPrimary)
                                    .lineLimit(4)
                                    .multilineTextAlignment(.leading)
                                    .textSelection(.enabled)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)

                        if !previewText.isEmpty && isHoveringLastDictation {
                            Button(action: handleCopyLastDictation) {
                                Image(systemName: "doc.on.doc")
                                    .font(.system(size: 12, weight: .semibold))
                                    .frame(width: 28, height: 28)
                            }
                            .buttonStyle(MenuBarIconButtonStyle())
                            .help("Copy last dictation")
                        }
                    }
                }
                .padding(VoceDesign.md)
                .background(
                    RoundedRectangle(cornerRadius: VoceDesign.radiusMedium, style: .continuous)
                        .fill(VoceDesign.surfaceSecondary.opacity(0.88))
                        .overlay(
                            RoundedRectangle(cornerRadius: VoceDesign.radiusMedium, style: .continuous)
                                .stroke(VoceDesign.border, lineWidth: 1)
                        )
                )
                .onHover { hovering in
                    isHoveringLastDictation = hovering
                }

                if controller.isRecording || controller.handsFreeOn {
                    Button(action: onToggleTranscription) {
                        Label("Stop dictation", systemImage: "stop.fill")
                    }
                    .buttonStyle(MenuBarPrimaryActionButtonStyle())
                }

                HStack(spacing: VoceDesign.sm) {
                    Button(action: onCreateSnippet) {
                        Label("New snippet", systemImage: "text.quote")
                    }
                    .buttonStyle(MenuBarActionButtonStyle())
                    .disabled(previewText.isEmpty)

                    Button(action: onCreateDictionaryItem) {
                        Label("Dictionary", systemImage: "text.badge.checkmark")
                    }
                    .buttonStyle(MenuBarActionButtonStyle())
                    .disabled(previewText.isEmpty)
                }

            }
            .padding(VoceDesign.lg)
            .padding(10)

            if let message = copyToastMessage {
                VStack {
                    HStack {
                        Spacer()
                        HStack(spacing: 6) {
                            Image(systemName: "checkmark")
                                .font(.system(size: 11, weight: .bold))
                            Text(message)
                                .font(VoceDesign.captionEmphasis())
                        }
                        .foregroundStyle(VoceDesign.textPrimary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background(
                            Capsule(style: .continuous)
                                .fill(VoceDesign.surface.opacity(0.96))
                                .overlay(
                                    Capsule(style: .continuous)
                                        .stroke(VoceDesign.border, lineWidth: 1)
                                )
                        )
                    }
                    Spacer()
                }
                .padding(.top, 16)
                .padding(.trailing, 18)
                .transition(.move(edge: .top).combined(with: .opacity))
                .allowsHitTesting(false)
                .zIndex(2)
            }
        }
        .frame(width: 320)
        .preferredColorScheme(preferredColorScheme)
    }

    private func handleCopyLastDictation() {
        onCopyLastDictation()
        showCopyToast(message: "Copied")
    }

    private func showCopyToast(message: String) {
        let token = UUID()
        copyToastToken = token
        withAnimation(.spring(response: 0.22, dampingFraction: 0.9)) {
            copyToastMessage = message
        }

        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.8))
            guard copyToastToken == token else { return }
            withAnimation(.easeOut(duration: 0.18)) {
                copyToastMessage = nil
            }
        }
    }
}

private struct MenuBarActionButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(VoceDesign.callout())
            .foregroundStyle(isEnabled ? VoceDesign.textPrimary : VoceDesign.textSecondary.opacity(0.72))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(VoceDesign.surfaceSecondary.opacity(isEnabled ? (configuration.isPressed ? 0.96 : 1) : 0.72))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(VoceDesign.border.opacity(isEnabled ? 1 : 0.72), lineWidth: 1)
                    )
            )
    }
}

private struct MenuBarPrimaryActionButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(VoceDesign.callout())
            .foregroundStyle(isEnabled ? VoceDesign.warmAccentText : VoceDesign.textSecondary.opacity(0.72))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isEnabled ? VoceDesign.warmAccentFill.opacity(configuration.isPressed ? 0.84 : 1) : VoceDesign.surfaceSecondary.opacity(0.72))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(isEnabled ? VoceDesign.warmAccentText.opacity(0.14) : VoceDesign.border.opacity(0.72), lineWidth: 1)
                    )
            )
            .opacity(configuration.isPressed && isEnabled ? 0.92 : 1)
    }
}

private struct MenuBarIconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(VoceDesign.textPrimary)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(VoceDesign.surfaceSecondary.opacity(configuration.isPressed ? 0.96 : 1))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(VoceDesign.border, lineWidth: 1)
                    )
            )
    }
}

// MARK: - Voce Action Picker

/// What the user picks after tapping Cmd+Option. The picker captures the
/// frontmost selection up-front and then routes to the matching flow.
enum VoceAction: Hashable, CaseIterable {
    case dictionaryFix
    case createSnippet

    var title: String {
        switch self {
        case .dictionaryFix: return "Dictionary fix"
        case .createSnippet: return "Create snippet"
        }
    }

    var description: String {
        switch self {
        case .dictionaryFix: return "Teach Voce a replacement for this text"
        case .createSnippet: return "Save this text as a spoken trigger"
        }
    }

    var systemImage: String {
        switch self {
        case .dictionaryFix: return "text.badge.checkmark"
        case .createSnippet: return "text.quote"
        }
    }

    /// Single-letter shortcut shown next to the action and accepted as a
    /// keypress to jump-select.
    var letterShortcut: Character {
        switch self {
        case .dictionaryFix: return "D"
        case .createSnippet: return "S"
        }
    }
}

private struct VoceActionPickerView: View {
    let selection: String
    let sourceAppName: String?
    let appearancePreference: AppAppearancePreference
    let onCancel: () -> Void
    let onPick: (VoceAction) -> Void

    @State private var highlighted: VoceAction = .dictionaryFix
    @FocusState private var isFocused: Bool

    private var preferredColorScheme: ColorScheme? {
        switch appearancePreference {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }

    private var subtitle: String {
        if let sourceAppName, !sourceAppName.isEmpty {
            return "Selected from \(sourceAppName)"
        } else {
            return "Pick what to do with the selection"
        }
    }

    var body: some View {
        ZStack {
            Image("RecordBackground")
                .resizable()
                .aspectRatio(contentMode: .fill)
                .saturation(0.94)
                .overlay {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(Color.white.opacity(0.10))
                }
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))

            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.ultraThinMaterial.opacity(0.72))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(VoceDesign.border.opacity(0.9), lineWidth: 1)
                )
                .padding(10)

            VStack(alignment: .leading, spacing: VoceDesign.md) {
                header

                selectionPreview

                VStack(spacing: VoceDesign.xs) {
                    actionRow(.dictionaryFix)
                    actionRow(.createSnippet)
                }

                Text("Return to confirm · ↑↓ to switch · D/S to choose · Esc to cancel")
                    .font(VoceDesign.caption())
                    .foregroundStyle(VoceDesign.textSecondary.opacity(0.85))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(VoceDesign.lg)
        }
        .preferredColorScheme(preferredColorScheme)
        .focusable()
        .focused($isFocused)
        .onAppear {
            // Defer focus until the popover finishes its present animation —
            // otherwise the focus state can be discarded.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                isFocused = true
            }
        }
        .onKeyPress(.return) {
            onPick(highlighted)
            return .handled
        }
        .onKeyPress(.escape) {
            onCancel()
            return .handled
        }
        .onKeyPress(.upArrow) {
            highlighted = .dictionaryFix
            return .handled
        }
        .onKeyPress(.downArrow) {
            highlighted = .createSnippet
            return .handled
        }
        .onKeyPress { press in
            switch press.characters.lowercased() {
            case "d":
                onPick(.dictionaryFix)
                return .handled
            case "s":
                onPick(.createSnippet)
                return .handled
            default:
                return .ignored
            }
        }
    }

    private var header: some View {
        HStack(spacing: VoceDesign.sm) {
            Image(systemName: "command")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(VoceDesign.warmAccentText)
                .frame(width: 30, height: 30)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(VoceDesign.warmAccentFill)
                )

            VStack(alignment: .leading, spacing: 2) {
                Text("Voce action")
                    .font(VoceDesign.bodyEmphasis())
                    .foregroundStyle(VoceDesign.textPrimary)
                Text(subtitle)
                    .font(VoceDesign.caption())
                    .foregroundStyle(VoceDesign.textSecondary)
            }

            Spacer(minLength: 0)

            Button(action: onCancel) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(MenuBarIconButtonStyle())
            .help("Cancel")
        }
    }

    private var selectionPreview: some View {
        VStack(alignment: .leading, spacing: VoceDesign.xs) {
            Text("Selected")
                .font(VoceDesign.labelEmphasis())
                .foregroundStyle(VoceDesign.textSecondary)

            Text(selection)
                .font(VoceDesign.bodyEmphasis())
                .foregroundStyle(VoceDesign.textPrimary)
                .lineLimit(2)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(VoceDesign.md)
        .background(
            RoundedRectangle(cornerRadius: VoceDesign.radiusMedium, style: .continuous)
                .fill(VoceDesign.surfaceSecondary.opacity(0.88))
                .overlay(
                    RoundedRectangle(cornerRadius: VoceDesign.radiusMedium, style: .continuous)
                        .stroke(VoceDesign.border, lineWidth: 1)
                )
        )
    }

    private func actionRow(_ action: VoceAction) -> some View {
        let isHighlighted = highlighted == action
        return Button {
            onPick(action)
        } label: {
            HStack(spacing: VoceDesign.sm) {
                Image(systemName: action.systemImage)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(isHighlighted ? VoceDesign.warmAccentText : VoceDesign.textPrimary)
                    .frame(width: 28, height: 28)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(isHighlighted ? VoceDesign.warmAccentFill : VoceDesign.surfaceSecondary.opacity(0.6))
                    )

                VStack(alignment: .leading, spacing: 2) {
                    Text(action.title)
                        .font(VoceDesign.bodyEmphasis())
                        .foregroundStyle(VoceDesign.textPrimary)
                    Text(action.description)
                        .font(VoceDesign.caption())
                        .foregroundStyle(VoceDesign.textSecondary)
                }

                Spacer(minLength: 0)

                Text(String(action.letterShortcut))
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(VoceDesign.textSecondary)
                    .frame(width: 22, height: 22)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(VoceDesign.surface.opacity(0.92))
                            .overlay(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .stroke(VoceDesign.border, lineWidth: 1)
                            )
                    )
            }
            .padding(.vertical, VoceDesign.sm)
            .padding(.horizontal, VoceDesign.md)
            .background(
                RoundedRectangle(cornerRadius: VoceDesign.radiusMedium, style: .continuous)
                    .fill(isHighlighted ? VoceDesign.warmAccentFill.opacity(0.4) : VoceDesign.surfaceSecondary.opacity(0.5))
                    .overlay(
                        RoundedRectangle(cornerRadius: VoceDesign.radiusMedium, style: .continuous)
                            .stroke(
                                isHighlighted ? VoceDesign.warmAccentText.opacity(0.32) : VoceDesign.border,
                                lineWidth: isHighlighted ? 1.5 : 1
                            )
                    )
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(action.title))
        .accessibilityHint(Text(action.description))
        .onHover { hovering in
            if hovering {
                highlighted = action
            }
        }
    }
}
