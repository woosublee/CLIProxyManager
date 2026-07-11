import Foundation
import Security

public struct SubscriptionUsageManagementKeyStore: SubscriptionUsageManagementKeyProviding {
    private let service: String
    private let account = "subscription-usage-management-key"

    public init(service: String = "io.woosublee.CLIProxyManager") {
        self.service = service
    }

    public func isConfigured() -> Bool {
        (try? managementKey()).map { !$0.isEmpty } ?? false
    }

    public func createManagementKeyIfNeeded() throws -> Bool {
        guard !isConfigured() else { return false }
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw SecretStoreError.writeFailed(account)
        }
        let key = Data(bytes)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        try setManagementKey(key)
        return true
    }

    public func setManagementKey(_ value: String) throws {
        let normalizedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedValue.isEmpty else {
            throw SecretStoreError.writeFailed(account)
        }

        let query = baseQuery()
        let attributes: [String: Any] = [kSecValueData as String: Data(normalizedValue.utf8)]
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess {
            return
        }

        guard updateStatus == errSecItemNotFound else {
            throw SecretStoreError.writeFailed(account)
        }

        var addQuery = query
        addQuery[kSecValueData as String] = Data(normalizedValue.utf8)
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        guard SecItemAdd(addQuery as CFDictionary, nil) == errSecSuccess else {
            throw SecretStoreError.writeFailed(account)
        }
    }

    public func deleteManagementKey() throws {
        let status = SecItemDelete(baseQuery() as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw SecretStoreError.writeFailed(account)
        }
    }

    func managementKey() throws -> String {
        var query = baseQuery()
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecReturnData as String] = true

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status != errSecItemNotFound else {
            throw SecretStoreError.missingSecret(account)
        }
        guard status == errSecSuccess,
              let data = result as? Data,
              let value = String(data: data, encoding: .utf8),
              !value.isEmpty else {
            throw SecretStoreError.readFailed(account)
        }
        return value
    }

    private func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }
}
