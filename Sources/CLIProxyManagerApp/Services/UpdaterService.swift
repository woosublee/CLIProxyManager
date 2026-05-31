import Combine
import Foundation
import Sparkle

struct UpdateSettingsCopy {
    static let automaticChecksLabel = "Check for updates"
    static let automaticChecksDescription = "Automatically check for new versions on launch."
    static let checkNowButtonTitle = "Check now"
}

@MainActor
final class UpdaterService: ObservableObject {
    private let updaterController: SPUStandardUpdaterController
    private var updaterObservationCancellables: Set<AnyCancellable> = []

    init() {
        self.updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )

        bridgeUpdaterChangesToSwiftUI()
    }

    var automaticallyChecksForUpdates: Bool {
        get { updaterController.updater.automaticallyChecksForUpdates }
        set {
            updaterController.updater.automaticallyChecksForUpdates = newValue
            objectWillChange.send()
        }
    }

    var canCheckForUpdates: Bool {
        updaterController.updater.canCheckForUpdates
    }

    func checkForUpdates() {
        updaterController.checkForUpdates(nil)
    }

    private func bridgeUpdaterChangesToSwiftUI() {
        updaterController.updater.publisher(for: \.canCheckForUpdates)
            .dropFirst()
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &updaterObservationCancellables)

        updaterController.updater.publisher(for: \.automaticallyChecksForUpdates)
            .dropFirst()
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &updaterObservationCancellables)
    }
}
