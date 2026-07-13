import XCTest
@testable import CLIProxyManagerApp
import CLIProxyManagerCore

final class MenuBarStatusSnapshotTests: XCTestCase {
    func testSnapshotShowsServerStatusAndConnectedProviderFunctionNames() {
        let snapshot = MenuBarStatusSnapshot(
            serverStatus: DiagnosticStatus(
                severity: .ready,
                title: "CLIProxyAPI Running",
                message: "Models are available on port 18317."
            ),
            providers: [
                ProviderRowState(
                    id: .claude,
                    name: "Claude OAuth",
                    nickname: "",
                    functionName: "ccm",
                    connectionTitle: "Connected",
                    connectionDetail: "claude@example.com",
                    isConnected: true
                ),
                ProviderRowState(
                    id: .codex,
                    name: "Codex OAuth",
                    nickname: "",
                    functionName: "ccmcodex",
                    connectionTitle: "Connected",
                    connectionDetail: "codex@example.com",
                    isConnected: true
                )
            ]
        )

        XCTAssertEqual(snapshot.serverTitle, "CLIProxyAPI Running")
        XCTAssertEqual(snapshot.serverDetail, "Models are available on port 18317.")
        XCTAssertTrue(snapshot.isServerRunning)
        XCTAssertEqual(snapshot.serverActionTitle, "Stop Server")
        XCTAssertEqual(snapshot.endpointTitle, "localhost:18317")
        XCTAssertEqual(snapshot.connectedProviders.map { $0.name }, ["Claude OAuth", "Codex OAuth"])
        XCTAssertEqual(snapshot.connectedProviders.map { $0.menuBarDisplayName }, ["Claude OAuth", "Codex OAuth"])
        XCTAssertEqual(snapshot.connectedProviders.map { $0.functionName }, ["ccm", "ccmcodex"])
        XCTAssertEqual(snapshot.connectedProviders.map { $0.connectionDetail }, ["claude@example.com", "codex@example.com"])
    }

    func testSnapshotCarriesAvailableSubscriptionUsageAndPrivacyState() {
        let snapshot = MenuBarStatusSnapshot(
            serverStatus: DiagnosticStatus(severity: .ready, title: "CLIProxyAPI Running", message: "Ready"),
            providers: [
                ProviderRowState(
                    id: .claude,
                    name: "Claude OAuth",
                    nickname: "",
                    functionName: "ccm",
                    connectionTitle: "Connected",
                    connectionDetail: "claude@example.com",
                    isConnected: true,
                    accountDetailHidden: false,
                    subscriptionUsageState: .available(
                        SubscriptionUsageSnapshot(
                            profileID: "claude.json",
                            provider: .claude,
                            windows: [UsageWindow(id: "five_hour", label: "5h", usedPercent: 52, resetAt: nil)],
                            fetchedAt: Date(timeIntervalSince1970: 0)
                        )
                    )
                )
            ]
        )

        guard let provider = snapshot.connectedProviders.first else {
            return XCTFail("Expected connected provider")
        }
        XCTAssertFalse(provider.accountDetailHidden)
        XCTAssertEqual(provider.menuBarConnectionDetail, "claude@example.com")
        guard case let .available(usage) = provider.subscriptionUsageState else {
            return XCTFail("Expected subscription usage")
        }
        XCTAssertEqual(usage.windows.map(\.id), ["five_hour"])
    }

    func testSnapshotKeepsNicknameVisibleWhileHidingConnectionDetail() {
        let snapshot = MenuBarStatusSnapshot(
            serverStatus: DiagnosticStatus(severity: .ready, title: "CLIProxyAPI Running", message: "Ready"),
            providers: [
                ProviderRowState(
                    id: .claude,
                    name: "Claude OAuth",
                    nickname: "Personal",
                    functionName: "ccm",
                    connectionTitle: "Connected",
                    connectionDetail: "private@example.com",
                    isConnected: true,
                    accountDetailHidden: true,
                    subscriptionUsageState: .available(
                        SubscriptionUsageSnapshot(
                            profileID: "claude.json",
                            provider: .claude,
                            windows: [UsageWindow(id: "five_hour", label: "5h", usedPercent: 52, resetAt: nil)],
                            fetchedAt: Date(timeIntervalSince1970: 0)
                        )
                    )
                )
            ]
        )

        let provider = try! XCTUnwrap(snapshot.connectedProviders.first)
        XCTAssertEqual(provider.menuBarDisplayName, "Personal")
        XCTAssertEqual(provider.usageOverlayDisplayName, "Personal")
        XCTAssertNil(provider.menuBarConnectionDetail)
        guard case let .available(usage) = provider.subscriptionUsageState else {
            return XCTFail("Expected available subscription usage")
        }
        XCTAssertEqual(usage.windows.map(\.id), ["five_hour"])
    }

    func testSnapshotPreservesUsageWindowCountsAndOrder() {
        let snapshot = MenuBarStatusSnapshot(
            serverStatus: DiagnosticStatus(severity: .ready, title: "CLIProxyAPI Running", message: "Ready"),
            providers: [
                ProviderRowState(
                    id: .claude,
                    name: "Claude OAuth",
                    nickname: "",
                    functionName: "ccm",
                    connectionTitle: "Connected",
                    connectionDetail: "claude@example.com",
                    isConnected: true,
                    accountDetailHidden: false,
                    subscriptionUsageState: .available(
                        SubscriptionUsageSnapshot(
                            profileID: "claude.json",
                            provider: .claude,
                            windows: [
                                UsageWindow(id: "five_hour", label: "5h", usedPercent: 20, resetAt: nil),
                                UsageWindow(id: "seven_day", label: "7d", usedPercent: 40, resetAt: nil)
                            ],
                            fetchedAt: Date(timeIntervalSince1970: 0)
                        )
                    )
                ),
                ProviderRowState(
                    id: .codex,
                    name: "Codex OAuth",
                    nickname: "",
                    functionName: "ccmcodex",
                    connectionTitle: "Connected",
                    connectionDetail: "codex@example.com",
                    isConnected: true,
                    accountDetailHidden: false,
                    subscriptionUsageState: .available(
                        SubscriptionUsageSnapshot(
                            profileID: "codex.json",
                            provider: .codex,
                            windows: [UsageWindow(id: "primary", label: "Primary", usedPercent: 60, resetAt: nil)],
                            fetchedAt: Date(timeIntervalSince1970: 0)
                        )
                    )
                )
            ]
        )

        let windowIDs = snapshot.connectedProviders.map { provider -> [String] in
            guard case let .available(usage) = provider.subscriptionUsageState else { return [] }
            return usage.windows.map(\.id)
        }
        XCTAssertEqual(windowIDs, [["five_hour", "seven_day"], ["primary"]])
    }

    func testCodexUsageWindowLabelsUseReportedPeriods() {
        XCTAssertEqual(
            subscriptionUsageDisplayLabel(
                for: UsageWindow(
                    id: "primary",
                    label: "Primary",
                    usedPercent: 0,
                    resetAt: nil,
                    limitWindowSeconds: 18_000
                )
            ),
            "5h"
        )
        XCTAssertEqual(
            subscriptionUsageDisplayLabel(
                for: UsageWindow(
                    id: "secondary",
                    label: "Secondary",
                    usedPercent: 0,
                    resetAt: nil,
                    limitWindowSeconds: 604_800
                )
            ),
            "7d"
        )
        XCTAssertEqual(
            subscriptionUsageDisplayLabel(
                for: UsageWindow(
                    id: "primary",
                    label: "Primary",
                    usedPercent: 0,
                    resetAt: nil,
                    limitWindowSeconds: 2_628_000
                )
            ),
            "1mo"
        )
    }

    func testSnapshotPreservesAvailableUsageWithNoWindowsForFallbackRendering() {
        let snapshot = MenuBarStatusSnapshot(
            serverStatus: DiagnosticStatus(severity: .ready, title: "CLIProxyAPI Running", message: "Ready"),
            providers: [
                ProviderRowState(
                    id: .claude,
                    name: "Claude OAuth",
                    nickname: "",
                    functionName: "ccm",
                    connectionTitle: "Connected",
                    connectionDetail: "claude@example.com",
                    isConnected: true,
                    accountDetailHidden: false,
                    subscriptionUsageState: .available(
                        SubscriptionUsageSnapshot(
                            profileID: "claude.json",
                            provider: .claude,
                            windows: [],
                            fetchedAt: Date(timeIntervalSince1970: 0)
                        )
                    )
                )
            ]
        )

        guard case let .available(usage)? = snapshot.connectedProviders.first?.subscriptionUsageState else {
            return XCTFail("Expected available subscription usage")
        }
        XCTAssertTrue(usage.windows.isEmpty)
    }

    func testProxyUnavailableUsageStateIsHiddenBeforeServerStarts() {
        let snapshot = MenuBarStatusSnapshot(
            serverStatus: DiagnosticStatus(severity: .warning, title: "CLIProxyAPI Stopped", message: "Stopped"),
            providers: [
                ProviderRowState(
                    id: .claude,
                    name: "Claude OAuth",
                    nickname: "",
                    functionName: "ccm",
                    connectionTitle: "Connected",
                    connectionDetail: "claude@example.com",
                    isConnected: true,
                    accountDetailHidden: false,
                    subscriptionUsageState: .unavailable(.proxyUnavailable)
                )
            ]
        )

        let provider = try! XCTUnwrap(snapshot.connectedProviders.first)
        XCTAssertFalse(provider.subscriptionUsageState.shouldDisplayInMenuBar)
    }

    func testUsageProgressToneThresholds() {
        XCTAssertEqual(subscriptionUsageProgressTone(for: 0), .normal)
        XCTAssertEqual(subscriptionUsageProgressTone(for: 49.9), .normal)
        XCTAssertEqual(subscriptionUsageProgressTone(for: 50), .warning)
        XCTAssertEqual(subscriptionUsageProgressTone(for: 79.9), .warning)
        XCTAssertEqual(subscriptionUsageProgressTone(for: 80), .critical)
        XCTAssertEqual(subscriptionUsageProgressTone(for: 100), .critical)
    }

    func testUsageProgressAccessibilityLabelIncludesUsageAndResetTime() {
        let window = UsageWindow(
            id: "five_hour",
            label: "5h",
            usedPercent: 52,
            resetAt: Date(timeIntervalSince1970: 0)
        )

        let label = subscriptionUsageAccessibilityLabel(for: window)

        XCTAssertTrue(label.contains("5h"))
        XCTAssertTrue(label.contains("52"))
        XCTAssertTrue(label.contains("resets"))
    }

    func testSnapshotExcludesDisabledConnectedProviders() {
        let snapshot = MenuBarStatusSnapshot(
            serverStatus: DiagnosticStatus(severity: .ready, title: "CLIProxyAPI Running", message: "Ready"),
            providers: [
                ProviderRowState(
                    id: .claude,
                    name: "Claude OAuth",
                    nickname: "",
                    functionName: "ccm",
                    connectionTitle: "Connected",
                    connectionDetail: "claude@example.com",
                    isConnected: true,
                    isDisabled: true
                ),
                ProviderRowState(
                    id: .codex,
                    name: "Codex OAuth",
                    nickname: "",
                    functionName: "ccmcodex",
                    connectionTitle: "Connected",
                    connectionDetail: "codex@example.com",
                    isConnected: true
                )
            ]
        )

        XCTAssertEqual(snapshot.connectedProviders.map(\.id), [.codex])
    }

    func testSnapshotKeepsConnectedAPIKeyAccountsWithoutSubscriptionUsage() {
        let snapshot = MenuBarStatusSnapshot(
            serverStatus: DiagnosticStatus(severity: .ready, title: "CLIProxyAPI Running", message: "Ready"),
            providers: [
                ProviderRowState(
                    id: .claudeAPI,
                    name: "Claude API Key",
                    nickname: "Work API",
                    functionName: "claude-api",
                    connectionTitle: "Configured",
                    connectionDetail: "API key configured",
                    isConnected: true,
                    showsSubscriptionUsage: false
                )
            ]
        )

        XCTAssertEqual(snapshot.connectedProviders.map(\.id), [.claudeAPI])
        XCTAssertEqual(snapshot.connectedProviders.first?.displayName, "Work API")
        XCTAssertEqual(snapshot.connectedProviders.first?.menuBarDisplayName, "Work API")
        XCTAssertEqual(snapshot.connectedProviders.first?.subscriptionUsageState, .disabled)
        XCTAssertEqual(snapshot.connectedProviders.first?.showsSubscriptionUsage, false)
    }

    func testSnapshotPropagatesSubscriptionUsageCapabilityForOAuthAccounts() {
        let snapshot = MenuBarStatusSnapshot(
            serverStatus: DiagnosticStatus(severity: .ready, title: "CLIProxyAPI Running", message: "Ready"),
            providers: [
                ProviderRowState(
                    id: .claude,
                    name: "Claude OAuth",
                    nickname: "Personal",
                    functionName: "ccm",
                    connectionTitle: "Connected",
                    connectionDetail: "claude@example.com",
                    isConnected: true,
                    subscriptionUsageState: .disabled,
                    showsSubscriptionUsage: true
                )
            ]
        )

        XCTAssertEqual(snapshot.connectedProviders.first?.showsSubscriptionUsage, true)
    }

    func testSnapshotShowsEmptyMessageWhenNoProviderIsConnected() {
        let snapshot = MenuBarStatusSnapshot(
            serverStatus: DiagnosticStatus(
                severity: .warning,
                title: "Needs check",
                message: "Server status has not been checked yet."
            ),
            providers: [
                ProviderRowState(
                    id: .claude,
                    name: "Claude",
                    nickname: "",
                    functionName: "ccm",
                    connectionTitle: "Needs check",
                    connectionDetail: "Check the Claude Code OAuth status.",
                    isConnected: false
                )
            ]
        )

        XCTAssertEqual(snapshot.connectedProviders, [])
        XCTAssertFalse(snapshot.isServerRunning)
        XCTAssertEqual(snapshot.serverActionTitle, "Start Server")
        XCTAssertEqual(snapshot.endpointTitle, nil)
        XCTAssertEqual(snapshot.emptyProviderMessage, "No connected accounts")
    }

    func testSnapshotCountsErroredProvidersFromStructuredState() {
        let snapshot = MenuBarStatusSnapshot(
            serverStatus: DiagnosticStatus(
                severity: .ready,
                title: "CLIProxyAPI Running",
                message: "Models are available on port 18317."
            ),
            providers: [
                ProviderRowState(
                    id: .claude,
                    name: "Claude OAuth",
                    nickname: "",
                    functionName: "ccm",
                    connectionTitle: "Authentication failed",
                    connectionDetail: "The token has expired.",
                    isConnected: false,
                    isErrored: true
                ),
                ProviderRowState(
                    id: .codex,
                    name: "Codex OAuth",
                    nickname: "",
                    functionName: "ccmcodex",
                    connectionTitle: "Needs connection",
                    connectionDetail: "Connect the Codex OAuth profile.",
                    isConnected: false
                )
            ]
        )

        XCTAssertEqual(snapshot.erroredCount, 1)
    }

    func testReadyServerStatusWinsOverStaleControlError() {
        let snapshot = MenuBarStatusSnapshot(
            serverStatus: DiagnosticStatus(
                severity: .ready,
                title: "CLIProxyAPI Running",
                message: "Models are available on port 18317."
            ),
            serverControlState: .error("Previous failure"),
            providers: []
        )

        XCTAssertEqual(snapshot.statusLabel, "Running")
        XCTAssertEqual(snapshot.indicatorState, .running)
        XCTAssertTrue(snapshot.isServerRunning)
        XCTAssertEqual(snapshot.serverActionTitle, "Stop Server")
        XCTAssertEqual(snapshot.endpointTitle, "localhost:18317")
    }

    func testTransitionControlStateWinsOverServerStatus() {
        let starting = MenuBarStatusSnapshot(
            serverStatus: DiagnosticStatus(
                severity: .warning,
                title: "CLIProxyAPI Stopped",
                message: "The server is not responding on the configured port."
            ),
            serverControlState: .starting,
            providers: []
        )
        let stopping = MenuBarStatusSnapshot(
            serverStatus: DiagnosticStatus(
                severity: .ready,
                title: "CLIProxyAPI Running",
                message: "Models are available on port 18317."
            ),
            serverControlState: .stopping,
            providers: []
        )

        XCTAssertEqual(starting.statusLabel, "Starting")
        XCTAssertEqual(starting.indicatorState, .running)
        XCTAssertEqual(stopping.statusLabel, "Stopping")
        XCTAssertEqual(stopping.indicatorState, .stopped)
    }
}
