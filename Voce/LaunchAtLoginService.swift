import Foundation
import ServiceManagement

enum LaunchAtLoginServiceError: Error, LocalizedError {
    case failed(underlying: Error)
    case unavailableForCurrentBuild

    var errorDescription: String? {
        switch self {
        case .failed(let underlying):
            return "Unable to update launch at login: \(underlying.localizedDescription)"
        case .unavailableForCurrentBuild:
            return "Launch at login is managed only by the installed app in Applications. Development builds won't start at login."
        }
    }
}

@MainActor
final class LaunchAtLoginService {
    func setEnabled(_ enabled: Bool) throws {
        guard Self.isEligibleForLaunchAtLogin(bundleURL: Bundle.main.bundleURL) else {
            if enabled {
                throw LaunchAtLoginServiceError.unavailableForCurrentBuild
            }

            return
        }

        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            throw LaunchAtLoginServiceError.failed(underlying: error)
        }
    }

    static func isEligibleForLaunchAtLogin(bundleURL: URL) -> Bool {
        let standardizedPath = bundleURL
            .resolvingSymlinksInPath()
            .standardizedFileURL
            .path

        return standardizedPath.hasPrefix("/Applications/")
            || standardizedPath.hasPrefix(NSHomeDirectory() + "/Applications/")
    }
}
