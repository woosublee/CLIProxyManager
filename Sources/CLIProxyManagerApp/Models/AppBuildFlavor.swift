import Foundation

enum AppBuildFlavor: Equatable, Sendable {
    static let releaseChannelKey = "CLIProxyManagerReleaseChannel"

    case official
    case development

    init(infoDictionary: [String: Any]?) {
        let releaseChannel = infoDictionary?[Self.releaseChannelKey] as? String
        self = releaseChannel == "development" ? .development : .official
    }

    static var current: AppBuildFlavor {
        AppBuildFlavor(infoDictionary: Bundle.main.infoDictionary)
    }
}
