import CLIProxyManagerCore

struct AutomaticShellInstallService: Sendable {
    struct EnabledFunctions: Sendable {
        var claudeOAuth: Bool
        var codex: Bool
        var claudeAPI: Bool

        static let none = EnabledFunctions(claudeOAuth: false, codex: false, claudeAPI: false)
        static let allOAuth = EnabledFunctions(claudeOAuth: true, codex: true, claudeAPI: false)
    }

    private let installer: any ShellFunctionInstalling
    private let secretStore: any SecretStore
    private let defaultHelperCommand: String

    init(
        installer: any ShellFunctionInstalling,
        secretStore: any SecretStore = KeychainSecretStore(),
        helperCommand: String = "/usr/local/bin/cliproxy-manager"
    ) {
        self.installer = installer
        self.secretStore = secretStore
        self.defaultHelperCommand = helperCommand
    }

    func apply(config: AppConfig, helperCommand: String? = nil, enabledFunctions: EnabledFunctions = .allOAuth) throws {
        let includeClaudeOAuth = enabledFunctions.claudeOAuth && !config.commands.cc.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let includeCodex = enabledFunctions.codex && !config.commands.ccodex.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let includeClaudeAPI = try enabledFunctions.claudeAPI
            && !config.commands.ccapi.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && hasClaudeAPIKey()
        let script = try ShellFunctionRenderer(
            config: config,
            helperCommand: helperCommand ?? defaultHelperCommand,
            enabledFunctions: ShellFunctionRenderer.EnabledFunctions(
                claudeOAuth: includeClaudeOAuth,
                codex: includeCodex,
                claudeAPI: includeClaudeAPI
            )
        ).render()
        var functionNames: [String] = []
        if includeClaudeOAuth { functionNames.append(config.commands.cc) }
        if includeCodex { functionNames.append(config.commands.ccodex) }
        if includeClaudeAPI { functionNames.append(config.commands.ccapi) }
        try installer.install(functionScript: script, functionNames: functionNames)
    }

    private func hasClaudeAPIKey() throws -> Bool {
        do {
            return try !secretStore.get(.claudeAPIKey).isEmpty
        } catch SecretStoreError.missingSecret {
            return false
        }
    }
}
