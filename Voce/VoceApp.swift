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
    private var suppressedInitialWindowForBackgroundLaunch = false
    private var pendingBackgroundLaunchSuppression: DispatchWorkItem?
    private lazy var launchPreferences = loadLaunchPreferences()

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Delay slightly so the window is fully created before configuring transparency
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            self.configureTransparentWindows()
#if DEBUG
            self.showPrimaryWindowIfNeeded()
#else
            self.scheduleBackgroundLaunchSuppressionIfNeeded()
#endif
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        pendingBackgroundLaunchSuppression?.cancel()
        pendingBackgroundLaunchSuppression = nil

        if suppressedInitialWindowForBackgroundLaunch || !hasVisiblePrimaryWindow() {
            showPrimaryWindowIfNeeded()
            suppressedInitialWindowForBackgroundLaunch = false
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
        suppressedInitialWindowForBackgroundLaunch = false
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
    private func scheduleBackgroundLaunchSuppressionIfNeeded() {
        guard !NSApp.isActive else {
            return
        }

        guard launchPreferences.general.launchAtLoginEnabled else {
            return
        }

        pendingBackgroundLaunchSuppression?.cancel()

        let workItem = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                self?.suppressInitialWindowIfNeeded()
            }
        }
        pendingBackgroundLaunchSuppression = workItem

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: workItem)
    }

    @MainActor
    private func hasVisiblePrimaryWindow() -> Bool {
        NSApp.windows.contains { window in
            isPrimaryVoceWindow(window) && window.isVisible
        }
    }

    @MainActor
    private func suppressInitialWindowIfNeeded() {
        pendingBackgroundLaunchSuppression = nil

        guard !NSApp.isActive else {
            return
        }

        guard launchPreferences.general.launchAtLoginEnabled else {
            return
        }

        let primaryWindows = NSApp.windows.filter(isPrimaryVoceWindow(_:))
        guard !primaryWindows.isEmpty else {
            return
        }

        primaryWindows.forEach { $0.orderOut(nil) }
        suppressedInitialWindowForBackgroundLaunch = true
    }

    @MainActor
    private func showPrimaryWindowIfNeeded() {
        guard let window = preferredPrimaryWindow() else {
            return
        }

        window.makeKeyAndOrderFront(nil)
        configureTransparentWindows()
        collapseDuplicatePrimaryWindows(keeping: window)
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

    private func loadLaunchPreferences() -> AppPreferences {
        let storageURL = VoceRuntimeConfiguration.applicationSupportDirectory(fileName: "preferences.json")

        guard
            let data = try? Data(contentsOf: storageURL),
            let preferences = try? JSONDecoder().decode(AppPreferences.self, from: data)
        else {
            return .default
        }

        var normalized = preferences
        normalized.normalize()
        return normalized
    }
}
