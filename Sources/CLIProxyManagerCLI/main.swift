import CLIProxyManagerCore
import Foundation

do {
    try run(arguments: Array(CommandLine.arguments.dropFirst()))
} catch let error as CLIError {
    fputs("\(error.description)\n", stderr)
    exit(EXIT_FAILURE)
} catch let error as SecretStoreError {
    fputs("\(error.description)\n", stderr)
    exit(EXIT_FAILURE)
} catch {
    fputs("\(error)\n", stderr)
    exit(EXIT_FAILURE)
}

private func run(arguments: [String], store: some SecretStore = KeychainSecretStore()) throws {
    guard arguments.count == 3, arguments[0] == "secret" else {
        throw CLIError.usage
    }

    guard let key = SecretKey(rawValue: arguments[2]) else {
        throw CLIError.usage
    }

    switch arguments[1] {
    case "get":
        print(try store.get(key))
    case "set":
        let input = FileHandle.standardInput.readDataToEndOfFile()
        let value = String(data: input, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !value.isEmpty else {
            throw CLIError.emptySecret(key.rawValue)
        }
        try store.set(value, for: key)
    case "delete":
        try store.delete(key)
    default:
        throw CLIError.usage
    }
}

private enum CLIError: Error, CustomStringConvertible {
    case usage
    case emptySecret(String)

    var description: String {
        switch self {
        case .usage:
            "Usage: cliproxy-manager secret <get|set|delete> claude-api-key"
        case .emptySecret(let key):
            "Secret value cannot be empty: \(key)"
        }
    }
}
