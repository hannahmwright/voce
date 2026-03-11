import Sparkle
import SwiftUI

@MainActor
final class UpdaterController: NSObject, ObservableObject {
    private static let fallbackFeedURLString = "https://raw.githubusercontent.com/hannahmwright/voce/main/appcast.xml"

    private lazy var updaterController = SPUStandardUpdaterController(
        startingUpdater: true,
        updaterDelegate: self,
        userDriverDelegate: nil
    )

    var canCheckForUpdates: Bool {
        updaterController.updater.canCheckForUpdates
    }

    override init() {
        super.init()
    }

    func checkForUpdates() {
        updaterController.updater.checkForUpdates()
    }
}

extension UpdaterController: SPUUpdaterDelegate {
    func feedURLString(for updater: SPUUpdater) -> String? {
        if let bundleFeedURL = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String,
           !bundleFeedURL.isEmpty {
            return bundleFeedURL
        }

        return Self.fallbackFeedURLString
    }
}
