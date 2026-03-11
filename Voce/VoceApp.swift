import AppKit
import Sparkle
import SwiftUI

@main
struct VoceApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var controller = DictationController()
    @StateObject private var updaterController = UpdaterController()

    var body: some Scene {
        WindowGroup("Voce") {
            Group {
                if !controller.hasBootstrapped {
                    VoceDesign.background
                } else if controller.preferences.general.showOnboarding {
                    OnboardingView()
                        .environmentObject(controller)
                } else {
                    ContentView()
                        .environmentObject(controller)
                        .environmentObject(updaterController)
                }
            }
        }
        .defaultSize(width: VoceDesign.windowIdealWidth, height: VoceDesign.windowIdealHeight)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            if let reopenWindow = sender.windows.first(where: { !($0 is NSPanel) && $0.canBecomeMain }) {
                reopenWindow.makeKeyAndOrderFront(nil)
            }
        }
        return true
    }
}
