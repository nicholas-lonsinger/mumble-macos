import Foundation

struct ServerConnectionParameters: Sendable, Equatable {
    var host: String
    var port: UInt16
    var username: String
    var password: String

    static let defaultPublicTestServer = ServerConnectionParameters(
        host: "mumble.info",
        port: 64738,
        username: "MumbleMacOSTester",
        password: ""
    )
}
