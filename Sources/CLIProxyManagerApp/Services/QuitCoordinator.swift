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
        alert.messageText = "CLIProxyManager를 종료할까요?"
        alert.informativeText = "앱이 시작한 CLIProxyAPI 서버도 함께 종료됩니다."
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
    private let isServerRunning: @MainActor @Sendable () -> Bool

    init(
        proxyService: any ProxyServiceControlling = BundledProxyBinary.serviceManager(),
        appTerminator: any AppTerminating = NSApplicationTerminator(),
        quitConfirmationPresenter: any QuitConfirmationPresenting = NSAlertQuitConfirmationPresenter(),
        isServerRunning: @escaping @MainActor @Sendable () -> Bool = { true }
    ) {
        self.proxyService = proxyService
        self.appTerminator = appTerminator
        self.quitConfirmationPresenter = quitConfirmationPresenter
        self.isServerRunning = isServerRunning
    }

    func requestQuit() {
        guard isServerRunning() else {
            appTerminator.terminate()
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
            appTerminator.terminate()
        } catch {
            quitErrorMessage = "CLIProxyAPI 서버 종료에 실패했습니다. 앱 종료를 중단했습니다."
        }
    }
}
