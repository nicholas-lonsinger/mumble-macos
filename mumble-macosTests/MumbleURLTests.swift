import XCTest
@testable import mumble_macos

/// Regression tests for `MumbleURL.parse`. The field set matches the reference
/// client's `MainWindow::openUrl` (src/mumble/MainWindow.cpp:1271) so a user
/// clicking the same `mumble://` link in either client should reach the same
/// server with the same identity.
final class MumbleURLTests: XCTestCase {

    // MARK: - Basic shapes

    func test_userAtHost_defaultsPort() throws {
        let url = try XCTUnwrap(URL(string: "mumble://Fenix878@zero.the-initiative.rocks"))
        let parsed = try MumbleURL.parse(url)

        XCTAssertEqual(parsed.host, "zero.the-initiative.rocks")
        XCTAssertEqual(parsed.port, 64738)
        XCTAssertEqual(parsed.username, "Fenix878")
        XCTAssertNil(parsed.password)
        XCTAssertTrue(parsed.channelPath.isEmpty)
        XCTAssertNil(parsed.title)
        XCTAssertNil(parsed.version)
    }

    func test_hostOnly_noUser() throws {
        let url = try XCTUnwrap(URL(string: "mumble://example.org"))
        let parsed = try MumbleURL.parse(url)

        XCTAssertEqual(parsed.host, "example.org")
        XCTAssertEqual(parsed.port, 64738)
        XCTAssertNil(parsed.username)
    }

    func test_explicitPort() throws {
        let url = try XCTUnwrap(URL(string: "mumble://alice@example.org:12345"))
        let parsed = try MumbleURL.parse(url)

        XCTAssertEqual(parsed.host, "example.org")
        XCTAssertEqual(parsed.port, 12345)
        XCTAssertEqual(parsed.username, "alice")
    }

    func test_passwordParsed() throws {
        let url = try XCTUnwrap(URL(string: "mumble://alice:hunter2@example.org:64738"))
        let parsed = try MumbleURL.parse(url)

        XCTAssertEqual(parsed.username, "alice")
        XCTAssertEqual(parsed.password, "hunter2")
    }

    // MARK: - Percent-encoded userinfo (the real-world reason this feature exists)

    func test_percentEncodedUsername_decodesBracketsAndSpace() throws {
        // [TRYHD] Fenix878 — brackets and space must be encoded in a URL.
        let url = try XCTUnwrap(URL(string: "mumble://%5BTRYHD%5D%20Fenix878@mumble.sh1t.space"))
        let parsed = try MumbleURL.parse(url)

        XCTAssertEqual(parsed.host, "mumble.sh1t.space")
        XCTAssertEqual(parsed.username, "[TRYHD] Fenix878")
    }

    func test_percentEncodedPassword() throws {
        let url = try XCTUnwrap(URL(string: "mumble://alice:p%40ss%20word@example.org"))
        let parsed = try MumbleURL.parse(url)

        XCTAssertEqual(parsed.username, "alice")
        XCTAssertEqual(parsed.password, "p@ss word")
    }

    // MARK: - Channel path

    func test_channelPath_singleSegment() throws {
        let url = try XCTUnwrap(URL(string: "mumble://alice@example.org/Lobby"))
        let parsed = try MumbleURL.parse(url)

        XCTAssertEqual(parsed.channelPath, ["Lobby"])
    }

    func test_channelPath_multiSegment_dropsEmptyAndDecodes() throws {
        let url = try XCTUnwrap(URL(string: "mumble://alice@example.org//Music%20Room/Lounge/"))
        let parsed = try MumbleURL.parse(url)

        XCTAssertEqual(parsed.channelPath, ["Music Room", "Lounge"])
    }

    // MARK: - Query parameters

    func test_titleAndVersion() throws {
        let url = try XCTUnwrap(URL(string: "mumble://alice@example.org/?version=1.5.0&title=My%20Server"))
        let parsed = try MumbleURL.parse(url)

        XCTAssertEqual(parsed.version, "1.5.0")
        XCTAssertEqual(parsed.title, "My Server")
    }

    // MARK: - Rejection cases

    func test_wrongScheme_rejected() {
        let url = URL(string: "https://example.org")!
        XCTAssertThrowsError(try MumbleURL.parse(url)) { error in
            guard case MumbleURL.ParseError.wrongScheme(let s) = error else {
                return XCTFail("expected wrongScheme, got \(error)")
            }
            XCTAssertEqual(s, "https")
        }
    }

    func test_missingHost_rejected() {
        // `mumble:` with no authority — RFC 3986 says no host.
        let url = URL(string: "mumble:")!
        XCTAssertThrowsError(try MumbleURL.parse(url)) { error in
            guard case MumbleURL.ParseError.missingHost = error else {
                return XCTFail("expected missingHost, got \(error)")
            }
        }
    }

    func test_portOutOfRange_rejected() throws {
        // URLComponents accepts up to 2^31-1 as an Int, but anything outside
        // 1...65535 makes no sense for TCP.
        var c = URLComponents()
        c.scheme = "mumble"
        c.host = "example.org"
        c.port = 99999
        let url = try XCTUnwrap(c.url)

        XCTAssertThrowsError(try MumbleURL.parse(url)) { error in
            guard case MumbleURL.ParseError.invalidPort(let p) = error else {
                return XCTFail("expected invalidPort, got \(error)")
            }
            XCTAssertEqual(p, 99999)
        }
    }

    // MARK: - connectionParameters

    func test_connectionParameters_fallsBackToDefaultUsername() throws {
        let url = try XCTUnwrap(URL(string: "mumble://example.org"))
        let parsed = try MumbleURL.parse(url)
        let params = parsed.connectionParameters(defaultUsername: "saved-user")

        XCTAssertEqual(params.host, "example.org")
        XCTAssertEqual(params.port, 64738)
        XCTAssertEqual(params.username, "saved-user")
        XCTAssertEqual(params.password, "")
    }

    func test_connectionParameters_urlUsernameWins() throws {
        let url = try XCTUnwrap(URL(string: "mumble://Fenix878@example.org"))
        let parsed = try MumbleURL.parse(url)
        let params = parsed.connectionParameters(defaultUsername: "saved-user")

        XCTAssertEqual(params.username, "Fenix878")
    }
}
