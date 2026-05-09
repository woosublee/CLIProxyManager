import XCTest
@testable import CLIProxyManagerCore

final class ShellFunctionRendererTests: XCTestCase {
    func testRenderUsesFunctionsNotAliasesOrGlobalExports() throws {
        let renderer = ShellFunctionRenderer(
            config: .default,
            helperCommand: "/usr/local/bin/cliproxy-manager"
        )

        let script = try renderer.render()

        XCTAssertTrue(script.contains("ccm() {"))
        XCTAssertTrue(script.contains("ccmapi() {"))
        XCTAssertTrue(script.contains("ccmcodex() {"))
        XCTAssertFalse(script.contains("alias cc="))
        XCTAssertFalse(script.contains("export ANTHROPIC_BASE_URL"))
        XCTAssertFalse(script.contains("export ANTHROPIC_AUTH_TOKEN"))
    }

    func testRenderPassesArgumentsThroughToClaude() throws {
        let script = try ShellFunctionRenderer(
            config: .default,
            helperCommand: "/usr/local/bin/cliproxy-manager"
        ).render()

        XCTAssertEqual(script.components(separatedBy: "claude \"$@\"").count - 1, 3)
    }

    func testClaudeOAuthFunctionUsesBundledProxyAndClaudeModelDefaults() throws {
        let script = try ShellFunctionRenderer(
            config: .default,
            helperCommand: "/usr/local/bin/cliproxy-manager"
        ).render()

        XCTAssertTrue(script.contains("ccm() {"))
        XCTAssertTrue(script.contains("ANTHROPIC_BASE_URL=\"http://127.0.0.1:18317\""))
        XCTAssertTrue(script.contains("ANTHROPIC_AUTH_TOKEN='sk-dummy'"))
        XCTAssertTrue(script.contains("ANTHROPIC_DEFAULT_OPUS_MODEL='claude-opus-4-7'"))
        XCTAssertTrue(script.contains("ANTHROPIC_DEFAULT_SONNET_MODEL='claude-sonnet-4-6'"))
        XCTAssertTrue(script.contains("ANTHROPIC_DEFAULT_HAIKU_MODEL='claude-haiku-4-5-20251001'"))
    }

    func testRenderUsesConfiguredModelsAndPort() throws {
        var config = AppConfig.default
        config.port = 8320
        config.ccapi.model = "claude-sonnet-4-6"
        config.ccodex = AppConfig.Codex(
            opus: AppConfig.CodexRole(model: "gpt-5.3-codex", reasoning: .xhigh, contextWindow: .auto),
            sonnet: AppConfig.CodexRole(model: "gpt-5.3-codex", reasoning: .medium, contextWindow: .auto),
            haiku: AppConfig.CodexRole(model: "gpt-5.3-codex", reasoning: .low, contextWindow: .auto)
        )

        let script = try ShellFunctionRenderer(
            config: config,
            helperCommand: "/opt/cliproxy-manager/bin/cliproxy-manager"
        ).render()

        XCTAssertTrue(script.contains("http://127.0.0.1:8320/v1/models"))
        XCTAssertTrue(script.contains("ANTHROPIC_MODEL='claude-sonnet-4-6'"))
        XCTAssertTrue(script.contains("ANTHROPIC_DEFAULT_OPUS_MODEL='gpt-5.3-codex(xhigh)'"))
        XCTAssertTrue(script.contains("ANTHROPIC_DEFAULT_SONNET_MODEL='gpt-5.3-codex(medium)'"))
        XCTAssertTrue(script.contains("ANTHROPIC_DEFAULT_HAIKU_MODEL='gpt-5.3-codex(low)'"))
        XCTAssertTrue(script.contains("'/opt/cliproxy-manager/bin/cliproxy-manager' secret get claude-api-key"))
    }

    func testRenderUsesConfiguredCodexRoleSettings() throws {
        var config = AppConfig.default
        config.port = 18_888
        config.ccodex = AppConfig.Codex(
            opus: AppConfig.CodexRole(model: "gpt-5.5", reasoning: .xhigh, contextWindow: .context1m),
            sonnet: AppConfig.CodexRole(model: "gpt-5.5", reasoning: .medium, contextWindow: .context400k),
            haiku: AppConfig.CodexRole(model: "gpt-5.5", reasoning: .auto, contextWindow: .auto)
        )

        let script = try ShellFunctionRenderer(
            config: config,
            helperCommand: "/usr/local/bin/cliproxy-manager"
        ).render()

        XCTAssertTrue(script.contains("ANTHROPIC_DEFAULT_OPUS_MODEL='gpt-5.5(xhigh)'"))
        XCTAssertTrue(script.contains("ANTHROPIC_DEFAULT_SONNET_MODEL='gpt-5.5(medium)'"))
        XCTAssertTrue(script.contains("ANTHROPIC_DEFAULT_HAIKU_MODEL='gpt-5.5'"))
        XCTAssertFalse(script.contains("1m"))
        XCTAssertFalse(script.contains("400k"))
    }

    func testCodexPrecheckUsesLocalAPIKeyHeader() throws {
        let script = try ShellFunctionRenderer(
            config: .default,
            helperCommand: "/usr/local/bin/cliproxy-manager"
        ).render()

        XCTAssertTrue(script.contains("curl -sf -H 'Authorization: Bearer sk-dummy'"))
        XCTAssertTrue(script.contains("http://127.0.0.1:18317/v1/models"))
    }

    func testDangerousPermissionFlagIsOptIn() throws {
        var config = AppConfig.default
        config.includeDangerouslySkipPermissions = true

        let script = try ShellFunctionRenderer(
            config: config,
            helperCommand: "/usr/local/bin/cliproxy-manager"
        ).render()

        XCTAssertTrue(script.contains("claude --dangerously-skip-permissions \"$@\""))
    }

    func testInvalidCommandNameThrows() {
        var config = AppConfig.default
        config.commands.cc = "bad;rm"

        XCTAssertThrowsError(try ShellFunctionRenderer(
            config: config,
            helperCommand: "/usr/local/bin/cliproxy-manager"
        ).render()) { error in
            XCTAssertEqual(error as? ShellFunctionRendererError, .invalidFunctionName("bad;rm"))
        }
    }

    func testInvalidPortsThrow() {
        for port in [0, 70_000] {
            var config = AppConfig.default
            config.port = port

            XCTAssertThrowsError(try ShellFunctionRenderer(
                config: config,
                helperCommand: "/usr/local/bin/cliproxy-manager"
            ).render()) { error in
                XCTAssertEqual(error as? ShellFunctionRendererError, .invalidPort(port))
            }
        }
    }

    func testModelStringIsRenderedAsSafeSingleQuotedLiteral() throws {
        var config = AppConfig.default
        let model = "foo$(touch /tmp/pwned)\"'\\bar"
        config.ccapi.model = model

        let script = try ShellFunctionRenderer(
            config: config,
            helperCommand: "/usr/local/bin/cliproxy-manager"
        ).render()

        XCTAssertTrue(script.contains("ANTHROPIC_MODEL='foo$(touch /tmp/pwned)\"'\\''\\bar'"))
        XCTAssertFalse(script.contains("ANTHROPIC_MODEL=\"\(model)\""))
    }

    func testCCAPIStopsWhenSecretHelperFails() throws {
        let script = try ShellFunctionRenderer(
            config: .default,
            helperCommand: "/usr/local/bin/cliproxy-manager"
        ).render()

        XCTAssertTrue(script.contains("local anthropic_auth_token"))
        XCTAssertTrue(script.contains("if ! anthropic_auth_token=\"$( '/usr/local/bin/cliproxy-manager' secret get claude-api-key )\"; then"))
        XCTAssertTrue(script.contains("Claude API key를 읽을 수 없습니다."))
        XCTAssertTrue(script.contains("return 1"))
        XCTAssertTrue(script.contains(#"ANTHROPIC_AUTH_TOKEN="$anthropic_auth_token" \"#))
    }

    func testHelperCommandPathWithSpacesAndSingleQuoteIsEscapedInCommandSubstitution() throws {
        let script = try ShellFunctionRenderer(
            config: .default,
            helperCommand: "/Applications/CLI Proxy/cliproxy-manager's bin"
        ).render()

        XCTAssertTrue(script.contains("if ! anthropic_auth_token=\"$( '/Applications/CLI Proxy/cliproxy-manager'\\''s bin' secret get claude-api-key )\"; then"))
    }

    func testDefaultGeneratedScriptPassesZshSyntaxCheck() throws {
        let script = try ShellFunctionRenderer(
            config: .default,
            helperCommand: "/usr/local/bin/cliproxy-manager"
        ).render()
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("zsh")
        try script.write(to: tempURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-n", tempURL.path]
        try process.run()
        process.waitUntilExit()

        XCTAssertEqual(process.terminationStatus, 0)
    }
}
