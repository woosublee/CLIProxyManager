import CLIProxyManagerCore
import Foundation

enum RoundRobinAvailability: Equatable {
    case available(count: Int)
    case insufficientProviderAccounts(count: Int)
    case insufficientSelectedAccounts(count: Int)
    case missingPrefixes([String])

    var canEnable: Bool {
        if case .available = self { return true }
        return false
    }

    var message: String {
        switch self {
        case .available(let count):
            return "Available — \(count) accounts selected."
        case .insufficientProviderAccounts(let count):
            return "Unavailable — connect at least 2 accounts. Current enabled accounts: \(count)."
        case .insufficientSelectedAccounts(let count):
            return "Select at least 2 accounts to enable round-robin. Current selected accounts: \(count)."
        case .missingPrefixes(let ids):
            return "Some accounts cannot be used because they do not have a routing prefix: \(ids.joined(separator: ", "))."
        }
    }
}

struct RoundRobinAccountOption: Identifiable, Equatable {
    let id: String
    let title: String
    let detail: String
    let isEnabled: Bool
    let hasPrefix: Bool
}

struct RoundRobinSettingsState: Equatable {
    var profile: AppConfig.RoundRobinProfile
    var accountOptions: [RoundRobinAccountOption]
    var availability: RoundRobinAvailability
}

enum RoundRobinSettingsError: LocalizedError, Equatable {
    case insufficientAccounts

    var errorDescription: String? {
        switch self {
        case .insufficientAccounts:
            return "Select at least 2 enabled accounts to enable round-robin."
        }
    }
}
