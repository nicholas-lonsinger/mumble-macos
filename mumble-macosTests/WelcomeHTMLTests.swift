import XCTest
@testable import mumble_macos

/// Adversarial-input regression tests for `WelcomeHTML.sanitize`.
final class WelcomeHTMLTests: XCTestCase {

    // MARK: - <img src>: only data: survives

    func test_stripHttpImgSrc() {
        let out = WelcomeHTML.sanitize(#"<img src="http://evil.example/x.png">"#)
        XCTAssertFalse(out.localizedCaseInsensitiveContains("evil.example"))
    }

    func test_stripHttpsImgSrc() {
        let out = WelcomeHTML.sanitize(#"<img src="https://evil.example/x.png">"#)
        XCTAssertFalse(out.localizedCaseInsensitiveContains("evil.example"))
    }

    func test_stripProtocolRelativeImgSrc() {
        let out = WelcomeHTML.sanitize(#"<img src="//evil.example/x.png">"#)
        XCTAssertFalse(out.localizedCaseInsensitiveContains("evil.example"))
    }

    func test_stripUppercaseSchemeImgSrc() {
        let out = WelcomeHTML.sanitize(#"<img src="HTTPS://evil.example/x.png">"#)
        XCTAssertFalse(out.localizedCaseInsensitiveContains("evil.example"))
    }

    func test_stripWhitespacePrefixedImgSrc() {
        let out = WelcomeHTML.sanitize(#"<img src="   http://evil.example/x.png">"#)
        XCTAssertFalse(out.localizedCaseInsensitiveContains("evil.example"))
    }

    func test_stripEntityEncodedImgSrc() {
        // `&#104;` decodes to 'h' inside XMLDocument, so the scheme check
        // sees `http://evil.example/...` and blanks it.
        let out = WelcomeHTML.sanitize("<img src=\"&#104;ttp://evil.example/x.png\">")
        XCTAssertFalse(out.localizedCaseInsensitiveContains("evil.example"))
    }

    func test_preserveDataImgSrc() {
        let out = WelcomeHTML.sanitize(#"<img src="data:image/png;base64,AAAA">"#)
        XCTAssertTrue(out.contains("data:image/png"))
    }

    // MARK: - <a href>: http(s) / mailto / data: allowed

    func test_preserveHttpAnchor() {
        let out = WelcomeHTML.sanitize(#"<a href="http://example.com">x</a>"#)
        XCTAssertTrue(out.contains("example.com"))
    }

    func test_preserveMailtoAnchor() {
        let out = WelcomeHTML.sanitize(#"<a href="mailto:foo@example.com">x</a>"#)
        XCTAssertTrue(out.contains("mailto:foo@example.com"))
    }

    func test_stripJavascriptAnchor() {
        let out = WelcomeHTML.sanitize(#"<a href="javascript:alert(1)">x</a>"#)
        XCTAssertFalse(out.localizedCaseInsensitiveContains("javascript"))
        XCTAssertFalse(out.contains("alert(1)"))
    }

    func test_stripFileAnchor() {
        let out = WelcomeHTML.sanitize(#"<a href="file:///etc/passwd">x</a>"#)
        XCTAssertFalse(out.contains("file:"))
        XCTAssertFalse(out.contains("passwd"))
    }

    func test_stripVbscriptAnchor() {
        let out = WelcomeHTML.sanitize(#"<a href="vbscript:msgbox">x</a>"#)
        XCTAssertFalse(out.localizedCaseInsensitiveContains("vbscript"))
    }

    // MARK: - Whole-element drops

    func test_dropScript() {
        let out = WelcomeHTML.sanitize("<p>before</p><script>alert(1)</script><p>after</p>")
        XCTAssertFalse(out.contains("<script"))
        XCTAssertFalse(out.contains("alert(1)"))
        XCTAssertTrue(out.contains("before"))
        XCTAssertTrue(out.contains("after"))
    }

    func test_dropStyle() {
        let out = WelcomeHTML.sanitize(#"<style>@import url(http://evil.example/x.css)</style>"#)
        XCTAssertFalse(out.localizedCaseInsensitiveContains("evil.example"))
        XCTAssertFalse(out.contains("<style"))
    }

    func test_dropIframe() {
        let out = WelcomeHTML.sanitize(#"<iframe src="data:text/html,x"></iframe>"#)
        XCTAssertFalse(out.contains("<iframe"))
    }

    func test_dropBase() {
        let out = WelcomeHTML.sanitize(#"<base href="http://evil.example/">"#)
        XCTAssertFalse(out.localizedCaseInsensitiveContains("evil.example"))
        XCTAssertFalse(out.contains("<base"))
    }

    func test_dropRefreshMeta() {
        let out = WelcomeHTML.sanitize(#"<meta http-equiv="refresh" content="0;url=http://evil.example/">"#)
        XCTAssertFalse(out.localizedCaseInsensitiveContains("evil.example"))
        XCTAssertFalse(out.localizedCaseInsensitiveContains("refresh"))
    }

    // MARK: - style attribute

    func test_dropStyleWithUrl() {
        let out = WelcomeHTML.sanitize(#"<div style="background:url(http://evil.example/bg.png)">x</div>"#)
        XCTAssertFalse(out.localizedCaseInsensitiveContains("evil.example"))
    }

    func test_preserveStyleWithoutUrl() {
        let out = WelcomeHTML.sanitize(#"<div style="color: red; font-weight: bold">x</div>"#)
        XCTAssertTrue(out.contains("color"))
        XCTAssertTrue(out.contains("red"))
    }

    // MARK: - Event handlers

    func test_dropEventHandlers() {
        let out = WelcomeHTML.sanitize(#"<div onclick="alert(1)" onmouseover="alert(2)">x</div>"#)
        XCTAssertFalse(out.contains("onclick"))
        XCTAssertFalse(out.contains("onmouseover"))
        XCTAssertFalse(out.contains("alert"))
    }

    // MARK: - Multibyte UTF-8

    /// Guards the libtidy-Latin-1-default trap: without a UTF-8 BOM on
    /// `XMLDocument`'s input, multi-byte characters get parsed as
    /// per-byte Latin-1 codepoints and round-trip as mojibake.
    func test_preserveBoxDrawingUtf8() {
        let out = WelcomeHTML.sanitize("<p>║═╗╝</p>")
        XCTAssertTrue(out.contains("║"))
        XCTAssertTrue(out.contains("═"))
        XCTAssertTrue(out.contains("╗"))
        XCTAssertTrue(out.contains("╝"))
    }
}
