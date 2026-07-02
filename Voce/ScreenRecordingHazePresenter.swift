import AppKit
import SwiftUI

@MainActor
final class ScreenRecordingHazePresenter {
    private var panelsByScreenID: [NSNumber: NSPanel] = [:]
    private var screenObserver: NSObjectProtocol?
    private var isVisible = false

    func setVisible(_ visible: Bool) {
        guard visible != isVisible else { return }
        isVisible = visible

        if visible {
            show()
        } else {
            hide()
        }
    }

    func hide() {
        stopObservingScreens()
        panelsByScreenID.values.forEach { $0.orderOut(nil) }
        panelsByScreenID.removeAll()
        isVisible = false
    }

    private func show() {
        startObservingScreens()
        syncPanelsToScreens()
    }

    private func syncPanelsToScreens() {
        let screens = NSScreen.screens
        let activeIDs = Set(screens.map(\.stableScreenID))

        let staleScreenIDs = panelsByScreenID.keys.filter { !activeIDs.contains($0) }
        for screenID in staleScreenIDs {
            panelsByScreenID[screenID]?.orderOut(nil)
            panelsByScreenID.removeValue(forKey: screenID)
        }

        for screen in screens {
            let screenID = screen.stableScreenID
            let panel = panelsByScreenID[screenID] ?? makePanel(for: screen)
            panel.setFrame(screen.frame, display: true)
            panel.orderFrontRegardless()
            panelsByScreenID[screenID] = panel
        }
    }

    private func makePanel(for screen: NSScreen) -> NSPanel {
        let panel = NSPanel(
            contentRect: screen.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.ignoresMouseEvents = true

        let hostingView = NSHostingView(rootView: ScreenRecordingHazeView())
        hostingView.frame = NSRect(origin: .zero, size: screen.frame.size)
        hostingView.autoresizingMask = [.width, .height]
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = NSColor.clear.cgColor
        panel.contentView = hostingView

        return panel
    }

    private func startObservingScreens() {
        guard screenObserver == nil else { return }
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard self?.isVisible == true else { return }
                self?.syncPanelsToScreens()
            }
        }
    }

    private func stopObservingScreens() {
        if let screenObserver {
            NotificationCenter.default.removeObserver(screenObserver)
            self.screenObserver = nil
        }
    }
}

private struct ScreenRecordingHazeView: View {
    var body: some View {
        Rectangle()
            .fill(.clear)
            .overlay {
                Rectangle()
                    .stroke(Color.white.opacity(0.38), lineWidth: 1.5)
            }
            .overlay {
                Rectangle()
                    .stroke(Color.white.opacity(0.24), lineWidth: 12)
                    .blur(radius: 7)
            }
            .overlay {
                Rectangle()
                    .stroke(Color.white.opacity(0.13), lineWidth: 32)
                    .blur(radius: 18)
            }
            .padding(2)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

private extension NSScreen {
    var stableScreenID: NSNumber {
        deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
            ?? NSNumber(value: frame.debugDescription.hashValue)
    }
}
