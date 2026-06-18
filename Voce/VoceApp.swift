import AppKit
import AppIntents
import Sparkle
import SwiftUI
import VoceKit

@main
struct VoceApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var controller = DictationController()
    @StateObject private var updaterController = UpdaterController()

    init() {
        VoceDesign.registerBundledFonts()
    }

    var body: some Scene {
        WindowGroup(VoceRuntimeConfiguration.windowTitle) {
            Group {
                if !controller.hasBootstrapped {
                    VoceWindowBackdrop()
                } else if controller.preferences.general.showOnboarding {
                    OnboardingView()
                        .environmentObject(controller)
                } else {
                    ContentView()
                        .environmentObject(controller)
                        .environmentObject(updaterController)
                }
            }
            .font(VoceDesign.body())
            .preferredColorScheme(controller.preferences.general.appearancePreference.preferredColorScheme)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: VoceDesign.windowIdealWidth, height: VoceDesign.windowIdealHeight)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") {
                    updaterController.checkForUpdates()
                }
                .disabled(!updaterController.canCheckForUpdates)
            }
        }
    }
}

private extension AppAppearancePreference {
    var preferredColorScheme: ColorScheme? {
        switch self {
        case .system:
            return nil
        case .light:
            return .light
        case .dark:
            return .dark
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private static let primaryWindowAutosaveName = "VocePrimaryWindow"

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Delay slightly so the window is fully created before configuring transparency
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            self.configureTransparentWindows()
            self.showPrimaryWindowIfNeeded()
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        if !hasVisiblePrimaryWindow() {
            showPrimaryWindowIfNeeded()
        } else {
            collapseDuplicatePrimaryWindows()
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showPrimaryWindowIfNeeded()
        return false
    }

    @MainActor
    func showPrimaryWindow() {
        showPrimaryWindowIfNeeded()
    }

    @MainActor
    private func configureTransparentWindows() {
        for window in NSApp.windows where isPrimaryVoceWindow(window) {
            window.isOpaque = false
            window.backgroundColor = .clear
            window.contentMinSize = NSSize(
                width: VoceDesign.windowMinWidth,
                height: VoceDesign.windowMinHeight
            )
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.titlebarSeparatorStyle = .none
            // Hidden-titlebar windows with full-size content can intermittently
            // swallow the first click when background dragging is enabled.
            window.isMovableByWindowBackground = false
            window.styleMask.insert(.fullSizeContentView)
        }
    }

    @MainActor
    private func isPrimaryVoceWindow(_ window: NSWindow) -> Bool {
        guard !(window is NSPanel) else {
            return false
        }

        return window.title == VoceRuntimeConfiguration.windowTitle
    }

    @MainActor
    private func hasVisiblePrimaryWindow() -> Bool {
        NSApp.windows.contains { window in
            isPrimaryVoceWindow(window) && window.isVisible
        }
    }

    @MainActor
    private func showPrimaryWindowIfNeeded() {
        guard let window = preferredPrimaryWindow() else {
            return
        }

        restorePrimaryWindowFromLegacyFrameIfNeeded(window)
        restorePrimaryWindowToVisibleScreenIfNeeded(window)
        window.setFrameAutosaveName(Self.primaryWindowAutosaveName)
        window.saveFrame(usingName: Self.primaryWindowAutosaveName)
        window.makeKeyAndOrderFront(nil)
        configureTransparentWindows()
        collapseDuplicatePrimaryWindows(keeping: window)
    }

    @MainActor
    private func restorePrimaryWindowFromLegacyFrameIfNeeded(_ window: NSWindow) {
        let defaults = UserDefaults.standard
        let stableFrameKey = "NSWindow Frame \(Self.primaryWindowAutosaveName)"
        guard defaults.string(forKey: stableFrameKey) == nil else { return }

        guard let mainVisibleFrame = NSScreen.main?.visibleFrame else { return }
        let legacyFrames = defaults.dictionaryRepresentation().compactMap { key, value -> NSRect? in
            guard key.hasPrefix("NSWindow Frame SwiftUI."),
                  key.contains("AppWindow"),
                  let frameString = value as? String else {
                return nil
            }
            return Self.windowFrame(from: frameString)
        }

        guard let bestMainFrame = legacyFrames
            .filter({ Self.hasUsableIntersection($0, with: mainVisibleFrame) })
            .max(by: {
                Self.visibleArea(of: $0, in: mainVisibleFrame) < Self.visibleArea(of: $1, in: mainVisibleFrame)
            }) else {
            return
        }

        guard !Self.hasUsableIntersection(window.frame, with: mainVisibleFrame) else { return }
        window.setFrame(bestMainFrame, display: false)
    }

    @MainActor
    private func restorePrimaryWindowToVisibleScreenIfNeeded(_ window: NSWindow) {
        let visibleFrames = NSScreen.screens.map(\.visibleFrame)
        guard !visibleFrames.isEmpty else { return }

        let hasUsableVisibleArea = visibleFrames.contains { visibleFrame in
            Self.hasUsableIntersection(window.frame, with: visibleFrame)
        }
        guard !hasUsableVisibleArea else { return }

        let targetFrame = NSScreen.main?.visibleFrame ?? visibleFrames[0]
        var windowFrame = window.frame
        windowFrame.size.width = min(windowFrame.width, max(targetFrame.width - 40, VoceDesign.windowMinWidth))
        windowFrame.size.height = min(windowFrame.height, max(targetFrame.height - 40, VoceDesign.windowMinHeight))
        windowFrame.origin.x = targetFrame.midX - (windowFrame.width / 2)
        windowFrame.origin.y = targetFrame.midY - (windowFrame.height / 2)
        window.setFrame(windowFrame, display: false)
    }

    private static func windowFrame(from autosaveFrameString: String) -> NSRect? {
        let values = autosaveFrameString
            .split(separator: " ")
            .prefix(4)
            .compactMap { Double($0) }
        guard values.count == 4 else { return nil }
        return NSRect(x: values[0], y: values[1], width: values[2], height: values[3])
    }

    private static func hasUsableIntersection(_ frame: NSRect, with visibleFrame: NSRect) -> Bool {
        let intersection = frame.intersection(visibleFrame)
        return intersection.width >= 160 && intersection.height >= 120
    }

    private static func visibleArea(of frame: NSRect, in visibleFrame: NSRect) -> CGFloat {
        let intersection = frame.intersection(visibleFrame)
        guard !intersection.isNull else { return 0 }
        return intersection.width * intersection.height
    }

    @MainActor
    private func preferredPrimaryWindow() -> NSWindow? {
        let windows = NSApp.windows.filter(isPrimaryVoceWindow(_:))
        return windows.first(where: \.isKeyWindow)
            ?? windows.first(where: \.isMainWindow)
            ?? windows.first(where: \.isVisible)
            ?? windows.first
    }

    @MainActor
    private func collapseDuplicatePrimaryWindows(keeping keptWindow: NSWindow? = nil) {
        guard let keptWindow = keptWindow ?? preferredPrimaryWindow() else {
            return
        }

        for window in NSApp.windows where isPrimaryVoceWindow(window) && window !== keptWindow {
            window.close()
        }
    }

}
