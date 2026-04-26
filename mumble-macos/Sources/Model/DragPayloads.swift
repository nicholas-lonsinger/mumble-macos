import CoreTransferable
import Foundation
import UniformTypeIdentifiers

/// In-app drag payloads.
///
/// `UTType(exportedAs:)` normally pairs with a matching
/// `UTExportedTypeDeclarations` entry in `Info.plist` — that's how
/// macOS publishes the type identifier system-wide. We deliberately
/// skip the Info.plist declaration here because the drag is purely
/// intra-app: we don't want other apps recognizing or claiming drops
/// of our internal server / group IDs, and we don't want LaunchServices
/// to associate `.savedserver` or similar with our app. SwiftUI's
/// `dropDestination(for:)` matches by Transferable type / `contentType`
/// string equality at runtime, which works for unregistered UTIs as
/// long as both source and destination live in the same process.
///
/// Distinct UTI strings keep the server drop target from satisfying a
/// group drop (and vice versa) — both decode to UUID and would
/// otherwise be ambiguous to SwiftUI.
///
/// If a future need arises (e.g. promoting drag to inter-app paste or
/// to the Files clipboard), declaring these in Info.plist becomes
/// straightforward.
extension UTType {
    static let mumbleSavedServerPayload =
        UTType(exportedAs: "com.nicholas-lonsinger.mumble-macos.saved-server-payload")
    static let mumbleServerGroupPayload =
        UTType(exportedAs: "com.nicholas-lonsinger.mumble-macos.server-group-payload")
}

struct SavedServerPayload: Codable, Transferable {
    let id: UUID
    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .mumbleSavedServerPayload)
    }
}

struct ServerGroupPayload: Codable, Transferable {
    let id: UUID
    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .mumbleServerGroupPayload)
    }
}
