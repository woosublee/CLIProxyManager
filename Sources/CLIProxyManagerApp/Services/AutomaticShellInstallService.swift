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
    private let isEnabled: Bool

    init(
        installer: any ShellFunctionInstalling,
        secretStore: any SecretStore = KeychainSecretStore(),
        helperCommand: String = "/usr/local/bin/cliproxy-manager",
        isEnabled: Bool = true
    ) {
        self.installer = installer
        self.secretStore = secretStore
        self.defaultHelperCommand = helperCommand
        self.isEnabled = isEnabled
    }

    static func runtimeDefault(installer: any ShellFunctionInstalling) -> AutomaticShellInstallService {
        #if DEBUG
        AutomaticShellInstallService(installer: installer, isEnabled: false)
        #else
        AutomaticShellInstallService(installer: installer)
        #endif
    }

    func apply(config: AppConfig, helperCommand: String? = nil, enabledFunctions: EnabledFunctions = .allOAuth) throws {
        guard isEnabled else { return }
        let includeClaudeOAuth = shouldIncludeOAuth(provider: .claude, config: config, enabled: enabledFunctions.claudeOAuth)
        let includeCodex = shouldIncludeOAuth(provider: .codex, config: config, enabled: enabledFunctions.codex)
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
        var functionNames = oauthFunctionNames(config: config, includeClaudeOAuth: includeClaudeOAuth, includeCodex: includeCodex)
        if includeClaudeAPI { functionNames.append(config.commands.ccapi) }
        try installer.install(functionScript: script, functionNames: functionNames)
    }

    private func shouldIncludeOAuth(provider: AuthProfileType, config: AppConfig, enabled: Bool) -> Bool {
        guard enabled else { return false }
        if config.oauthCommandProfiles.isEmpty {
            let hasLegacyCommand: Bool
            switch provider {
            case .claude:
                hasLegacyCommand = !config.commands.cc.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            case .codex:
                hasLegacyCommand = !config.commands.ccodex.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
            if hasLegacyCommand { return true }
        }

        let hasFixedCommand = config.oauthCommandProfiles.contains { commandProfile in
            commandProfile.provider == provider
                && commandProfile.isEnabled
                && !commandProfile.commandName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        let hasRoundRobinCommand = config.roundRobinProfiles.contains { roundRobinProfile in
            roundRobinProfile.provider == provider
                && roundRobinProfile.isEnabled
                && !roundRobinProfile.commandName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        return hasFixedCommand || hasRoundRobinCommand
    }

    private func oauthFunctionNames(config: AppConfig, includeClaudeOAuth: Bool, includeCodex: Bool) -> [String] {
        var names: [String]
        if config.oauthCommandProfiles.isEmpty {
            names = []
            let claudeCommandName = config.commands.cc.trimmingCharacters(in: .whitespacesAndNewlines)
            let codexCommandName = config.commands.ccodex.trimmingCharacters(in: .whitespacesAndNewlines)
            if includeClaudeOAuth, !claudeCommandName.isEmpty { names.append(claudeCommandName) }
            if includeCodex, !codexCommandName.isEmpty { names.append(codexCommandName) }
        } else {
            names = config.oauthCommandProfiles.compactMap { commandProfile in
                let included = commandProfile.provider == .claude ? includeClaudeOAuth : includeCodex
                let commandName = commandProfile.commandName.trimmingCharacters(in: .whitespacesAndNewlines)
                return included && commandProfile.isEnabled && !commandName.isEmpty ? commandName : nil
            }
        }
        names.append(contentsOf: config.roundRobinProfiles.compactMap { profile in
            let included = profile.provider == .claude ? includeClaudeOAuth : includeCodex
            let commandName = profile.commandName.trimmingCharacters(in: .whitespacesAndNewlines)
            return included && profile.isEnabled && !commandName.isEmpty ? commandName : nil
        })
        return names
    }

    private func hasClaudeAPIKey() throws -> Bool {
        do {
            return try !secretStore.get(.claudeAPIKey).isEmpty
        } catch SecretStoreError.missingSecret {
            return false
        }
    }
}
