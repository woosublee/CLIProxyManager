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
    private let beforeTerminate: @MainActor @Sendable () async throws -> Void
    private let cancelTerminationPreparation: @MainActor @Sendable () -> Void
    private let terminationPreparationTimeoutNanoseconds: UInt64
    private let terminationSleep: @MainActor @Sendable (UInt64) async -> Void
    private var terminationState = TerminationState.idle

    init(
        proxyService: any ProxyServiceControlling = BundledProxyBinary.serviceManager(),
        appTerminator: any AppTerminating = NSApplicationTerminator(),
        quitConfirmationPresenter: any QuitConfirmationPresenting = NSAlertQuitConfirmationPresenter(),
        shouldStopServerBeforeQuit: @escaping @MainActor @Sendable () -> Bool = { true },
        beginTermination: @escaping @MainActor @Sendable () -> Void = {},
        beforeTerminate: @escaping @MainActor @Sendable () async throws -> Void = {},
        cancelTerminationPreparation: @escaping @MainActor @Sendable () -> Void = {},
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
        self.cancelTerminationPreparation = cancelTerminationPreparation
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
    }

    func confirmQuit() async {
        guard case .idle = terminationState else { return }
        beginTermination()
        terminationState = .preparingInternalRequest
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
        } catch {
            cancelTerminationPreparation()
            cancelTermination(
                completion: completion,
                message: "Failed to stop the CLIProxyAPI server. Quit was cancelled."
            )
            return
        }

        switch await prepareForTerminationWithinTimeout() {
        case .succeeded:
            switch completion {
            case .terminateInternally:
                terminationState = .authorizingInternalTermination
                appTerminator.terminate()
            case .replyToApplication(let reply):
                terminationState = .idle
                reply(true)
            }
        case .timedOut:
            cancelTerminationPreparation()
            cancelTermination(
                completion: completion,
                message: "Usage data could not be safely flushed before the timeout. Quit was cancelled."
            )
        case .failed:
            cancelTerminationPreparation()
            cancelTermination(
                completion: completion,
                message: "Usage data could not be safely flushed. Quit was cancelled."
            )
        }
    }

    private func cancelTermination(
        completion: TerminationCompletion,
        message: String
    ) {
        terminationState = .idle
        quitErrorMessage = message
        if case .replyToApplication(let reply) = completion {
            reply(false)
        }
    }

    fileprivate enum TerminationPreparationOutcome {
        case succeeded
        case timedOut
        case failed
    }

    private func prepareForTerminationWithinTimeout() async -> TerminationPreparationOutcome {
        let race = TerminationPreparationRace()
        let preparationTask = Task { [beforeTerminate] in
            do {
                try await beforeTerminate()
                await race.resolve(.succeeded)
            } catch {
                await race.resolve(.failed)
            }
        }
        let timeoutTask = Task { [terminationSleep, terminationPreparationTimeoutNanoseconds] in
            await terminationSleep(terminationPreparationTimeoutNanoseconds)
            await race.resolve(.timedOut)
        }
        let outcome = await race.value()
        switch outcome {
        case .succeeded, .failed:
            timeoutTask.cancel()
        case .timedOut:
            preparationTask.cancel()
        }
        return outcome
    }
}

private actor TerminationPreparationRace {
    private var result: QuitCoordinator.TerminationPreparationOutcome?
    private var continuation: CheckedContinuation<QuitCoordinator.TerminationPreparationOutcome, Never>?

    func resolve(_ value: QuitCoordinator.TerminationPreparationOutcome) {
        guard result == nil else { return }
        result = value
        continuation?.resume(returning: value)
        continuation = nil
    }

    func value() async -> QuitCoordinator.TerminationPreparationOutcome {
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
    var quitCoordinator: QuitCoordinator?
    var replyToApplicationShouldTerminate: @MainActor (NSApplication, Bool) -> Void = {
        application, shouldTerminate in
        application.reply(toApplicationShouldTerminate: shouldTerminate)
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let quitCoordinator else { return .terminateCancel }
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
