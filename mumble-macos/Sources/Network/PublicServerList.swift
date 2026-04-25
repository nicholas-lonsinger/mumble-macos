import Foundation
import OSLog

/// One row from the Mumble public server list.
struct PublicServerEntry: Equatable, Sendable {
    let name: String
    let host: String
    let port: UInt16
    /// 2-letter continent code (e.g. "EU"). Carried for future filter UI;
    /// not displayed in the source list today.
    let continentCode: String?
    /// 2-letter ISO country code (e.g. "DE").
    let countryCode: String?
}

enum PublicServerListError: Error, LocalizedError {
    case badStatus(Int)
    case parseFailed(underlying: Error?)
    case noServers

    var errorDescription: String? {
        switch self {
        case .badStatus(let code):
            return "Public list endpoint returned HTTP \(code)."
        case .parseFailed(let err):
            return "Couldn't parse the public list XML: \(err?.localizedDescription ?? "unknown error")."
        case .noServers:
            return "Public list was empty."
        }
    }
}

/// Fetches the canonical Mumble public server list from
/// `publist.mumble.info` and parses the XML response.
///
/// The endpoint requires `POST` (a `GET` is rejected with HTTP 501). The
/// payload format matches the reference Mumble client's expectation,
/// confirmed by probing the live endpoint:
///
///     <servers>
///         <server name="..." ip="host" port="64738"
///                 continent_code="EU" country_code="DE" ... />
///         …
///     </servers>
struct PublicServerListFetcher: Sendable {
    static let endpoint = URL(string: "https://publist.mumble.info/v1/list")!
    private static let log = Logger(subsystem: "com.nicholas-lonsinger.mumble-macos",
                                    category: "publist")

    /// Test seam — production passes the shared session.
    let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func fetch() async throws -> [PublicServerEntry] {
        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        // Mumble's publist accepts this minimal request shape; the
        // reference client also sends version/guid, but those aren't
        // required for the response and we'd rather not advertise a
        // version we don't honor exactly.
        request.setValue("mumble-macos", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 15

        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw PublicServerListError.badStatus(http.statusCode)
        }
        let entries = try Self.parseXML(data)
        if entries.isEmpty { throw PublicServerListError.noServers }
        Self.log.info("Fetched \(entries.count, privacy: .public) public servers")
        return entries
    }

    /// Internal so tests can drive the parser without mocking URLSession.
    static func parseXML(_ data: Data) throws -> [PublicServerEntry] {
        let parser = XMLParser(data: data)
        let delegate = ServerListXMLDelegate()
        parser.delegate = delegate
        guard parser.parse() else {
            throw PublicServerListError.parseFailed(underlying: parser.parserError)
        }
        return delegate.entries
    }
}

private final class ServerListXMLDelegate: NSObject, XMLParserDelegate {
    var entries: [PublicServerEntry] = []

    func parser(_ parser: XMLParser,
                didStartElement elementName: String,
                namespaceURI: String?,
                qualifiedName qName: String?,
                attributes attributeDict: [String: String]) {
        guard elementName == "server" else { return }
        guard let name = attributeDict["name"],
              let host = attributeDict["ip"],
              let portString = attributeDict["port"],
              let port = UInt16(portString),
              !name.isEmpty, !host.isEmpty
        else {
            // Skip malformed rows rather than fail the whole list — the
            // publist regularly carries a few entries with garbage data.
            return
        }
        entries.append(PublicServerEntry(
            name: name,
            host: host,
            port: port,
            continentCode: attributeDict["continent_code"],
            countryCode: attributeDict["country_code"]
        ))
    }
}
