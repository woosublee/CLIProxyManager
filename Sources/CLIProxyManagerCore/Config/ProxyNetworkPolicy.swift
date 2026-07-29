public enum ProxyNetworkPolicy {
    public static let loopbackHost = "127.0.0.1"

    /// Intentionally ignores legacy input and always returns loopback as a fail-closed policy.
    public static func normalizedBindAddress(_: String?) -> String {
        loopbackHost
    }

    public static func requiresCanonicalRewrite(_ value: String?) -> Bool {
        value != loopbackHost
    }
}
