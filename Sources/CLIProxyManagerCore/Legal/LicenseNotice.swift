import Foundation

public struct LicenseNotice: Equatable, Sendable {
    public let name: String
    public let licenseName: String
    public let requiredNotice: String
    public let providerTermsNotice: String
    public let fullLicenseText: String

    public init(
        name: String,
        licenseName: String,
        requiredNotice: String,
        providerTermsNotice: String,
        fullLicenseText: String
    ) {
        self.name = name
        self.licenseName = licenseName
        self.requiredNotice = requiredNotice
        self.providerTermsNotice = providerTermsNotice
        self.fullLicenseText = fullLicenseText
    }

    public static let cliProxyAPI = LicenseNotice(
        name: "CLIProxyAPI",
        licenseName: "MIT License",
        requiredNotice: "CLIProxyAPI는 MIT License로 배포됩니다. 이 앱이 CLIProxyAPI를 번들하거나 함께 배포하는 경우, upstream copyright notice와 MIT permission notice 전문을 앱 및 배포물에 포함해야 합니다.",
        providerTermsNotice: "이 앱은 Claude, OpenAI, Codex 등 각 provider의 공식 보증 제품이 아닙니다. 사용자는 자신의 계정과 인증 정보로 각 provider 약관을 확인하고 준수해야 합니다.",
        fullLicenseText: cliProxyAPILicenseText
    )

    public static let cliProxyAPILicenseText = """
    MIT License

    Copyright (c) 2025 Luis Pater
    Copyright (c) 2025.9-present Router-For.ME

    Permission is hereby granted, free of charge, to any person obtaining a copy
    of this software and associated documentation files (the \"Software\"), to deal
    in the Software without restriction, including without limitation the rights
    to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
    copies of the Software, and to permit persons to whom the Software is
    furnished to do so, subject to the following conditions:

    The above copyright notice and this permission notice shall be included in all
    copies or substantial portions of the Software.

    THE SOFTWARE IS PROVIDED \"AS IS\", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
    IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
    FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
    AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
    LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
    OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
    SOFTWARE.
    """
}
