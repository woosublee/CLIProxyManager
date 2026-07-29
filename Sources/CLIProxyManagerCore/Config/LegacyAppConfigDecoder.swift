import Foundation

public struct LegacyOAuthProviderDefaults: Equatable, Sendable {
    public var commandName: String
    public var nickname: String
    public var accountDetailHidden: Bool
    public var dangerousPermissionsEnabled: Bool
    public var claude: ClaudeRouting?
    public var codex: AppConfig.Codex?

    public init(
        commandName: String,
        nickname: String,
        accountDetailHidden: Bool,
        dangerousPermissionsEnabled: Bool,
        claude: ClaudeRouting?,
        codex: AppConfig.Codex?
    ) {
        self.commandName = commandName
        self.nickname = nickname
        self.accountDetailHidden = accountDetailHidden
        self.dangerousPermissionsEnabled = dangerousPermissionsEnabled
        self.claude = claude
        self.codex = codex
    }
}

public struct LegacyOAuthDefaults: Equatable, Sendable {
    public var claude: LegacyOAuthProviderDefaults?
    public var codex: LegacyOAuthProviderDefaults?

    public init(
        claude: LegacyOAuthProviderDefaults?,
        codex: LegacyOAuthProviderDefaults?
    ) {
        self.claude = claude
        self.codex = codex
    }
}

public struct AppConfigLoadResult: Equatable, Sendable {
    public var config: AppConfig
    public var legacyOAuthDefaults: LegacyOAuthDefaults?
    public var requiresCanonicalRewrite: Bool

    public init(
        config: AppConfig,
        legacyOAuthDefaults: LegacyOAuthDefaults?,
        requiresCanonicalRewrite: Bool
    ) {
        self.config = config
        self.legacyOAuthDefaults = legacyOAuthDefaults
        self.requiresCanonicalRewrite = requiresCanonicalRewrite
    }

    public static func canonical(_ config: AppConfig) -> AppConfigLoadResult {
        AppConfigLoadResult(
            config: config,
            legacyOAuthDefaults: nil,
            requiresCanonicalRewrite: false
        )
    }
}

enum LegacyAppConfigDecoder {
    static func schemaVersion(in data: Data) throws -> Int {
        let object = try JSONSerialization.jsonObject(with: data)
        guard let dictionary = object as? [String: Any] else { return 1 }
        return dictionary["schemaVersion"] as? Int ?? 1
    }

    static func isLegacyDocument(_ data: Data) throws -> Bool {
        try schemaVersion(in: data) < AppConfig.currentSchemaVersion
    }

    static func decode(_ data: Data) throws -> AppConfigLoadResult {
        if try schemaVersion(in: data) == 2 {
            return try decodeVersion2(data)
        }

        let legacy = try JSONDecoder().decode(LegacyDocument.self, from: data)
        let claudeAPI = AppConfig.ClaudeAPI(
            commandName: legacy.commands.claudeAPI,
            claude: legacy.claudeAPI.claude,
            nickname: legacy.claudeAPI.nickname,
            dangerousPermissionsEnabled: legacy.claudeAPI.dangerousPermissionsEnabled
        )
        var codexAPI = legacy.codexAPI?.settings ?? AppConfig.CodexAPI(codex: legacy.codex)
        codexAPI.commandName = legacy.commands.codexAPI

        let config = AppConfig(
            port: legacy.port,
            apiKeyProfiles: apiKeyProfiles(claude: claudeAPI, codex: codexAPI),
            startAtLogin: legacy.startAtLogin,
            showDockIcon: legacy.showDockIcon,
            showMenuBarIcon: legacy.showMenuBarIcon,
            showNotifications: false,
            appearance: legacy.appearance,
            subscriptionUsage: legacy.subscriptionUsage,
            usageOverlay: legacy.usageOverlay,
            oauthCommandProfiles: legacy.oauthCommandProfiles,
            roundRobinProfiles: legacy.roundRobinProfiles,
            accountOrder: legacy.accountOrder,
            bindAddress: legacy.bindAddress,
            autostartServer: legacy.autostartServer,
            roundRobinEnabled: false,
            logLevel: legacy.logLevel
        )
        let oauthDefaults = LegacyOAuthDefaults(
            claude: LegacyOAuthProviderDefaults(
                commandName: legacy.commands.claudeOAuth,
                nickname: legacy.nicknames.claude,
                accountDetailHidden: legacy.accountPrivacy.claudeHidden,
                dangerousPermissionsEnabled: legacy.dangerousPermissionsEnabled,
                claude: legacy.claudeAPI.claude,
                codex: nil
            ),
            codex: LegacyOAuthProviderDefaults(
                commandName: legacy.commands.codexOAuth,
                nickname: legacy.nicknames.codex,
                accountDetailHidden: legacy.accountPrivacy.codexHidden,
                dangerousPermissionsEnabled: legacy.dangerousPermissionsEnabled,
                claude: nil,
                codex: legacy.codex
            )
        )
        return AppConfigLoadResult(
            config: config,
            legacyOAuthDefaults: oauthDefaults,
            requiresCanonicalRewrite: true
        )
    }

    private static func decodeVersion2(_ data: Data) throws -> AppConfigLoadResult {
        let document = try JSONDecoder().decode(Version2Document.self, from: data)
        let config = AppConfig(
            port: document.port,
            apiKeyProfiles: apiKeyProfiles(claude: document.claudeAPI, codex: document.codexAPI),
            startAtLogin: document.startAtLogin,
            showDockIcon: document.showDockIcon,
            showMenuBarIcon: document.showMenuBarIcon,
            showNotifications: false,
            appearance: document.appearance,
            subscriptionUsage: document.subscriptionUsage,
            usageOverlay: document.usageOverlay,
            oauthCommandProfiles: document.oauthCommandProfiles,
            roundRobinProfiles: document.roundRobinProfiles,
            accountOrder: document.accountOrder,
            bindAddress: document.bindAddress,
            autostartServer: document.autostartServer,
            roundRobinEnabled: false,
            logLevel: document.logLevel
        )
        return AppConfigLoadResult(
            config: config,
            legacyOAuthDefaults: nil,
            requiresCanonicalRewrite: true
        )
    }

    private static func apiKeyProfiles(
        claude: AppConfig.ClaudeAPI,
        codex: AppConfig.CodexAPI
    ) -> [AppConfig.APIKeyProfile] {
        [
            AppConfig.APIKeyProfile(
                id: "claude-api",
                provider: .claude,
                secretReference: .claudeAPIKey,
                commandName: claude.commandName,
                nickname: claude.nickname,
                dangerousPermissionsEnabled: claude.dangerousPermissionsEnabled,
                claude: claude.claude
            ),
            AppConfig.APIKeyProfile(
                id: "codex-api",
                provider: .codex,
                secretReference: .codexAPIKey,
                commandName: codex.commandName,
                nickname: codex.nickname,
                dangerousPermissionsEnabled: codex.dangerousPermissionsEnabled,
                codex: codex.codex
            )
        ]
    }

    private struct Version2Document: Decodable {
        var port: Int
        var claudeAPI: AppConfig.ClaudeAPI
        var codexAPI: AppConfig.CodexAPI
        var startAtLogin: Bool
        var showDockIcon: Bool
        var showMenuBarIcon: Bool
        var appearance: AppearanceMode
        var subscriptionUsage: AppConfig.SubscriptionUsage
        var usageOverlay: AppConfig.UsageOverlay
        var oauthCommandProfiles: [AppConfig.OAuthCommandProfile]
        var roundRobinProfiles: [AppConfig.RoundRobinProfile]
        var accountOrder: [String]
        var bindAddress: String
        var autostartServer: Bool
        var logLevel: LogLevel

        private enum CodingKeys: String, CodingKey {
            case port, claudeAPI, codexAPI, startAtLogin, showDockIcon, showMenuBarIcon
            case appearance, subscriptionUsage, usageOverlay, oauthCommandProfiles
            case roundRobinProfiles, accountOrder, bindAddress, autostartServer, logLevel
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            port = try c.decodeIfPresent(Int.self, forKey: .port) ?? AppConfig.default.port
            claudeAPI = try c.decodeIfPresent(AppConfig.ClaudeAPI.self, forKey: .claudeAPI) ?? AppConfig.ClaudeAPI()
            codexAPI = try c.decodeIfPresent(AppConfig.CodexAPI.self, forKey: .codexAPI) ?? AppConfig.CodexAPI()
            startAtLogin = try c.decodeIfPresent(Bool.self, forKey: .startAtLogin) ?? false
            showDockIcon = try c.decodeIfPresent(Bool.self, forKey: .showDockIcon) ?? true
            showMenuBarIcon = try c.decodeIfPresent(Bool.self, forKey: .showMenuBarIcon) ?? true
            appearance = try c.decodeIfPresent(AppearanceMode.self, forKey: .appearance) ?? .system
            subscriptionUsage = try c.decodeIfPresent(AppConfig.SubscriptionUsage.self, forKey: .subscriptionUsage) ?? .init()
            usageOverlay = try c.decodeIfPresent(AppConfig.UsageOverlay.self, forKey: .usageOverlay) ?? .init()
            oauthCommandProfiles = try c.decodeIfPresent([AppConfig.OAuthCommandProfile].self, forKey: .oauthCommandProfiles) ?? []
            roundRobinProfiles = try c.decodeIfPresent([AppConfig.RoundRobinProfile].self, forKey: .roundRobinProfiles) ?? []
            accountOrder = try c.decodeIfPresent([String].self, forKey: .accountOrder) ?? []
            bindAddress = try c.decodeIfPresent(String.self, forKey: .bindAddress) ?? ProxyNetworkPolicy.loopbackHost
            autostartServer = try c.decodeIfPresent(Bool.self, forKey: .autostartServer) ?? false
            logLevel = try c.decodeIfPresent(LogLevel.self, forKey: .logLevel) ?? .info
        }
    }

    private struct LegacyDocument: Decodable {
        var port: Int
        var commands: LegacyCommands
        var claudeAPI: AppConfig.ClaudeAPI
        var codex: AppConfig.Codex
        var codexAPI: LegacyCodexAPI?
        var dangerousPermissionsEnabled: Bool
        var startAtLogin: Bool
        var showDockIcon: Bool
        var showMenuBarIcon: Bool
        var appearance: AppearanceMode
        var nicknames: LegacyNicknames
        var accountPrivacy: LegacyAccountPrivacy
        var subscriptionUsage: AppConfig.SubscriptionUsage
        var usageOverlay: AppConfig.UsageOverlay
        var oauthCommandProfiles: [AppConfig.OAuthCommandProfile]
        var roundRobinProfiles: [AppConfig.RoundRobinProfile]
        var accountOrder: [String]
        var bindAddress: String
        var autostartServer: Bool
        var logLevel: LogLevel

        private enum CodingKeys: String, CodingKey {
            case port
            case commands
            case claudeAPI = "ccapi"
            case codex = "ccodex"
            case codexAPI
            case dangerousPermissionsEnabled = "includeDangerouslySkipPermissions"
            case startAtLogin
            case showDockIcon
            case showMenuBarIcon
            case appearance
            case nicknames
            case accountPrivacy
            case subscriptionUsage
            case usageOverlay
            case oauthCommandProfiles
            case roundRobinProfiles
            case accountOrder
            case bindAddress
            case autostartServer
            case logLevel
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            port = try container.decodeIfPresent(Int.self, forKey: .port) ?? AppConfig.default.port
            commands = try container.decodeIfPresent(LegacyCommands.self, forKey: .commands) ?? LegacyCommands()
            claudeAPI = try container.decodeIfPresent(AppConfig.ClaudeAPI.self, forKey: .claudeAPI) ?? AppConfig.ClaudeAPI()
            codex = try container.decodeIfPresent(AppConfig.Codex.self, forKey: .codex) ?? .default
            codexAPI = try container.decodeIfPresent(LegacyCodexAPI.self, forKey: .codexAPI)
            dangerousPermissionsEnabled = try container.decodeIfPresent(Bool.self, forKey: .dangerousPermissionsEnabled) ?? false
            startAtLogin = try container.decodeIfPresent(Bool.self, forKey: .startAtLogin) ?? false
            showDockIcon = try container.decodeIfPresent(Bool.self, forKey: .showDockIcon) ?? true
            showMenuBarIcon = try container.decodeIfPresent(Bool.self, forKey: .showMenuBarIcon) ?? true
            appearance = try container.decodeIfPresent(AppearanceMode.self, forKey: .appearance) ?? .system
            nicknames = try container.decodeIfPresent(LegacyNicknames.self, forKey: .nicknames) ?? LegacyNicknames()
            accountPrivacy = try container.decodeIfPresent(LegacyAccountPrivacy.self, forKey: .accountPrivacy) ?? LegacyAccountPrivacy()
            subscriptionUsage = try container.decodeIfPresent(AppConfig.SubscriptionUsage.self, forKey: .subscriptionUsage) ?? AppConfig.SubscriptionUsage()
            usageOverlay = try container.decodeIfPresent(AppConfig.UsageOverlay.self, forKey: .usageOverlay) ?? AppConfig.UsageOverlay()
            oauthCommandProfiles = try container.decodeIfPresent([AppConfig.OAuthCommandProfile].self, forKey: .oauthCommandProfiles) ?? []
            roundRobinProfiles = try container.decodeIfPresent([AppConfig.RoundRobinProfile].self, forKey: .roundRobinProfiles) ?? []
            accountOrder = try container.decodeIfPresent([String].self, forKey: .accountOrder) ?? []
            bindAddress = try container.decodeIfPresent(String.self, forKey: .bindAddress) ?? ProxyNetworkPolicy.loopbackHost
            autostartServer = try container.decodeIfPresent(Bool.self, forKey: .autostartServer) ?? false
            logLevel = try container.decodeIfPresent(LogLevel.self, forKey: .logLevel) ?? .info
        }
    }

    private struct LegacyCommands: Decodable {
        var claudeOAuth = ""
        var claudeAPI = ""
        var codexOAuth = ""
        var codexAPI = ""

        private enum CodingKeys: String, CodingKey {
            case claudeOAuth = "cc"
            case claudeAPI = "ccapi"
            case codexOAuth = "ccodex"
            case codexAPI = "ccodexapi"
        }

        init() {}

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            claudeOAuth = try container.decodeIfPresent(String.self, forKey: .claudeOAuth) ?? ""
            claudeAPI = try container.decodeIfPresent(String.self, forKey: .claudeAPI) ?? ""
            codexOAuth = try container.decodeIfPresent(String.self, forKey: .codexOAuth) ?? ""
            codexAPI = try container.decodeIfPresent(String.self, forKey: .codexAPI) ?? ""
        }
    }

    private struct LegacyNicknames: Decodable {
        var claude = ""
        var codex = ""

        private enum CodingKeys: String, CodingKey {
            case claude = "cc"
            case codex = "ccodex"
        }

        init() {}

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            claude = try container.decodeIfPresent(String.self, forKey: .claude) ?? ""
            codex = try container.decodeIfPresent(String.self, forKey: .codex) ?? ""
        }
    }

    private struct LegacyAccountPrivacy: Decodable {
        var claudeHidden = true
        var codexHidden = true

        private enum CodingKeys: String, CodingKey {
            case claudeHidden
            case codexHidden
        }

        init() {}

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            claudeHidden = try container.decodeIfPresent(Bool.self, forKey: .claudeHidden) ?? true
            codexHidden = try container.decodeIfPresent(Bool.self, forKey: .codexHidden) ?? true
        }
    }

    private struct LegacyCodexAPI: Decodable {
        var settings: AppConfig.CodexAPI

        private enum CodingKeys: String, CodingKey {
            case codex
        }

        init(from decoder: Decoder) throws {
            let probe = try decoder.container(keyedBy: CodingKeys.self)
            if probe.contains(.codex) {
                settings = try AppConfig.CodexAPI(from: decoder)
            } else {
                settings = AppConfig.CodexAPI(codex: try AppConfig.Codex(from: decoder))
            }
        }
    }
}
