import AppKit
import Foundation
import SwiftUI

/// Renders a Mumble server welcome message (HTML) as an attributed string.
///
/// Mirrors the reference client's resource-loading policy (see
/// `mumble/src/mumble/Log.cpp` `LogDocument::loadResource`): only `data:`
/// URLs are honored; every other scheme is blanked. We do this at parse
/// time because `NSAttributedString`'s HTML loader has no public hook to
/// intercept resource loads — by the time it returns, any surviving
/// `http(s):` URL has already been fetched on the main thread (info leak
/// + UI-hang DoS vector).
///
/// Pipeline: bytes → `XMLDocument(.documentTidyHTML)` (libtidy normalizes
/// loose HTML and decodes entities) → DOM walk that strips dangerous
/// elements and rewrites URL-bearing attributes → re-serialize → hand to
/// `NSAttributedString(data:.html)`.
enum WelcomeHTML {
    /// Element names whose entire subtree we drop. `base` is here
    /// because a hostile base href could change how the HTML loader
    /// resolves any URL we missed scrubbing. `<meta>` is *not* here —
    /// tidy auto-injects `<meta http-equiv="Content-Type" charset=utf-8>`
    /// and `NSAttributedString`'s HTML loader honors that over the
    /// `.characterEncoding` option; stripping it produced mojibake on
    /// non-ASCII content (box-drawing chars, emoji). Dangerous meta
    /// variants (`http-equiv="refresh"`) are stripped per-element below.
    private static let blockedElements: Set<String> = [
        "script", "style", "link", "iframe", "frame", "frameset",
        "object", "embed", "base", "form", "input", "button",
        "noscript", "applet", "textarea", "select", "option",
    ]

    /// Attributes that resolve a URL the HTML loader will fetch. We
    /// blank the value unless the scheme is `data:`. Anchor-style `href`
    /// is handled separately (`anchorTags` below) because user-clicked
    /// links are fine for `http(s):`/`mailto:`.
    private static let urlAttributes: Set<String> = [
        "src", "xlink:href", "data", "poster", "background",
        "cite", "formaction", "action", "longdesc",
        "usemap", "ping", "manifest",
    ]

    /// Attributes whose value can encode multiple URLs in one string
    /// (`srcset` is comma-separated `url descriptor` pairs, and a `data:`
    /// URL itself contains commas, so we can't reliably split-and-scrub
    /// per candidate). Always blanked. Mumble welcome text doesn't need
    /// responsive image sets, and the reference Qt client (HTML4-era)
    /// doesn't honor srcset anyway.
    private static let unconditionalBlankAttributes: Set<String> = [
        "srcset",
    ]

    /// Tags whose `href` attribute is a user-clicked navigation target
    /// rather than an auto-loaded resource. Allowed schemes:
    /// `http(s):`/`mailto:`/`data:`.
    private static let anchorTags: Set<String> = ["a", "area"]

    static func attributedString(from raw: String) -> NSAttributedString {
        guard !raw.isEmpty else { return NSAttributedString() }
        let sanitized = sanitize(raw)
        guard let body = sanitized.data(using: .utf8) else {
            return NSAttributedString(string: raw)
        }
        // Prepend UTF-8 BOM. `NSAttributedString`'s HTML loader checks the
        // BOM before any `<meta>` charset declaration and before the
        // `.characterEncoding` option — and on macOS we observed it
        // ignoring both, decoding as Windows-1252 and producing mojibake
        // on multibyte chars like box-drawing glyphs and emoji.
        let data = Data([0xEF, 0xBB, 0xBF]) + body
        let opts: [NSAttributedString.DocumentReadingOptionKey: Any] = [
            .documentType: NSAttributedString.DocumentType.html,
            .characterEncoding: String.Encoding.utf8.rawValue,
        ]
        do {
            return try NSAttributedString(data: data, options: opts, documentAttributes: nil)
        } catch {
            return NSAttributedString(string: raw)
        }
    }

    static func sanitize(_ raw: String) -> String {
        guard let body = raw.data(using: .utf8) else {
            return "<pre>\(escapeHTML(raw))</pre>"
        }
        // libtidy (driving `.documentTidyHTML`) defaults to Latin-1 for
        // input with no encoding declared, which mangles multi-byte UTF-8
        // sequences (box-drawing chars, emoji) into per-byte codepoints
        // *before* the DOM is built — corruption that no downstream
        // charset hint can undo. Prepending a UTF-8 BOM tells tidy the
        // input is UTF-8.
        let data = Data([0xEF, 0xBB, 0xBF]) + body
        guard let doc = try? XMLDocument(data: data, options: [.documentTidyHTML]) else {
            return "<pre>\(escapeHTML(raw))</pre>"
        }
        if let root = doc.rootElement() {
            sanitize(element: root)
            ensureCharsetMeta(in: root)
        }
        return doc.xmlString
    }

    /// Inject `<meta http-equiv="Content-Type" content="text/html; charset=utf-8">`
    /// as the first child of `<head>`. `NSAttributedString`'s HTML loader
    /// reads charset from `<meta>`, not from the XML declaration tidy emits;
    /// without this, non-ASCII bytes (box-drawing chars, emoji) get decoded
    /// as Windows-1252 even though we pass `.characterEncoding: utf8`.
    private static func ensureCharsetMeta(in root: XMLElement) {
        let head: XMLElement
        if let existing = root.elements(forName: "head").first {
            head = existing
        } else {
            head = XMLElement(name: "head")
            root.insertChild(head, at: 0)
        }
        for meta in head.elements(forName: "meta") {
            let httpEquiv = meta.attribute(forName: "http-equiv")?.stringValue?.lowercased()
            let hasCharset = meta.attribute(forName: "charset") != nil
            if httpEquiv == "content-type" || hasCharset {
                head.removeChild(at: meta.index)
            }
        }
        let charsetMeta = XMLElement(name: "meta")
        charsetMeta.setAttributesWith([
            "http-equiv": "Content-Type",
            "content": "text/html; charset=utf-8",
        ])
        head.insertChild(charsetMeta, at: 0)
    }

    /// Iterative DFS — recursion bound by libtidy-normalized DOM depth,
    /// which can in principle be hundreds of thousands deep on hostile
    /// input. The default 8 MB macOS stack would overflow well before
    /// that, so we walk explicitly.
    ///
    /// Tag names below are compared lowercased; tidy normalizes element
    /// names during parse, but we lowercase again here for defense.
    private static func sanitize(element root: XMLElement) {
        var stack: [XMLElement] = [root]
        while let current = stack.popLast() {
            var i = 0
            while i < current.childCount {
                guard let child = current.child(at: i) else { break }
                if let childEl = child as? XMLElement {
                    let tag = (childEl.name ?? "").lowercased()
                    if blockedElements.contains(tag) {
                        current.removeChild(at: i)
                        continue
                    }
                    if tag == "meta" && isRefreshMeta(childEl) {
                        current.removeChild(at: i)
                        continue
                    }
                    sanitizeAttributes(of: childEl, tag: tag)
                    stack.append(childEl)
                }
                i += 1
            }
        }
    }

    private static func sanitizeAttributes(of element: XMLElement, tag: String) {
        let names = (element.attributes ?? []).compactMap { $0.name }
        for originalName in names {
            let lower = originalName.lowercased()

            // Event handlers: `onclick`, `onerror`, etc.
            if lower.hasPrefix("on") {
                element.removeAttribute(forName: originalName)
                continue
            }

            // Inline CSS: any `url(…)` could fetch. Killing the whole
            // attribute is safer than parsing CSS strings here.
            if lower == "style" {
                let value = element.attribute(forName: originalName)?.stringValue ?? ""
                if value.range(of: "url(", options: .caseInsensitive) != nil {
                    element.removeAttribute(forName: originalName)
                }
                continue
            }

            if unconditionalBlankAttributes.contains(lower) {
                element.attribute(forName: originalName)?.stringValue = ""
                continue
            }

            if anchorTags.contains(tag) && lower == "href" {
                let value = element.attribute(forName: originalName)?.stringValue ?? ""
                if !isAllowedAnchorURL(value) {
                    element.attribute(forName: originalName)?.stringValue = ""
                }
                continue
            }

            if urlAttributes.contains(lower) {
                let value = element.attribute(forName: originalName)?.stringValue ?? ""
                if !isDataURL(value) {
                    element.attribute(forName: originalName)?.stringValue = ""
                }
                continue
            }
        }
    }

    private static func isRefreshMeta(_ element: XMLElement) -> Bool {
        guard let attrs = element.attributes else { return false }
        return attrs.contains { attr in
            guard (attr.name ?? "").lowercased() == "http-equiv" else { return false }
            return (attr.stringValue ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased() == "refresh"
        }
    }

    private static func isDataURL(_ raw: String) -> Bool {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .hasPrefix("data:")
    }

    private static func isAllowedAnchorURL(_ raw: String) -> Bool {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return trimmed.hasPrefix("http://")
            || trimmed.hasPrefix("https://")
            || trimmed.hasPrefix("mailto:")
            || trimmed.hasPrefix("data:")
    }

    private static func escapeHTML(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}

struct WelcomeTextView: View {
    let html: String

    /// Cached parse. Recomputed only when `html` changes — `MainView`
    /// re-evaluates on every channel/user mutation, and re-running the
    /// HTML loader each time would burn CPU for output that hasn't moved.
    @State private var attributed = AttributedString()

    var body: some View {
        ScrollView {
            Text(attributed)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(4)
        }
        .onChange(of: html, initial: true) { _, newValue in
            attributed = AttributedString(WelcomeHTML.attributedString(from: newValue))
        }
    }
}
