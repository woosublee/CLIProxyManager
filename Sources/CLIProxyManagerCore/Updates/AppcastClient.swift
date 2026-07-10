import Foundation

public struct AppcastClient: AppcastFetching, Sendable {
    static let feedURL = URL(string: "https://github.com/woosublee/CLIProxyManager/releases/latest/download/appcast.xml")!

    private let httpClient: any HTTPClient

    public init(httpClient: any HTTPClient = URLSessionHTTPClient()) {
        self.httpClient = httpClient
    }

    public func fetchLatest(afterBuild: Int) async throws -> AppUpdateRelease? {
        guard Self.feedURL.scheme == "https" else {
            throw CLIProxyManagerCommandError.operation("App update feed must use HTTPS.")
        }
        let data = try await httpClient.get(Self.feedURL, headers: [:])
        let parser = AppcastXMLParser(afterBuild: afterBuild)
        let parser_ = XMLParser(data: data)
        parser_.delegate = parser
        parser_.parse()
        if let error = parser.parseError {
            throw error
        }
        return parser.bestRelease
    }
}

// MARK: - XML parsing

private final class AppcastXMLParser: NSObject, XMLParserDelegate {
    private let afterBuild: Int
    private var currentItem: PartialItem?
    private var currentElement: String?
    private var inItem = false
    private(set) var bestRelease: AppUpdateRelease?
    private(set) var parseError: Error?

    init(afterBuild: Int) { self.afterBuild = afterBuild }

    private struct PartialItem {
        var shortVersion: String?
        var build: Int?
        var enclosureURL: URL?
        var expectedLength: Int?
        var edSignature: String?
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes: [String: String]) {
        currentElement = elementName
        if elementName == "item" {
            inItem = true
            currentItem = PartialItem()
        }
        if elementName == "enclosure", inItem {
            guard var item = currentItem else { return }
            let urlString = attributes["url"] ?? ""
            guard let url = URL(string: urlString), url.scheme == "https" else {
                parseError = CLIProxyManagerCommandError.operation("App update enclosure must use HTTPS.")
                parser.abortParsing()
                return
            }
            item.enclosureURL = url
            if let sig = attributes["sparkle:edSignature"] { item.edSignature = sig }
            if let versionStr = attributes["sparkle:version"], let build = Int(versionStr), build > afterBuild {
                item.build = build
            }
            if let shortVer = attributes["sparkle:shortVersionString"] { item.shortVersion = shortVer }
            if let lengthStr = attributes["length"], let len = parsePositiveInt(lengthStr) { item.expectedLength = len }
            currentItem = item
        }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        if elementName == "item" {
            inItem = false
            if let item = currentItem,
               let build = item.build,
               let url = item.enclosureURL,
               let length = item.expectedLength,
               let sig = item.edSignature,
               let version = item.shortVersion {
                let release = AppUpdateRelease(version: version, build: build, enclosureURL: url, expectedLength: length, edSignature: sig)
                if let best = bestRelease {
                    if build > best.build { bestRelease = release }
                } else {
                    bestRelease = release
                }
            }
            currentItem = nil
        }
    }

    func parserDidEndDocument(_ parser: XMLParser) {}

    func parser(_ parser: XMLParser, parseErrorOccurred parseError: Error) {
        if self.parseError == nil {
            self.parseError = parseError
        }
    }

    private func parsePositiveInt(_ s: String) -> Int? {
        let trimmed = s.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !trimmed.contains("."), !trimmed.hasPrefix("-"), !trimmed.hasPrefix("+") else { return nil }
        guard let value = Int(trimmed), value > 0 else { return nil }
        return value
    }
}
