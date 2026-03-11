import Sparkle
import SwiftUI

@MainActor
final class UpdaterController: NSObject, ObservableObject {
    private static let fallbackFeedURLString = "https://raw.githubusercontent.com/hannahmwright/voce/main/appcast.xml"

    @Published private(set) var canCheckForUpdates = false
    @Published private(set) var automaticallyChecksForUpdates = false

    private var updaterController: SPUStandardUpdaterController!
    private var updaterObservations: [NSKeyValueObservation] = []

    override init() {
        super.init()
        updaterController = SPUStandardUpdaterController(
            startingUpdater: false,
            updaterDelegate: self,
            userDriverDelegate: nil
        )
        bindUpdaterState()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.updaterController.startUpdater()
            self.refreshUpdaterState()
        }
    }

    func checkForUpdates() {
        updaterController.checkForUpdates(nil)
    }

    private func bindUpdaterState() {
        updaterObservations = [
            updaterController.updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] _, _ in
                Task { @MainActor [weak self] in
                    self?.refreshUpdaterState()
                }
            },
            updaterController.updater.observe(\.automaticallyChecksForUpdates, options: [.initial, .new]) { [weak self] _, _ in
                Task { @MainActor [weak self] in
                    self?.refreshUpdaterState()
                }
            }
        ]
    }

    private func refreshUpdaterState() {
        canCheckForUpdates = updaterController.updater.canCheckForUpdates
        automaticallyChecksForUpdates = updaterController.updater.automaticallyChecksForUpdates
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
