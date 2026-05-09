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
        requiredNotice: "CLIProxyAPI is distributed under the MIT License. When this app bundles or distributes CLIProxyAPI, the upstream copyright notice and the full MIT permission notice must be included in the app and any release materials.",
        providerTermsNotice: "CLIProxyManager is not an official product of Anthropic, OpenAI, Codex, or any other model provider. Users are responsible for using their own accounts and credentials in compliance with each provider's terms of service.",
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
