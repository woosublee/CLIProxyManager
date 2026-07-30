import CLIProxyManagerCore
import Foundation

enum ShellFunctionInstallationError: LocalizedError, Equatable, Sendable {
    case unsupportedLoginShell
    case claudeCodeUnavailable
    case runtimeIncompatible

    var errorDescription: String? {
        switch self {
        case .unsupportedLoginShell:
            "Shell functions require zsh as the login shell. Change the login shell to zsh, then retry."
        case .claudeCodeUnavailable:
            "Shell functions require the Claude executable. Install Claude Code, then retry."
        case .runtimeIncompatible:
            "Shell functions cannot be installed in this runtime. Use a supported runtime, then retry."
        }
    }
}

enum AutomaticShellInstallationResult: Equatable, Sendable {
    case written
    case skippedForCompatibility
    case skippedForSupersededRequest
    case disabled
}

private final class AutomaticShellReconciliationCoordinator: @unchecked Sendable {
    private let lock = NSLock()
    private var latestGeneration = 0

    func begin() -> AutomaticShellReconciliationRequest {
        let generation = lock.withLock { () -> Int in
            latestGeneration &+= 1
            return latestGeneration
        }
        return AutomaticShellReconciliationRequest(coordinator: self, generation: generation)
    }

    func invalidate() {
        lock.withLock { latestGeneration &+= 1 }
    }

    fileprivate func installIfCurrent(
        generation: Int,
        installer: any ShellFunctionInstalling,
        functionScript: String,
        functionNames: [String]
    ) throws -> Bool {
        try lock.withLock {
            guard generation == latestGeneration else { return false }
            try installer.install(functionScript: functionScript, functionNames: functionNames)
            return true
        }
    }
}

struct AutomaticShellReconciliationRequest: Sendable {
    private let coordinator: AutomaticShellReconciliationCoordinator
    private let generation: Int

    fileprivate init(coordinator: AutomaticShellReconciliationCoordinator, generation: Int) {
        self.coordinator = coordinator
        self.generation = generation
    }

    fileprivate func install(
        using installer: any ShellFunctionInstalling,
        functionScript: String,
        functionNames: [String]
    ) throws -> Bool {
        try coordinator.installIfCurrent(
            generation: generation,
            installer: installer,
            functionScript: functionScript,
            functionNames: functionNames
        )
    }
}

struct AutomaticShellInstallService: Sendable {
    struct EnabledFunctions: Sendable {
        var claudeOAuth: Bool
        var codex: Bool
        var apiKeyProfileIDs: Set<String>

        init(claudeOAuth: Bool, codex: Bool, apiKeyProfileIDs: Set<String>) {
            self.claudeOAuth = claudeOAuth
            self.codex = codex
            self.apiKeyProfileIDs = apiKeyProfileIDs
        }

        init(claudeOAuth: Bool, codex: Bool, claudeAPI: Bool, codexAPI: Bool = false) {
            var profileIDs: Set<String> = []
            if claudeAPI { profileIDs.insert("claude-api") }
            if codexAPI { profileIDs.insert("codex-api") }
            self.init(claudeOAuth: claudeOAuth, codex: codex, apiKeyProfileIDs: profileIDs)
        }

        static let none = EnabledFunctions(claudeOAuth: false, codex: false, apiKeyProfileIDs: [])
        static let allOAuth = EnabledFunctions(claudeOAuth: true, codex: true, apiKeyProfileIDs: [])
    }

    private let installer: any ShellFunctionInstalling
    private let secretStore: any SecretStore
    private let compatibilityAuthorizer: any RuntimeCompatibilityAuthorizing
    private let reconciliationCoordinator = AutomaticShellReconciliationCoordinator()
    private let defaultHelperCommand: String
    private let isEnabled: Bool

    init(
        installer: any ShellFunctionInstalling,
        secretStore: any SecretStore = FileSecretStore(),
        helperCommand: String = "/usr/local/bin/cliproxy-manager",
        compatibilityAuthorizer: any RuntimeCompatibilityAuthorizing = RuntimeCompatibilityPreflight(),
        isEnabled: Bool = true
    ) {
        self.installer = installer
        self.secretStore = secretStore
        self.compatibilityAuthorizer = compatibilityAuthorizer
        self.defaultHelperCommand = helperCommand
        self.isEnabled = isEnabled
    }

    static func runtimeDefault(
        installer: any ShellFunctionInstalling,
        secretStore: any SecretStore = FileSecretStore(),
        compatibilityAuthorizer: any RuntimeCompatibilityAuthorizing = RuntimeCompatibilityPreflight()
    ) -> AutomaticShellInstallService {
        AutomaticShellInstallService(
            installer: installer,
            secretStore: secretStore,
            helperCommand: resolvedDefaultHelperCommand(),
            compatibilityAuthorizer: compatibilityAuthorizer
        )
    }

    static func resolvedDefaultHelperCommand(
        currentExecutableURL: URL? = Bundle.main.executableURL,
        fileExists: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) -> String {
        if let currentExecutableURL {
            #if DEBUG
            // Prefer cpm, fall back to cliproxy-manager for pre-bootstrap installs
            let debugCpmPath = currentExecutableURL.deletingLastPathComponent().appendingPathComponent("cpm").path
            if fileExists(debugCpmPath) { return debugCpmPath }
            let debugLegacyPath = currentExecutableURL.deletingLastPathComponent().appendingPathComponent("cliproxy-manager").path
            if fileExists(debugLegacyPath) { return debugLegacyPath }
            #endif

            let macOSDirectory = currentExecutableURL.deletingLastPathComponent()
            let contentsDirectory = macOSDirectory.deletingLastPathComponent()
            let appBundleURL = contentsDirectory.deletingLastPathComponent()
            if macOSDirectory.lastPathComponent == "MacOS",
               contentsDirectory.lastPathComponent == "Contents",
               appBundleURL.pathExtension.lowercased() == "app" {
                let helpersDir = contentsDirectory.appendingPathComponent("Helpers")
                let cpmPath = helpersDir.appendingPathComponent("cpm").path
                if fileExists(cpmPath) { return cpmPath }
                let legacyPath = helpersDir.appendingPathComponent("cliproxy-manager").path
                if fileExists(legacyPath) { return legacyPath }
            }
        }
        // Prefer cpm if installed; fall back to cliproxy-manager for pre-bootstrap installs
        if fileExists("/usr/local/bin/cpm") { return "/usr/local/bin/cpm" }
        return "/usr/local/bin/cliproxy-manager"
    }

    func apply(
        config: AppConfig,
        helperCommand: String? = nil,
        enabledFunctions: EnabledFunctions = .allOAuth
    ) async throws {
        guard isEnabled else { return }
        reconciliationCoordinator.invalidate()
        try await preflight()
        let installation = try renderedInstallation(
            config: config,
            helperCommand: helperCommand,
            enabledFunctions: enabledFunctions
        )
        try installer.install(
            functionScript: installation.functionScript,
            functionNames: installation.functionNames
        )
    }

    func beginAutomaticReconciliation() -> AutomaticShellReconciliationRequest {
        reconciliationCoordinator.begin()
    }

    func reconcile(
        config: AppConfig,
        helperCommand: String? = nil,
        enabledFunctions: EnabledFunctions = .allOAuth,
        request: AutomaticShellReconciliationRequest? = nil
    ) async throws -> AutomaticShellInstallationResult {
        guard isEnabled else { return .disabled }
        let request = request ?? beginAutomaticReconciliation()
        do {
            try await preflight()
            let installation = try renderedInstallation(
                config: config,
                helperCommand: helperCommand,
                enabledFunctions: enabledFunctions
            )
            guard try request.install(
                using: installer,
                functionScript: installation.functionScript,
                functionNames: installation.functionNames
            ) else {
                return .skippedForSupersededRequest
            }
            return .written
        } catch is ShellFunctionInstallationError {
            return .skippedForCompatibility
        }
    }

    private func preflight() async throws {
        let report = await compatibilityAuthorizer.report(artifacts: CompatibilityArtifacts(
            bundled: nil,
            active: nil,
            pending: nil
        ))
        if let compatibilityError = compatibilityError(for: report) {
            throw compatibilityError
        }
    }

    private func renderedInstallation(
        config: AppConfig,
        helperCommand: String?,
        enabledFunctions: EnabledFunctions
    ) throws -> (functionScript: String, functionNames: [String]) {
        let includeClaudeOAuth = shouldIncludeOAuth(provider: .claude, config: config, enabled: enabledFunctions.claudeOAuth)
        let includeCodex = shouldIncludeOAuth(provider: .codex, config: config, enabled: enabledFunctions.codex)
        var includedAPIKeyProfileIDs: Set<String> = []
        for profile in config.apiKeyProfiles where enabledFunctions.apiKeyProfileIDs.contains(profile.id) {
            guard !profile.commandName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                continue
            }
            do {
                guard try hasAPIKey(profile.secretReference) else { continue }
                includedAPIKeyProfileIDs.insert(profile.id)
            } catch {
                continue
            }
        }
        let functionScript = try ShellFunctionRenderer(
            config: config,
            helperCommand: helperCommand ?? defaultHelperCommand,
            enabledFunctions: ShellFunctionRenderer.EnabledFunctions(
                claudeOAuth: includeClaudeOAuth,
                codex: includeCodex,
                apiKeyProfileIDs: includedAPIKeyProfileIDs
            )
        ).render()
        var functionNames = oauthFunctionNames(config: config, includeClaudeOAuth: includeClaudeOAuth, includeCodex: includeCodex)
        functionNames.append(contentsOf: config.apiKeyProfiles.compactMap { profile in
            includedAPIKeyProfileIDs.contains(profile.id) ? profile.commandName : nil
        })
        return (functionScript, functionNames)
    }

    private func compatibilityError(for report: RuntimeCompatibilityReport) -> ShellFunctionInstallationError? {
        if report.findings.contains(where: { finding in
            if case .unsupportedLoginShell = finding { return true }
            return false
        }) {
            return .unsupportedLoginShell
        }
        if report.findings.contains(where: { finding in
            if case .unavailableClaudeCode = finding { return true }
            return false
        }) {
            return .claudeCodeUnavailable
        }
        if report.decision(for: .installShellFunctions).disposition == .blocked {
            return .runtimeIncompatible
        }
        return nil
    }

    private func shouldIncludeOAuth(provider: AuthProfileType, config: AppConfig, enabled: Bool) -> Bool {
        guard enabled else { return false }
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
        var names = config.oauthCommandProfiles.compactMap { commandProfile in
            let included = commandProfile.provider == .claude ? includeClaudeOAuth : includeCodex
            let commandName = commandProfile.commandName.trimmingCharacters(in: .whitespacesAndNewlines)
            return included && commandProfile.isEnabled && !commandName.isEmpty ? commandName : nil
        }
        names.append(contentsOf: config.roundRobinProfiles.compactMap { profile in
            let included = profile.provider == .claude ? includeClaudeOAuth : includeCodex
            let commandName = profile.commandName.trimmingCharacters(in: .whitespacesAndNewlines)
            return included && profile.isEnabled && !commandName.isEmpty ? commandName : nil
        })
        return names
    }

    private func hasAPIKey(_ key: SecretReference) throws -> Bool {
        do {
            return try !secretStore.get(key).isEmpty
        } catch SecretStoreError.missingSecret {
            return false
        }
    }
}
