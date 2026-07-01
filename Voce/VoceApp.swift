import AppKit
import AppIntents
import Sparkle
import SwiftUI
import VoceKit

@main
struct VoceApp: App {
    private static let primaryWindowID = "primary"

    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @Environment(\.openWindow) private var openWindow
    @StateObject private var controller = DictationController()
    @StateObject private var updaterController = UpdaterController()

    init() {
        VoceDesign.registerBundledFonts()
    }

    var body: some Scene {
        WindowGroup(VoceRuntimeConfiguration.windowTitle, id: Self.primaryWindowID) {
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
            .onAppear {
                appDelegate.registerPrimaryWindowCreationHandler {
                    openWindow(id: Self.primaryWindowID)
                }
            }
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
    private weak var primaryWindow: NSWindow?
    private var primaryWindowDelegateProxies: [ObjectIdentifier: PrimaryWindowDelegateProxy] = [:]
    private var primaryWindowCreationHandler: (() -> Void)?
    private var isRequestingPrimaryWindowCreation = false

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        installWindowObservers()

        // Delay slightly so the window is fully created before configuring transparency
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            self.configureTransparentWindows()
            self.showPrimaryWindowCreatingIfNeeded()
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        if !hasVisiblePrimaryWindow() {
            _ = showPrimaryWindowCreatingIfNeeded()
        } else {
            collapseDuplicatePrimaryWindows()
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        !showPrimaryWindowCreatingIfNeeded()
    }

    @MainActor
    func showPrimaryWindow() {
        _ = showPrimaryWindowCreatingIfNeeded()
    }

    @MainActor
    func registerPrimaryWindowCreationHandler(_ handler: @escaping () -> Void) {
        primaryWindowCreationHandler = handler
    }

    @MainActor
    private func configureTransparentWindows() {
        for window in NSApp.windows where isPrimaryVoceWindow(window) {
            configurePrimaryWindow(window)
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
    private func configurePrimaryWindow(_ window: NSWindow) {
        primaryWindow = window
        window.isReleasedWhenClosed = false

        if let proxy = window.delegate as? PrimaryWindowDelegateProxy,
           proxy.owner === self {
            primaryWindowDelegateProxies[ObjectIdentifier(window)] = proxy
            return
        }

        let proxy = PrimaryWindowDelegateProxy(owner: self, forwardingDelegate: window.delegate)
        primaryWindowDelegateProxies[ObjectIdentifier(window)] = proxy
        window.delegate = proxy
    }

    @MainActor
    fileprivate func primaryWindowShouldClose(_ window: NSWindow) -> Bool {
        guard isPrimaryVoceWindow(window) else {
            return true
        }

        window.orderOut(nil)
        return false
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
    @discardableResult
    private func showPrimaryWindowCreatingIfNeeded() -> Bool {
        if showPrimaryWindowIfNeeded() {
            isRequestingPrimaryWindowCreation = false
            return true
        }

        activateForPrimaryWindow()
        guard !isRequestingPrimaryWindowCreation else {
            return true
        }

        isRequestingPrimaryWindowCreation = true
        if let primaryWindowCreationHandler {
            primaryWindowCreationHandler()
            confirmPrimaryWindowCreation(allowResponderFallback: true)
            return true
        }

        let didSendNewWindowAction = requestPrimaryWindowViaResponderChain()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            _ = self.showPrimaryWindowIfNeeded()
            self.isRequestingPrimaryWindowCreation = false
        }
        if !didSendNewWindowAction {
            isRequestingPrimaryWindowCreation = false
        }
        return didSendNewWindowAction
    }

    @MainActor
    private func confirmPrimaryWindowCreation(allowResponderFallback: Bool) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if self.showPrimaryWindowIfNeeded() {
                self.isRequestingPrimaryWindowCreation = false
                return
            }

            guard allowResponderFallback,
                  self.requestPrimaryWindowViaResponderChain() else {
                self.isRequestingPrimaryWindowCreation = false
                return
            }

            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                _ = self.showPrimaryWindowIfNeeded()
                self.isRequestingPrimaryWindowCreation = false
            }
        }
    }

    @MainActor
    private func requestPrimaryWindowViaResponderChain() -> Bool {
        // If SwiftUI has destroyed the WindowGroup's NSWindow and the explicit
        // creation hook is unavailable or no-ops, ask AppKit's responder chain
        // for a fresh window, then restore it through the normal path.
        NSApp.sendAction(Selector(("newWindow:")), to: nil, from: nil)
    }

    @MainActor
    private func showPrimaryWindowIfNeeded() -> Bool {
        guard let window = preferredPrimaryWindow() else {
            return false
        }

        activateForPrimaryWindow()
        restorePrimaryWindowFromLegacyFrameIfNeeded(window)
        restorePrimaryWindowToVisibleScreenIfNeeded(window)
        window.setFrameAutosaveName(Self.primaryWindowAutosaveName)
        window.saveFrame(usingName: Self.primaryWindowAutosaveName)
        if window.isMiniaturized {
            window.deminiaturize(nil)
        }
        window.makeKeyAndOrderFront(nil)
        configureTransparentWindows()
        collapseDuplicatePrimaryWindows(keeping: window)
        return true
    }

    @MainActor
    private func activateForPrimaryWindow() {
        if #available(macOS 14.0, *) {
            NSApp.activate()
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }
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
            ?? primaryWindow
            ?? windows.first
    }

    private func installWindowObservers() {
        let notificationCenter = NotificationCenter.default
        notificationCenter.addObserver(
            self,
            selector: #selector(primaryWindowDidBecomeActive(_:)),
            name: NSWindow.didBecomeKeyNotification,
            object: nil
        )
        notificationCenter.addObserver(
            self,
            selector: #selector(primaryWindowDidBecomeActive(_:)),
            name: NSWindow.didBecomeMainNotification,
            object: nil
        )
    }

    @MainActor
    @objc private func primaryWindowDidBecomeActive(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              isPrimaryVoceWindow(window) else {
            return
        }

        configurePrimaryWindow(window)
    }

    @MainActor
    private func collapseDuplicatePrimaryWindows(keeping keptWindow: NSWindow? = nil) {
        guard let keptWindow = keptWindow ?? preferredPrimaryWindow() else {
            return
        }

        primaryWindow = keptWindow
        for window in NSApp.windows where isPrimaryVoceWindow(window) && window !== keptWindow {
            window.delegate = nil
            window.isReleasedWhenClosed = true
            window.close()
            primaryWindowDelegateProxies.removeValue(forKey: ObjectIdentifier(window))
        }
    }

}

private final class PrimaryWindowDelegateProxy: NSObject, NSWindowDelegate {
    weak var owner: AppDelegate?
    weak var forwardingDelegate: NSWindowDelegate?

    init(owner: AppDelegate, forwardingDelegate: NSWindowDelegate?) {
        self.owner = owner
        self.forwardingDelegate = forwardingDelegate
    }

    @MainActor
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if owner?.primaryWindowShouldClose(sender) == false {
            return false
        }

        return forwardingDelegate?.windowShouldClose?(sender) ?? true
    }

    override func responds(to selector: Selector!) -> Bool {
        if selector == #selector(NSWindowDelegate.windowShouldClose(_:)) {
            return true
        }

        return super.responds(to: selector)
            || (forwardingDelegate as AnyObject?)?.responds(to: selector) == true
    }

    override func forwardingTarget(for selector: Selector!) -> Any? {
        if (forwardingDelegate as AnyObject?)?.responds(to: selector) == true {
            return forwardingDelegate
        }

        return super.forwardingTarget(for: selector)
    }
}
