import Foundation

public struct AuthProfileStore: Sendable {
    private let authDirectory: URL
    private let fileManager: FileManager

    public init(authDirectory: URL, fileManager: FileManager = .default) {
        self.authDirectory = authDirectory
        self.fileManager = fileManager
    }

    public init(paths: ManagedPaths = ManagedPaths(), fileManager: FileManager = .default) {
        self.init(authDirectory: paths.authDirectory, fileManager: fileManager)
    }

    public func profiles() throws -> [AuthProfile] {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: authDirectory.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return []
        }

        let fileURLs = try fileManager.contentsOfDirectory(
            at: authDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )

        return fileURLs
            .filter { $0.pathExtension == "json" }
            .compactMap(loadProfile)
            .sorted { $0.fileName.localizedStandardCompare($1.fileName) == .orderedAscending }
    }

    public func profile(type: AuthProfileType) throws -> AuthProfile? {
        try profiles().first { $0.type == type && $0.disabled == false }
    }

    @discardableResult
    public func setDisabled(_ disabled: Bool, for type: AuthProfileType) throws -> Int {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: authDirectory.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return 0
        }

        let fileURLs = try fileManager.contentsOfDirectory(
            at: authDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )

        var updatedCount = 0
        for fileURL in fileURLs where fileURL.pathExtension == "json" {
            guard let data = try? Data(contentsOf: fileURL),
                  var json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  json["type"] as? String == type.rawValue else {
                continue
            }

            json["disabled"] = disabled
            let updatedData = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
            try updatedData.write(to: fileURL, options: .atomic)
            updatedCount += 1
        }

        return updatedCount
    }

    private func loadProfile(from fileURL: URL) -> AuthProfile? {
        guard let data = try? Data(contentsOf: fileURL),
              let authFile = try? JSONDecoder().decode(AuthFile.self, from: data),
              let type = authFile.type.flatMap(AuthProfileType.init(rawValue:)) else {
            return nil
        }

        return AuthProfile(
            fileName: fileURL.lastPathComponent,
            type: type,
            email: trimmed(authFile.email),
            accountID: trimmed(authFile.accountID),
            expired: trimmed(authFile.expired),
            disabled: authFile.disabled ?? false
        )
    }

    private func trimmed(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedValue.isEmpty ? nil : trimmedValue
    }
}

private struct AuthFile: Decodable {
    let type: String?
    let email: String?
    let accountID: String?
    let expired: String?
    let disabled: Bool?

    enum CodingKeys: String, CodingKey {
        case type
        case email
        case accountID = "account_id"
        case expired
        case disabled
    }
}
