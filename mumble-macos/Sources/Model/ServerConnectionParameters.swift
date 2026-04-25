import Foundation

struct ServerConnectionParameters: Sendable, Equatable {
    var host: String
    var port: UInt16
    var username: String
    var password: String
    /// Channel path the user wants to join after `ServerSync`. Empty means
    /// "wherever the server places me". Populated when the connect attempt
    /// originated from a `mumble://host/Channel/Sub` URL.
    var desiredChannelPath: [String] = []

    static let defaultPublicTestServer = ServerConnectionParameters(
        host: "mumble.sh1t.space",
        port: 64738,
        username: "[TRYHD] Fenix878",
        password: ""
    )
}
