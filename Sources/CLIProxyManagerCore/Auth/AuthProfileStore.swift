import CryptoKit
import Foundation

public struct AuthProfileMigration: Equatable, Sendable {
    public let oldID: String
    public let newID: String
    fileprivate let createdCanonicalFile: Bool

    public init(oldID: String, newID: String) {
        self.oldID = oldID
        self.newID = newID
        self.createdCanonicalFile = false
    }

    fileprivate init(oldID: String, newID: String, createdCanonicalFile: Bool) {
        self.oldID = oldID
        self.newID = newID
        self.createdCanonicalFile = createdCanonicalFile
    }
}

public struct AuthProfileStore: @unchecked Sendable {
    private let authDirectory: URL
    private let migrationBackupsDirectory: URL
    private let fileManager: FileManager

    public init(
        authDirectory: URL,
        migrationBackupsDirectory: URL? = nil,
        fileManager: FileManager = .default
    ) {
        self.authDirectory = authDirectory
        self.migrationBackupsDirectory = migrationBackupsDirectory
            ?? authDirectory.deletingLastPathComponent()
                .appendingPathComponent("backups/credential-migrations", isDirectory: true)
        self.fileManager = fileManager
    }

    public init(paths: ManagedPaths = ManagedPaths(), fileManager: FileManager = .default) {
        self.init(
            authDirectory: paths.authDirectory,
            migrationBackupsDirectory: paths.credentialMigrationBackupsDirectory,
            fileManager: fileManager
        )
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

    public func prepareCodexCredentialMigrations() throws -> [AuthProfileMigration] {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: authDirectory.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return []
        }

        let fileURLs = try fileManager.contentsOfDirectory(
            at: authDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )

        var migrations: [AuthProfileMigration] = []
        for sourceURL in fileURLs where sourceURL.pathExtension == "json" {
            guard let migration = try prepareCodexCredentialMigration(at: sourceURL) else { continue }
            migrations.append(migration)
        }
        return migrations
    }

    public func finalizeCodexCredentialMigrations(_ migrations: [AuthProfileMigration]) throws {
        guard !migrations.isEmpty else { return }
        try fileManager.createDirectory(at: migrationBackupsDirectory, withIntermediateDirectories: true)

        var moved: [(source: URL, destination: URL)] = []
        do {
            for migration in migrations {
                let sourceURL = authDirectory.appendingPathComponent(migration.oldID)
                guard fileManager.fileExists(atPath: sourceURL.path) else { continue }
                let destinationURL = uniqueMigrationBackupURL(for: migration.oldID)
                try fileManager.moveItem(at: sourceURL, to: destinationURL)
                moved.append((sourceURL, destinationURL))
            }
        } catch {
            for item in moved.reversed() where fileManager.fileExists(atPath: item.destination.path) {
                try? fileManager.moveItem(at: item.destination, to: item.source)
            }
            throw error
        }
    }

    public func rollbackCodexCredentialMigrations(_ migrations: [AuthProfileMigration]) {
        for migration in migrations where migration.createdCanonicalFile {
            let sourceURL = authDirectory.appendingPathComponent(migration.oldID)
            let targetURL = authDirectory.appendingPathComponent(migration.newID)
            guard fileManager.fileExists(atPath: sourceURL.path),
                  fileManager.fileExists(atPath: targetURL.path),
                  sameCodexAccount(sourceURL, targetURL) else {
                continue
            }
            try? fileManager.removeItem(at: targetURL)
        }
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

    private func prepareCodexCredentialMigration(at sourceURL: URL) throws -> AuthProfileMigration? {
        let data = try Data(contentsOf: sourceURL)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              json["type"] as? String == AuthProfileType.codex.rawValue,
              let email = trimmed(json["email"] as? String),
              let accountID = trimmed(json["account_id"] as? String),
              let planType = codexPlanType(idToken: json["id_token"] as? String),
              let targetName = canonicalCodexFileName(
                  legacyFileName: sourceURL.lastPathComponent,
                  email: email,
                  accountID: accountID,
                  planType: planType
              ) else {
            return nil
        }

        let targetURL = authDirectory.appendingPathComponent(targetName)
        if fileManager.fileExists(atPath: targetURL.path) {
            guard sameCodexAccount(sourceURL, targetURL) else { return nil }
            return AuthProfileMigration(
                oldID: sourceURL.lastPathComponent,
                newID: targetName,
                createdCanonicalFile: false
            )
        }

        let temporaryURL = authDirectory.appendingPathComponent(".\(targetName).migration")
        try? fileManager.removeItem(at: temporaryURL)
        do {
            try fileManager.copyItem(at: sourceURL, to: temporaryURL)
            let attributes = try fileManager.attributesOfItem(atPath: sourceURL.path)
            if let permissions = attributes[.posixPermissions] {
                try fileManager.setAttributes([.posixPermissions: permissions], ofItemAtPath: temporaryURL.path)
            }
            try fileManager.moveItem(at: temporaryURL, to: targetURL)
        } catch {
            try? fileManager.removeItem(at: temporaryURL)
            throw error
        }

        return AuthProfileMigration(
            oldID: sourceURL.lastPathComponent,
            newID: targetName,
            createdCanonicalFile: true
        )
    }

    private func canonicalCodexFileName(
        legacyFileName: String,
        email: String,
        accountID: String,
        planType: String
    ) -> String? {
        let normalizedPlan = normalizedCodexPlanType(planType)
        let legacyName = normalizedPlan.isEmpty
            ? "codex-\(email).json"
            : "codex-\(email)-\(normalizedPlan).json"
        guard legacyFileName == legacyName else { return nil }

        let planSuffix = normalizedPlan.isEmpty ? "" : "-\(normalizedPlan)"
        let accountHash = SHA256.hash(data: Data(accountID.utf8))
            .prefix(4)
            .map { String(format: "%02x", $0) }
            .joined()
        return "codex-\(accountHash)-\(email)\(planSuffix).json"
    }

    private func codexPlanType(idToken: String?) -> String? {
        guard let idToken = trimmed(idToken) else { return nil }
        let segments = idToken.split(separator: ".", omittingEmptySubsequences: false)
        guard segments.count >= 2 else { return nil }
        var encoded = String(segments[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        encoded += String(repeating: "=", count: (4 - encoded.count % 4) % 4)
        guard let data = Data(base64Encoded: encoded),
              let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let auth = payload["https://api.openai.com/auth"] as? [String: Any],
              let planType = auth["chatgpt_plan_type"] as? String else {
            return nil
        }
        return planType
    }

    private func normalizedCodexPlanType(_ value: String) -> String {
        value.components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .map { $0.lowercased() }
            .joined(separator: "-")
    }

    private func sameCodexAccount(_ lhsURL: URL, _ rhsURL: URL) -> Bool {
        guard let lhs = codexIdentity(at: lhsURL), let rhs = codexIdentity(at: rhsURL) else { return false }
        return lhs.accountID == rhs.accountID
            && lhs.email.caseInsensitiveCompare(rhs.email) == .orderedSame
    }

    private func codexIdentity(at url: URL) -> (accountID: String, email: String)? {
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              json["type"] as? String == AuthProfileType.codex.rawValue,
              let accountID = trimmed(json["account_id"] as? String),
              let email = trimmed(json["email"] as? String) else {
            return nil
        }
        return (accountID, email)
    }

    private func uniqueMigrationBackupURL(for fileName: String) -> URL {
        let baseName = "\(fileName).migrated"
        var candidate = migrationBackupsDirectory.appendingPathComponent(baseName)
        var suffix = 2
        while fileManager.fileExists(atPath: candidate.path) {
            candidate = migrationBackupsDirectory.appendingPathComponent("\(baseName).\(suffix)")
            suffix += 1
        }
        return candidate
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
