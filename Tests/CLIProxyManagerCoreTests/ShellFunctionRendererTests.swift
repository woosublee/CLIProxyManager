import XCTest
@testable import CLIProxyManagerCore

final class ShellFunctionRendererTests: XCTestCase {
    func testRenderUsesFunctionsNotAliasesOrGlobalExports() {
        let renderer = ShellFunctionRenderer(
            config: .default,
            helperCommand: "/usr/local/bin/cliproxy-manager"
        )

        let script = renderer.render()

        XCTAssertTrue(script.contains("cc() {"))
        XCTAssertTrue(script.contains("ccapi() {"))
        XCTAssertTrue(script.contains("ccodex() {"))
        XCTAssertFalse(script.contains("alias cc="))
        XCTAssertFalse(script.contains("export ANTHROPIC_BASE_URL"))
        XCTAssertFalse(script.contains("export ANTHROPIC_AUTH_TOKEN"))
    }

    func testRenderPassesArgumentsThroughToClaude() {
        let script = ShellFunctionRenderer(
            config: .default,
            helperCommand: "/usr/local/bin/cliproxy-manager"
        ).render()

        XCTAssertEqual(script.components(separatedBy: "claude \"$@\"").count - 1, 3)
    }

    func testRenderUsesConfiguredModelsAndPort() {
        var config = AppConfig.default
        config.port = 8320
        config.ccapi.model = "claude-sonnet-4-6"
        config.ccodex.opusModel = "gpt-5.3-codex(xhigh)"
        config.ccodex.sonnetModel = "gpt-5.3-codex(medium)"
        config.ccodex.haikuModel = "gpt-5.3-codex(low)"

        let script = ShellFunctionRenderer(
            config: config,
            helperCommand: "/opt/cliproxy-manager/bin/cliproxy-manager"
        ).render()

        XCTAssertTrue(script.contains("http://127.0.0.1:8320/v1/models"))
        XCTAssertTrue(script.contains("ANTHROPIC_MODEL=\"claude-sonnet-4-6\""))
        XCTAssertTrue(script.contains("ANTHROPIC_DEFAULT_OPUS_MODEL=\"gpt-5.3-codex(xhigh)\""))
        XCTAssertTrue(script.contains("ANTHROPIC_DEFAULT_SONNET_MODEL=\"gpt-5.3-codex(medium)\""))
        XCTAssertTrue(script.contains("ANTHROPIC_DEFAULT_HAIKU_MODEL=\"gpt-5.3-codex(low)\""))
        XCTAssertTrue(script.contains("/opt/cliproxy-manager/bin/cliproxy-manager secret get claude-api-key"))
    }

    func testDangerousPermissionFlagIsOptIn() {
        var config = AppConfig.default
        config.includeDangerouslySkipPermissions = true

        let script = ShellFunctionRenderer(
            config: config,
            helperCommand: "/usr/local/bin/cliproxy-manager"
        ).render()

        XCTAssertTrue(script.contains("claude --dangerously-skip-permissions \"$@\""))
    }
}
