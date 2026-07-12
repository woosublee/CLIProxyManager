import Foundation

public struct CodexModelOption: Equatable, Sendable {
    public static let fastModeFallbackModels: Set<String> = [
        "gpt-5.4",
        "gpt-5.5",
        "gpt-5.6-sol",
        "gpt-5.6-terra",
        "gpt-5.6-luna"
    ]

    public var id: String
    public var supportedReasoning: [AppConfig.CodexReasoning]
    public var defaultReasoning: AppConfig.CodexReasoning?
    public var supportsFastMode: Bool

    public init(
        id: String,
        supportedReasoning: [AppConfig.CodexReasoning] = [],
        defaultReasoning: AppConfig.CodexReasoning? = nil,
        supportsFastMode: Bool? = nil
    ) {
        let canonicalID = CodexFastMode.canonicalModel(from: id)
        self.id = canonicalID
        self.supportedReasoning = supportedReasoning
        self.defaultReasoning = defaultReasoning
        self.supportsFastMode = supportsFastMode
            ?? Self.fastModeFallbackModels.contains(canonicalID.lowercased())
    }
}
