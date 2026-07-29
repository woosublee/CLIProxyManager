import CLIProxyManagerCore
import Combine
import Foundation
import Sparkle

struct UpdateSettingsCopy {
    static let automaticChecksLabel = "Check for updates"
    static let automaticChecksDescription = "Automatically check for new versions on launch."
    static let checkNowButtonTitle = "Check now"
}

@MainActor
final class UpdaterService: NSObject, ObservableObject, SPUUpdaterDelegate {
    private var updaterController: SPUStandardUpdaterController!
    private let appLogger: any AppLogging
    private var updaterObservationCancellables: Set<AnyCancellable> = []

    init(appLogger: any AppLogging = DisabledAppLogger()) {
        self.appLogger = appLogger
        super.init()
        updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: self,
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
        appLogger.record(.update(target: .app, action: .check, result: .started))
        updaterController.checkForUpdates(nil)
    }

    func updater(
        _: SPUUpdater,
        didFinishUpdateCycleFor _: SPUUpdateCheck,
        error: Error?
    ) {
        appLogger.record(.update(
            target: .app,
            action: .check,
            result: error == nil ? .succeeded : .failed(.network)
        ))
    }

    func updater(_: SPUUpdater, didFindValidUpdate _: SUAppcastItem) {
        appLogger.record(.update(target: .app, action: .download, result: .started))
    }

    func updater(_: SPUUpdater, failedToDownloadUpdate _: SUAppcastItem, error _: Error) {
        appLogger.record(.update(target: .app, action: .download, result: .failed(.network)))
    }

    private func bridgeUpdaterChangesToSwiftUI() {
        updaterController.updater.publisher(for: \.canCheckForUpdates)
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &updaterObservationCancellables)

        updaterController.updater.publisher(for: \.automaticallyChecksForUpdates)
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &updaterObservationCancellables)
    }
}
