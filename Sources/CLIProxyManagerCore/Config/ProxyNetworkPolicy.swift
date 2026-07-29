public enum ProxyNetworkPolicy {
    public static let loopbackHost = "127.0.0.1"

    public static func normalizedBindAddress(_: String?) -> String {
        loopbackHost
    }

    public static func requiresCanonicalRewrite(_ value: String?) -> Bool {
        value != loopbackHost
    }
}
