import AppKit
import SwiftUI

@MainActor
final class MenuBarController: NSObject, NSPopoverDelegate {
    private var statusItem: NSStatusItem?
    private weak var controller: DictationController?
    private let popover = NSPopover()
    private let statusSymbolConfiguration = NSImage.SymbolConfiguration(pointSize: 14, weight: .semibold)
    private var localEventMonitor: Any?
    private var globalEventMonitor: Any?

    func setup(controller: DictationController) {
        self.controller = controller
        configurePopover(controller: controller)

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
        togglePopover(relativeTo: sender)
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

    private func configurePopover(controller: DictationController) {
        popover.delegate = self
        popover.behavior = .transient
        popover.animates = true
        popover.contentSize = NSSize(width: 320, height: 260)
        popover.contentViewController = NSHostingController(
            rootView: MenuBarPopoverView(
                controller: controller,
                onOpenVoce: { [weak self] in self?.handleOpenVoce() },
                onCopyLastDictation: { [weak self] in self?.handleCopyLastDictation() },
                onToggleTranscription: { [weak self] in self?.handleToggleTranscription() },
                onCheckForUpdates: { [weak self] in self?.handleCheckForUpdates() }
            )
        )
    }

    private func togglePopover(relativeTo button: NSStatusBarButton) {
        if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            installOutsideClickMonitors()
        }
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
        closePopover()
        controller?.toggleMenuBarTranscription()
    }

    private func handleCheckForUpdates() {
        closePopover()
        checkForUpdatesAction()
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

    func popoverDidClose(_ notification: Notification) {
        removeOutsideClickMonitors()
    }
}

private struct MenuBarPopoverView: View {
    @ObservedObject var controller: DictationController
    let onOpenVoce: () -> Void
    let onCopyLastDictation: () -> Void
    let onToggleTranscription: () -> Void
    let onCheckForUpdates: () -> Void

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
        if controller.isRecording {
            return "Listening"
        }
        if controller.handsFreeOn {
            return "Hands-free on"
        }
        return "Ready"
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
                    Button(action: onToggleTranscription) {
                        Image(systemName: controller.isRecording ? "waveform" : (controller.handsFreeOn ? "mic.fill" : "mic"))
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(VoceDesign.warmAccentText)
                            .frame(width: 28, height: 28)
                            .background(
                                RoundedRectangle(cornerRadius: 9, style: .continuous)
                                    .fill(VoceDesign.warmAccentFill)
                            )
                    }
                    .buttonStyle(.plain)
                    .help(controller.isRecording ? "Stop transcription" : "Start transcription")

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

                VStack(alignment: .leading, spacing: VoceDesign.sm) {
                    Text("Last dictation")
                        .font(VoceDesign.labelEmphasis())
                        .foregroundStyle(VoceDesign.textSecondary)

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

                HStack(spacing: VoceDesign.sm) {
                    Button(action: onCopyLastDictation) {
                        Label("Copy", systemImage: "doc.on.doc")
                    }
                    .buttonStyle(MenuBarActionButtonStyle())
                    .disabled(previewText.isEmpty)

                    Button(action: onCheckForUpdates) {
                        Label("Updates", systemImage: "arrow.triangle.2.circlepath")
                    }
                    .buttonStyle(MenuBarActionButtonStyle())
                }

            }
            .padding(VoceDesign.lg)
            .padding(10)
        }
        .frame(width: 320)
        .preferredColorScheme(preferredColorScheme)
    }
}

private struct MenuBarActionButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(VoceDesign.callout())
            .foregroundStyle(VoceDesign.textPrimary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(VoceDesign.surfaceSecondary.opacity(configuration.isPressed ? 0.96 : 1))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(VoceDesign.border, lineWidth: 1)
                    )
            )
    }
}

private struct MenuBarIconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(VoceDesign.textPrimary)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(VoceDesign.surfaceSecondary.opacity(configuration.isPressed ? 0.96 : 1))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(VoceDesign.border, lineWidth: 1)
                    )
            )
    }
}
