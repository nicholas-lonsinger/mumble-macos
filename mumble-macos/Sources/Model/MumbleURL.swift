import Foundation

/// Parsed `mumble://` URL. Mirrors the fields the reference client accepts in
/// `MainWindow::openUrl` (src/mumble/MainWindow.cpp:1271):
///
///     mumble://[user[:password]@]host[:port][/channel/path][?version=X.Y.Z&title=Name]
///
/// `port` defaults to 64738 (`DEFAULT_MUMBLE_PORT`) when absent. Userinfo and
/// channel segments are percent-decoded here so that callers can drop them
/// straight into the Connect form.
struct MumbleURL: Equatable, Sendable {
    var host: String
    var port: UInt16
    var username: String?
    var password: String?
    /// Channel path split on `/`, with empty segments removed. `["Lobby", "Music"]`
    /// for `mumble://host/Lobby/Music`. Empty means "server root".
    var channelPath: [String]
    /// Optional `title` query parameter — the server's display name as
    /// chosen by whoever made the link. We don't surface it yet.
    var title: String?
    /// Optional `version` query parameter (e.g. `1.2.0`). Informational only.
    var version: String?

    static let defaultPort: UInt16 = 64738

    enum ParseError: Error, CustomStringConvertible, Equatable {
        case wrongScheme(String?)
        case missingHost
        case invalidPort(Int)

        var description: String {
            switch self {
            case .wrongScheme(let s):
                return "URL scheme is not 'mumble' (got \(s.map { "'\($0)'" } ?? "nil"))"
            case .missingHost:
                return "mumble:// URL has no host"
            case .invalidPort(let p):
                return "mumble:// URL has out-of-range port \(p)"
            }
        }
    }

    static func parse(_ url: URL) throws -> MumbleURL {
        guard let scheme = url.scheme?.lowercased(), scheme == "mumble" else {
            throw ParseError.wrongScheme(url.scheme)
        }

        // `URLComponents` gives us consistent access to user/password and the
        // query items, and it mirrors what the reference client does with
        // `QUrl::fromEncoded` + `QUrlQuery`.
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw ParseError.missingHost
        }

        guard let rawHost = components.host, !rawHost.isEmpty else {
            throw ParseError.missingHost
        }

        let port: UInt16
        if let p = components.port {
            guard let u16 = UInt16(exactly: p), u16 != 0 else {
                throw ParseError.invalidPort(p)
            }
            port = u16
        } else {
            port = Self.defaultPort
        }

        let username = components.user.flatMap { $0.isEmpty ? nil : $0 }
        let password = components.password.flatMap { $0.isEmpty ? nil : $0 }

        // `URLComponents.path` is already percent-decoded — split on the
        // literal '/' is enough. (Channel names containing an encoded '%2F'
        // would still split here; the reference client has the same
        // limitation in `MainWindow::findDesiredChannel`.)
        let channelPath = components.path
            .split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)

        let queryItems = components.queryItems ?? []
        let title = queryItems.first(where: { $0.name == "title" })?.value
        let version = queryItems.first(where: { $0.name == "version" })?.value

        return MumbleURL(
            host: rawHost,
            port: port,
            username: username,
            password: password,
            channelPath: channelPath,
            title: title,
            version: version
        )
    }

    /// Render a `mumble://` URL for logging without leaking the password.
    /// Mirrors the reference client's `QUrl::RemovePassword` formatting
    /// (`MainWindow::openUrl` line 1273): username, host, port, path, and
    /// query are kept; only the password is stripped.
    static func redactingPassword(_ url: URL) -> String {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.password = nil
        return components?.string ?? "<unparseable mumble:// URL>"
    }

    /// Materialise connection parameters for `MumbleClient.connect(to:)`.
    /// `username` and `password` fall back to the caller-supplied defaults
    /// when the URL didn't carry them — the defaults come from the Connect
    /// form's persisted values so the user doesn't have to retype them.
    func connectionParameters(defaultUsername: String, defaultPassword: String = "") -> ServerConnectionParameters {
        ServerConnectionParameters(
            host: host,
            port: port,
            username: username ?? defaultUsername,
            password: password ?? defaultPassword
        )
    }
}
