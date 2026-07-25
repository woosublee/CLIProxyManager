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

    private enum TerminationState {
        case idle
        case preparingInternalRequest
        case preparingApplicationRequest
        case authorizingInternalTermination
    }

    private let proxyService: any ProxyServiceControlling
    private let appTerminator: any AppTerminating
    private let quitConfirmationPresenter: any QuitConfirmationPresenting
    private let shouldStopServerBeforeQuit: @MainActor @Sendable () -> Bool
    private let beginTermination: @MainActor @Sendable () -> Void
    private let beforeTerminate: @MainActor @Sendable () async -> Void
    private let terminationPreparationTimeoutNanoseconds: UInt64
    private let terminationSleep: @MainActor @Sendable (UInt64) async -> Void
    private var terminationState = TerminationState.idle

    init(
        proxyService: any ProxyServiceControlling = BundledProxyBinary.serviceManager(),
        appTerminator: any AppTerminating = NSApplicationTerminator(),
        quitConfirmationPresenter: any QuitConfirmationPresenting = NSAlertQuitConfirmationPresenter(),
        shouldStopServerBeforeQuit: @escaping @MainActor @Sendable () -> Bool = { true },
        beginTermination: @escaping @MainActor @Sendable () -> Void = {},
        beforeTerminate: @escaping @MainActor @Sendable () async -> Void = {},
        terminationPreparationTimeoutNanoseconds: UInt64 = 20_000_000_000,
        terminationSleep: @escaping @MainActor @Sendable (UInt64) async -> Void = { delay in
            try? await Task.sleep(nanoseconds: delay)
        }
    ) {
        self.proxyService = proxyService
        self.appTerminator = appTerminator
        self.quitConfirmationPresenter = quitConfirmationPresenter
        self.shouldStopServerBeforeQuit = shouldStopServerBeforeQuit
        self.beginTermination = beginTermination
        self.beforeTerminate = beforeTerminate
        self.terminationPreparationTimeoutNanoseconds = terminationPreparationTimeoutNanoseconds
        self.terminationSleep = terminationSleep
    }

    func requestQuit() {
        guard case .idle = terminationState else { return }
        let shouldStopServer = shouldStopServerBeforeQuit()
        if shouldStopServer, !quitConfirmationPresenter.confirmQuit() {
            return
        }

        beginTermination()
        terminationState = .preparingInternalRequest
        Task {
            await completeTermination(
                shouldStopServer: shouldStopServer,
                completion: .terminateInternally
            )
        }
    }

    func applicationShouldTerminate(
        reply: @escaping @MainActor (Bool) -> Void
    ) -> NSApplication.TerminateReply {
        switch terminationState {
        case .authorizingInternalTermination:
            terminationState = .idle
            return .terminateNow
        case .preparingInternalRequest, .preparingApplicationRequest:
            return .terminateLater
        case .idle:
            break
        }

        let shouldStopServer = shouldStopServerBeforeQuit()
        if shouldStopServer, !quitConfirmationPresenter.confirmQuit() {
            return .terminateCancel
        }

        beginTermination()
        terminationState = .preparingApplicationRequest
        Task {
            await completeTermination(
                shouldStopServer: shouldStopServer,
                completion: .replyToApplication(reply)
            )
        }
        return .terminateLater
    }

    func cancelQuit() {
        isQuitConfirmationPresented = false
        terminationState = .idle
    }

    func confirmQuit() async {
        if case .idle = terminationState {
            beginTermination()
            terminationState = .preparingInternalRequest
        }
        await completeTermination(
            shouldStopServer: true,
            completion: .terminateInternally
        )
    }

    private enum TerminationCompletion {
        case terminateInternally
        case replyToApplication(@MainActor (Bool) -> Void)
    }

    private func completeTermination(
        shouldStopServer: Bool,
        completion: TerminationCompletion
    ) async {
        isQuitConfirmationPresented = false
        quitErrorMessage = nil
        do {
            if shouldStopServer {
                try await proxyService.stop()
            }
            guard await prepareForTerminationWithinTimeout() else {
                terminationState = .idle
                quitErrorMessage = "Usage data could not be safely flushed before the timeout. Quit was cancelled."
                if case .replyToApplication(let reply) = completion {
                    reply(false)
                }
                return
            }
            switch completion {
            case .terminateInternally:
                terminationState = .authorizingInternalTermination
                appTerminator.terminate()
            case .replyToApplication(let reply):
                terminationState = .idle
                reply(true)
            }
        } catch {
            terminationState = .idle
            quitErrorMessage = "Failed to stop the CLIProxyAPI server. Quit was cancelled."
            if case .replyToApplication(let reply) = completion {
                reply(false)
            }
        }
    }

    private func prepareForTerminationWithinTimeout() async -> Bool {
        let race = TerminationPreparationRace()
        let preparationTask = Task { [beforeTerminate] in
            await beforeTerminate()
            await race.resolve(true)
        }
        let timeoutTask = Task { [terminationSleep, terminationPreparationTimeoutNanoseconds] in
            await terminationSleep(terminationPreparationTimeoutNanoseconds)
            await race.resolve(false)
        }
        let succeeded = await race.value()
        if succeeded {
            timeoutTask.cancel()
        } else {
            preparationTask.cancel()
        }
        return succeeded
    }
}

private actor TerminationPreparationRace {
    private var result: Bool?
    private var continuation: CheckedContinuation<Bool, Never>?

    func resolve(_ value: Bool) {
        guard result == nil else { return }
        result = value
        continuation?.resume(returning: value)
        continuation = nil
    }

    func value() async -> Bool {
        if let result { return result }
        return await withCheckedContinuation { continuation in
            if let result {
                continuation.resume(returning: result)
            } else {
                self.continuation = continuation
            }
        }
    }
}

@MainActor
final class ApplicationTerminationDelegate: NSObject, NSApplicationDelegate {
    weak var quitCoordinator: QuitCoordinator?
    var replyToApplicationShouldTerminate: @MainActor (NSApplication, Bool) -> Void = {
        application, shouldTerminate in
        application.reply(toApplicationShouldTerminate: shouldTerminate)
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let quitCoordinator else { return .terminateNow }
        return quitCoordinator.applicationShouldTerminate { [weak self] shouldTerminate in
            self?.replyToApplicationShouldTerminate(sender, shouldTerminate)
        }
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
