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
        openSettingsURL(
            candidates: [
                "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility",
                "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Accessibility",
                "x-apple.systempreferences:com.apple.settings.PrivacySecurity"
            ]
        )
    }

    static func openMicrophoneSettings() {
        openSettingsURL(
            candidates: [
                "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone",
                "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Microphone",
                "x-apple.systempreferences:com.apple.settings.PrivacySecurity"
            ]
        )
    }

    static func openInputMonitoringSettings() {
        openSettingsURL(
            candidates: [
                "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent",
                "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_ListenEvent",
                "x-apple.systempreferences:com.apple.settings.PrivacySecurity"
            ]
        )
    }

    static func revealCurrentAppInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
    }

    static func currentAppBundlePath() -> String {
        Bundle.main.bundleURL.path
    }

    private static func openSettingsURL(candidates: [String]) {
        for candidate in candidates {
            guard let url = URL(string: candidate) else { continue }
            if NSWorkspace.shared.open(url) {
                return
            }
        }
    }
}
