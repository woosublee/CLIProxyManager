import Foundation

public struct AuthProfileStore: @unchecked Sendable {
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

    public func profile(id: String) throws -> AuthProfile? {
        try profiles().first { $0.id == id }
    }

    /// Deletes a single auth file matching the given profile id. Returns true when a file was removed.
    @discardableResult
    public func delete(id: String) throws -> Bool {
        guard let fileURL = try authFileURL(id: id) else { return false }
        try fileManager.removeItem(at: fileURL)
        return true
    }

    /// Deletes every auth file matching the given provider type. Returns the number of files removed.
    @discardableResult
    public func delete(for type: AuthProfileType) throws -> Int {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: authDirectory.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return 0
        }

        let fileURLs = try fileManager.contentsOfDirectory(
            at: authDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )

        var deletedCount = 0
        for fileURL in fileURLs where fileURL.pathExtension == "json" {
            guard let data = try? Data(contentsOf: fileURL),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  json["type"] as? String == type.rawValue else {
                continue
            }
            try fileManager.removeItem(at: fileURL)
            deletedCount += 1
        }
        return deletedCount
    }

    @discardableResult
    public func setDisabled(_ disabled: Bool, id: String) throws -> Bool {
        guard let fileURL = try authFileURL(id: id) else { return false }
        try updateField(key: "disabled", value: disabled, fileURL: fileURL)
        return true
    }

    @discardableResult
    public func setPrefix(_ prefix: String?, id: String) throws -> Bool {
        guard let fileURL = try authFileURL(id: id) else { return false }
        let sanitizedPrefix = sanitizedPrefix(prefix)
        try updateField(key: "prefix", value: sanitizedPrefix, fileURL: fileURL)
        return true
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
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  json["type"] as? String == type.rawValue else {
                continue
            }

            try updateField(key: "disabled", value: disabled, fileURL: fileURL, json: json)
            updatedCount += 1
        }

        return updatedCount
    }

    private func authFileURL(id: String) throws -> URL? {
        let trimmedID = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedID.isEmpty else { return nil }

        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: authDirectory.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return nil
        }

        let fileURLs = try fileManager.contentsOfDirectory(
            at: authDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )

        return fileURLs.first { fileURL in
            fileURL.pathExtension == "json" && fileURL.lastPathComponent == trimmedID
        }
    }

    private func updateField(key: String, value: Any?, fileURL: URL) throws {
        let data = try Data(contentsOf: fileURL)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        try updateField(key: key, value: value, fileURL: fileURL, json: json)
    }

    private func updateField(key: String, value: Any?, fileURL: URL, json: [String: Any]) throws {
        var updatedJSON = json
        if let value {
            updatedJSON[key] = value
        } else {
            updatedJSON.removeValue(forKey: key)
        }
        let updatedData = try JSONSerialization.data(withJSONObject: updatedJSON, options: [.prettyPrinted, .sortedKeys])
        try updatedData.write(to: fileURL, options: .atomic)
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
            disabled: authFile.disabled ?? false,
            prefix: sanitizedPrefix(authFile.prefix)
        )
    }

    private func trimmed(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedValue.isEmpty ? nil : trimmedValue
    }

    private func sanitizedPrefix(_ value: String?) -> String? {
        guard var prefix = trimmed(value) else { return nil }
        prefix = prefix.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !prefix.isEmpty, !prefix.contains("/") else { return nil }
        return prefix
    }
}

private struct AuthFile: Decodable {
    let type: String?
    let email: String?
    let accountID: String?
    let expired: String?
    let disabled: Bool?
    let prefix: String?

    enum CodingKeys: String, CodingKey {
        case type
        case email
        case accountID = "account_id"
        case expired
        case disabled
        case prefix
    }
}
