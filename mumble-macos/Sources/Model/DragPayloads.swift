import AppKit

/// In-app drag payloads for the Servers source list.
///
/// Custom pasteboard types normally pair with `UTExportedTypeDeclarations`
/// in `Info.plist` — that's how macOS publishes the identifier system-wide.
/// We deliberately skip the declaration because the drag is purely
/// intra-app: we don't want other apps recognizing or claiming drops of
/// our internal server / group IDs, and we don't want LaunchServices to
/// associate the types with our app. The Servers outline view additionally
/// restricts its drag sessions to `.withinApplication`.
///
/// Distinct type strings keep a server drop target from satisfying a
/// group drop (and vice versa) — both payloads are just a UUID string
/// and would otherwise be ambiguous.
///
/// If a future need arises (e.g. promoting drag to inter-app paste),
/// declaring these in Info.plist becomes straightforward.
extension NSPasteboard.PasteboardType {
    static let mumbleSavedServerPayload = NSPasteboard.PasteboardType(
        "com.nicholas-lonsinger.mumble-macos.saved-server-payload")
    static let mumbleServerGroupPayload = NSPasteboard.PasteboardType(
        "com.nicholas-lonsinger.mumble-macos.server-group-payload")
}
