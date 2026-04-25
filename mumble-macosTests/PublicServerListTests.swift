import XCTest
@testable import mumble_macos

/// Tests for the `PublicServerListFetcher` XML parser. Live network calls
/// would be flaky and slow, so these exercise the parser with synthesized
/// payloads modelled on the live response shape (verified at impl time
/// against publist.mumble.info).
final class PublicServerListTests: XCTestCase {

    private func parse(_ xml: String) throws -> [PublicServerEntry] {
        let data = Data(xml.utf8)
        return try PublicServerListFetcher.parseXML(data)
    }

    // MARK: - Happy path

    func test_parsesWellFormedList() throws {
        let xml = """
        <?xml version='1.0' standalone='yes'?>
        <servers>
            <server name="Alpha" ca="0" continent_code="EU" country="Germany" country_code="DE" ip="alpha.example" port="64738" region="Berlin" url="https://alpha.example" />
            <server name="Beta" ca="1" continent_code="NA" country="United States of America" country_code="US" ip="beta.example" port="2026" region="California" url="https://beta.example" />
        </servers>
        """
        let entries = try parse(xml)
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries[0].name, "Alpha")
        XCTAssertEqual(entries[0].host, "alpha.example")
        XCTAssertEqual(entries[0].port, 64738)
        XCTAssertEqual(entries[0].continentCode, "EU")
        XCTAssertEqual(entries[0].countryCode, "DE")
        XCTAssertEqual(entries[1].name, "Beta")
        XCTAssertEqual(entries[1].port, 2026)
        XCTAssertEqual(entries[1].countryCode, "US")
    }

    // MARK: - Skip-malformed semantics

    func test_skipsRowsMissingHost() throws {
        // The publist regularly carries a few rows with missing/garbage
        // attributes. Skip them quietly rather than failing the whole list.
        let xml = """
        <servers>
            <server name="Good" ip="ok.example" port="64738" />
            <server name="NoHost" port="64738" />
            <server name="" ip="empty-name.example" port="64738" />
            <server ip="no-name.example" port="64738" />
            <server name="BadPort" ip="bad-port.example" port="999999" />
            <server name="OK2" ip="ok2.example" port="64738" />
        </servers>
        """
        let entries = try parse(xml)
        XCTAssertEqual(entries.map(\.name), ["Good", "OK2"])
    }

    // MARK: - Failure modes

    func test_emptyDocumentReturnsEmpty() throws {
        let xml = "<servers></servers>"
        XCTAssertTrue(try parse(xml).isEmpty)
    }

    func test_malformedXMLThrows() {
        let xml = "<servers><server name=\"Bad\""
        XCTAssertThrowsError(try parse(xml)) { error in
            guard case PublicServerListError.parseFailed = error else {
                return XCTFail("Expected parseFailed, got \(error)")
            }
        }
    }

    // MARK: - Unicode + entity handling

    func test_decodesUTF8AndEntities() throws {
        let xml = """
        <servers>
            <server name="Café &amp; co" ip="cafe.example" port="64738" />
            <server name="日本語" ip="jp.example" port="64738" />
        </servers>
        """
        let entries = try parse(xml)
        XCTAssertEqual(entries.map(\.name), ["Café & co", "日本語"])
    }
}
