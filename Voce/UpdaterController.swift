import Sparkle
import SwiftUI

extension Notification.Name {
    static let voceCheckForUpdatesRequested = Notification.Name("voceCheckForUpdatesRequested")
}

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
        bindExternalUpdateRequests()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.updaterController.startUpdater()
            self.refreshUpdaterState()

            // Force a launch-time check for users who just installed an update,
            // since Sparkle's persisted last-check timestamp can otherwise defer
            // discovering the next available version until the scheduled interval.
            // Sparkle recommends doing this immediately after starting the updater
            // and only when automatic update checks are enabled.
            let updater = self.updaterController.updater
            if updater.automaticallyChecksForUpdates && !updater.sessionInProgress {
                updater.checkForUpdatesInBackground()
            }
        }
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
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

    private func bindExternalUpdateRequests() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleExternalUpdateRequest),
            name: .voceCheckForUpdatesRequested,
            object: nil
        )
    }

    private func refreshUpdaterState() {
        canCheckForUpdates = updaterController.updater.canCheckForUpdates
        automaticallyChecksForUpdates = updaterController.updater.automaticallyChecksForUpdates
    }

    @objc private func handleExternalUpdateRequest() {
        checkForUpdates()
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
