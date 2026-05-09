import CLIProxyManagerCore

struct AutomaticShellInstallService: Sendable {
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

    func apply(config: AppConfig, helperCommand: String? = nil) throws {
        let includeClaudeAPI: Bool
        do {
            includeClaudeAPI = try !secretStore.get(.claudeAPIKey).isEmpty
        } catch SecretStoreError.missingSecret {
            includeClaudeAPI = false
        }
        let script = try ShellFunctionRenderer(
            config: config,
            helperCommand: helperCommand ?? defaultHelperCommand,
            includeClaudeAPI: includeClaudeAPI
        ).render()
        var functionNames = [config.commands.cc, config.commands.ccodex]
        if includeClaudeAPI { functionNames.append(config.commands.ccapi) }
        try installer.install(functionScript: script, functionNames: functionNames)
    }
}
