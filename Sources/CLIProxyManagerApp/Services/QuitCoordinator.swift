import AppKit
import CLIProxyManagerCore

protocol AppTerminating: Sendable {
    func terminate()
}

protocol QuitConfirmationPresenting: Sendable {
    @MainActor func confirmQuit() -> Bool
}

struct NSAlertQuitConfirmationPresenter: QuitConfirmationPresenting {
    @MainActor func confirmQuit() -> Bool {
        let alert = NSAlert()
        alert.messageText = "Quit CLIProxyManager?"
        alert.informativeText = "The CLIProxyAPI server started by the app will also be stopped."
        alert.addButton(withTitle: "Stop Server and Quit")
        alert.addButton(withTitle: "Cancel")
        NSApplication.shared.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertFirstButtonReturn
    }
}

struct NSApplicationTerminator: AppTerminating {
    func terminate() {
        NSApplication.shared.terminate(nil)
    }
}

@MainActor
final class QuitCoordinator: ObservableObject {
    @Published var isQuitConfirmationPresented = false
    @Published private(set) var quitErrorMessage: String?

    private let proxyService: any ProxyServiceControlling
    private let appTerminator: any AppTerminating
    private let quitConfirmationPresenter: any QuitConfirmationPresenting
    private let shouldStopServerBeforeQuit: @MainActor @Sendable () -> Bool
    private let beforeTerminate: @MainActor @Sendable () async -> Void

    init(
        proxyService: any ProxyServiceControlling = BundledProxyBinary.serviceManager(),
        appTerminator: any AppTerminating = NSApplicationTerminator(),
        quitConfirmationPresenter: any QuitConfirmationPresenting = NSAlertQuitConfirmationPresenter(),
        shouldStopServerBeforeQuit: @escaping @MainActor @Sendable () -> Bool = { true },
        beforeTerminate: @escaping @MainActor @Sendable () async -> Void = {}
    ) {
        self.proxyService = proxyService
        self.appTerminator = appTerminator
        self.quitConfirmationPresenter = quitConfirmationPresenter
        self.shouldStopServerBeforeQuit = shouldStopServerBeforeQuit
        self.beforeTerminate = beforeTerminate
    }

    func requestQuit() {
        guard shouldStopServerBeforeQuit() else {
            Task { await finishTermination() }
            return
        }

        if quitConfirmationPresenter.confirmQuit() {
            Task { await confirmQuit() }
        }
    }

    func cancelQuit() {
        isQuitConfirmationPresented = false
    }

    func confirmQuit() async {
        isQuitConfirmationPresented = false
        quitErrorMessage = nil
        do {
            try await proxyService.stop()
            await finishTermination()
        } catch {
            quitErrorMessage = "Failed to stop the CLIProxyAPI server. Quit was cancelled."
        }
    }

    private func finishTermination() async {
        await beforeTerminate()
        appTerminator.terminate()
    }
}

extension ServerControlState {
    var shouldStopServerBeforeQuit: Bool {
        switch self {
        case .starting, .running, .stopping:
            return true
        case .stopped, .error:
            return false
        }
    }
}
