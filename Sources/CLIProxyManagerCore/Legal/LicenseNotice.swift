import Foundation

public struct LicenseNotice: Equatable, Sendable {
    public let name: String
    public let licenseName: String
    public let requiredNotice: String
    public let providerTermsNotice: String

    public init(
        name: String,
        licenseName: String,
        requiredNotice: String,
        providerTermsNotice: String
    ) {
        self.name = name
        self.licenseName = licenseName
        self.requiredNotice = requiredNotice
        self.providerTermsNotice = providerTermsNotice
    }

    public static let cliProxyAPI = LicenseNotice(
        name: "CLIProxyAPI",
        licenseName: "MIT License",
        requiredNotice: "CLIProxyAPI는 MIT License로 배포됩니다. 이 앱이 CLIProxyAPI를 번들하거나 함께 배포하는 경우, upstream copyright notice와 MIT permission notice 전문을 앱 및 배포물에 포함해야 합니다.",
        providerTermsNotice: "이 앱은 Claude, OpenAI, Codex 등 각 provider의 공식 보증 제품이 아닙니다. 사용자는 자신의 계정과 인증 정보로 각 provider 약관을 확인하고 준수해야 합니다."
    )
}
