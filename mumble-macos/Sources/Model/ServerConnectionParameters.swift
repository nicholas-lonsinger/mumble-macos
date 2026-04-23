import Foundation

struct ServerConnectionParameters: Sendable, Equatable {
    var host: String
    var port: UInt16
    var username: String
    var password: String

    static let defaultPublicTestServer = ServerConnectionParameters(
        host: "mumble.sh1t.space",
        port: 64738,
        username: "[TRYHD] Fenix878",
        password: ""
    )
}
