import AppKit
import AVFoundation
import ApplicationServices
import Foundation

struct PermissionDiagnostics {
    enum AccessStatus: String {
        case granted = "Granted"
        case denied = "Denied"
        case unknown = "Unknown"
    }

    static func microphoneStatus() -> AccessStatus {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return .granted
        case .denied, .restricted:
            return .denied
        case .notDetermined:
            return .unknown
        @unknown default:
            return .unknown
        }
    }

    static func accessibilityStatus() -> AccessStatus {
        AXIsProcessTrusted() ? .granted : .denied
    }

    static func inputMonitoringStatus() -> AccessStatus {
        CGPreflightListenEventAccess() ? .granted : .denied
    }

    static func requestMicrophonePermission() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }

    static func requestAccessibilityPermission() -> Bool {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    static func requestInputMonitoringPermission() -> Bool {
        if CGPreflightListenEventAccess() {
            return true
        }
        _ = CGRequestListenEventAccess()
        // The request call may return before user action. Check preflight later.
        return false
    }

    static func openAccessibilitySettings() {
        openPrivacySecuritySettings()
    }

    static func openMicrophoneSettings() {
        openPrivacySecuritySettings()
    }

    static func openInputMonitoringSettings() {
        openPrivacySecuritySettings()
    }

    static func revealCurrentAppInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
    }

    static func currentAppBundlePath() -> String {
        Bundle.main.bundleURL.path
    }

    private static func openPrivacySecuritySettings() {
        openSettingsURL("x-apple.systempreferences:com.apple.settings.PrivacySecurity")
    }

    private static func openSettingsURL(_ value: String) {
        guard let url = URL(string: value) else { return }
        NSWorkspace.shared.open(url)
    }
}
