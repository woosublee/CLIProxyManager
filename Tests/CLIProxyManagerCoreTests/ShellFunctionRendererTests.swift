import XCTest
@testable import CLIProxyManagerCore

final class ShellFunctionRendererTests: XCTestCase {
    func testRenderUsesFunctionsNotAliasesOrGlobalExports() throws {
        let renderer = ShellFunctionRenderer(
            config: .default,
            helperCommand: "/usr/local/bin/cliproxy-manager"
        )

        let script = try renderer.render()

        XCTAssertTrue(script.contains("cc() {"))
        XCTAssertTrue(script.contains("ccapi() {"))
        XCTAssertTrue(script.contains("ccodex() {"))
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

    func testRenderUsesConfiguredModelsAndPort() throws {
        var config = AppConfig.default
        config.port = 8320
        config.ccapi.model = "claude-sonnet-4-6"
        config.ccodex.opusModel = "gpt-5.3-codex(xhigh)"
        config.ccodex.sonnetModel = "gpt-5.3-codex(medium)"
        config.ccodex.haikuModel = "gpt-5.3-codex(low)"

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

    func testHelperCommandPathWithSpacesAndSingleQuoteIsEscapedInCommandSubstitution() throws {
        let script = try ShellFunctionRenderer(
            config: .default,
            helperCommand: "/Applications/CLI Proxy/cliproxy-manager's bin"
        ).render()

        XCTAssertTrue(script.contains("ANTHROPIC_AUTH_TOKEN=\"$( '/Applications/CLI Proxy/cliproxy-manager'\\''s bin' secret get claude-api-key )\""))
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
