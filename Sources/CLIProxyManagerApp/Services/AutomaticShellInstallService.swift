import CLIProxyManagerCore

struct AutomaticShellInstallService: Sendable {
    private let installer: any ShellFunctionInstalling
    private let secretStore: any SecretStore
    private let helperCommand: String

    init(
        installer: any ShellFunctionInstalling,
        secretStore: any SecretStore = KeychainSecretStore(),
        helperCommand: String = "/usr/local/bin/cliproxy-manager"
    ) {
        self.installer = installer
        self.secretStore = secretStore
        self.helperCommand = helperCommand
    }

    func apply(config: AppConfig) throws {
        let includeClaudeAPI = (try? secretStore.get(.claudeAPIKey)).map { !$0.isEmpty } ?? false
        let script = try ShellFunctionRenderer(
            config: config,
            helperCommand: helperCommand,
            includeClaudeAPI: includeClaudeAPI
        ).render()
        var functionNames = [config.commands.cc, config.commands.ccodex]
        if includeClaudeAPI { functionNames.append(config.commands.ccapi) }
        try installer.install(functionScript: script, functionNames: functionNames)
    }
}
