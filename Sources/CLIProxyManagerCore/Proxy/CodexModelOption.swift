import Foundation

public struct CodexModelOption: Equatable, Sendable {
    public var id: String
    public var supportedReasoning: [AppConfig.CodexReasoning]
    public var defaultReasoning: AppConfig.CodexReasoning?

    public init(
        id: String,
        supportedReasoning: [AppConfig.CodexReasoning] = [],
        defaultReasoning: AppConfig.CodexReasoning? = nil
    ) {
        self.id = id
        self.supportedReasoning = supportedReasoning
        self.defaultReasoning = defaultReasoning
    }
}
