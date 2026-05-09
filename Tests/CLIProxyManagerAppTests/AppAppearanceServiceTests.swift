import XCTest
@testable import CLIProxyManagerApp
import CLIProxyManagerCore

@MainActor
final class AppAppearanceServiceTests: XCTestCase {
    func testInitializationAppliesSavedDockVisibility() {
        let appearanceService = StubAppAppearanceService()
        _ = DashboardViewModel(
            configStore: StubConfigStore(config: .default),
            shellInstaller: StubShellInstaller(),
            proxyService: StubProxyService(),
            claudeConnector: connectedClaudeConnector(),
            loginItemService: StubLoginItemService(),
            appAppearanceService: appearanceService
        )

        XCTAssertEqual(appearanceService.showDockIconValues, [true])
    }

    func testStartAtLoginToggleCallsLoginServiceAndPersistsConfig() throws {
        let store = StubConfigStore(config: .default)
        let loginService = StubLoginItemService()
        let viewModel = DashboardViewModel(
            configStore: store,
            shellInstaller: StubShellInstaller(),
            proxyService: StubProxyService(),
            claudeConnector: connectedClaudeConnector(),
            loginItemService: loginService,
            appAppearanceService: StubAppAppearanceService()
        )

        try viewModel.saveStartAtLogin(true)

        XCTAssertEqual(loginService.enabledValues, [true])
        XCTAssertEqual(store.savedConfigs.last?.startAtLogin, true)
    }

    func testStartAtLoginDoesNotUpdateLoginItemWhenConfigSaveFails() {
        let store = StubConfigStore(config: .default, saveError: NSError(domain: "test", code: 1))
        let loginService = StubLoginItemService()
        let viewModel = DashboardViewModel(
            configStore: store,
            shellInstaller: StubShellInstaller(),
            proxyService: StubProxyService(),
            claudeConnector: connectedClaudeConnector(),
            loginItemService: loginService,
            appAppearanceService: StubAppAppearanceService()
        )

        XCTAssertThrowsError(try viewModel.saveStartAtLogin(true))

        XCTAssertEqual(loginService.enabledValues, [])
        XCTAssertEqual(viewModel.config.startAtLogin, false)
    }

    func testDockIconToggleAppliesActivationPolicyAndPersistsConfig() throws {
        let store = StubConfigStore(config: .default)
        let appearanceService = StubAppAppearanceService()
        let viewModel = DashboardViewModel(
            configStore: store,
            shellInstaller: StubShellInstaller(),
            proxyService: StubProxyService(),
            claudeConnector: connectedClaudeConnector(),
            loginItemService: StubLoginItemService(),
            appAppearanceService: appearanceService
        )

        try viewModel.saveDockIconVisible(false)

        XCTAssertEqual(appearanceService.showDockIconValues, [true, false])
        XCTAssertEqual(store.savedConfigs.last?.showDockIcon, false)
    }

    func testMenuBarIconTogglePersistsConfig() throws {
        let store = StubConfigStore(config: .default)
        let viewModel = DashboardViewModel(
            configStore: store,
            shellInstaller: StubShellInstaller(),
            proxyService: StubProxyService(),
            claudeConnector: connectedClaudeConnector(),
            loginItemService: StubLoginItemService(),
            appAppearanceService: StubAppAppearanceService()
        )

        try viewModel.saveMenuBarIconVisible(false)

        XCTAssertEqual(store.savedConfigs.last?.showMenuBarIcon, false)
    }

    func testCannotHideBothDockAndMenuBarIcons() throws {
        var config = AppConfig.default
        config.showDockIcon = false
        config.showMenuBarIcon = true
        let store = StubConfigStore(config: config)
        let viewModel = DashboardViewModel(
            configStore: store,
            shellInstaller: StubShellInstaller(),
            proxyService: StubProxyService(),
            claudeConnector: connectedClaudeConnector(),
            loginItemService: StubLoginItemService(),
            appAppearanceService: StubAppAppearanceService()
        )

        try viewModel.saveMenuBarIconVisible(false)

        XCTAssertEqual(store.savedConfigs, [])
        XCTAssertEqual(viewModel.settingsMessage, "Dock 아이콘과 메뉴바 아이콘 중 하나는 켜져 있어야 합니다.")
    }

    private func connectedClaudeConnector() -> ClaudeConnector {
        ClaudeConnector(runner: StubProcessRunner(results: Array(repeating: [
            ProcessResult(exitCode: 0, stdout: "/usr/local/bin/claude\n", stderr: ""),
            ProcessResult(exitCode: 0, stdout: "로그인되어 있습니다.\n", stderr: ""),
            ProcessResult(exitCode: 0, stdout: "Logged in\n", stderr: "")
        ], count: 4).flatMap { $0 }))
    }
}

private final class StubConfigStore: AppConfigStoring, @unchecked Sendable {
    private let lock = NSLock()
    private let saveError: Error?
    private(set) var savedConfigs: [AppConfig] = []
    var config: AppConfig

    init(config: AppConfig, saveError: Error? = nil) {
        self.config = config
        self.saveError = saveError
    }

    func load() throws -> AppConfig { config }

    func save(_ config: AppConfig) throws {
        if let saveError {
            throw saveError
        }
        lock.withLock { savedConfigs.append(config) }
        self.config = config
    }
}

private final class StubShellInstaller: ShellFunctionInstalling, @unchecked Sendable {
    func install(functionScript: String, functionNames: [String]) throws {}
    func isInstalled() -> Bool { true }
}

private final class StubLoginItemService: LoginItemControlling, @unchecked Sendable {
    private let lock = NSLock()
    private var _enabledValues: [Bool] = []

    var enabledValues: [Bool] {
        lock.withLock { _enabledValues }
    }

    func setStartAtLoginEnabled(_ isEnabled: Bool) throws {
        lock.withLock { _enabledValues.append(isEnabled) }
    }
}

@MainActor
private final class StubAppAppearanceService: AppAppearanceApplying, @unchecked Sendable {
    private(set) var showDockIconValues: [Bool] = []

    func apply(showDockIcon: Bool) {
        showDockIconValues.append(showDockIcon)
    }
}

private final class StubProxyService: ProxyServiceControlling, @unchecked Sendable {
    func start(port: Int) async throws {}
    func stop() async throws {}
    func restart(port: Int) async throws {}
}

private final class StubProcessRunner: ProcessRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var results: [ProcessResult]

    init(results: [ProcessResult]) {
        self.results = results
    }

    func run(_ executable: String, _ arguments: [String]) async -> ProcessResult {
        lock.withLock {
            guard results.isEmpty == false else {
                XCTFail("Unexpected process run: \(executable) \(arguments.joined(separator: " "))")
                return ProcessResult(exitCode: 1, stdout: "", stderr: "unexpected process run")
            }
            return results.removeFirst()
        }
    }
}
