import Foundation
import ServiceManagement

enum LaunchAtLoginServiceError: Error, LocalizedError {
    case failed(underlying: Error)

    var errorDescription: String? {
        switch self {
        case .failed(let underlying):
            return "Unable to update launch at login: \(underlying.localizedDescription)"
        }
    }
}

@MainActor
final class LaunchAtLoginService {
    func setEnabled(_ enabled: Bool) throws {
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
}
