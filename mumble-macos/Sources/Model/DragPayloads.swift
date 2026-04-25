import CoreTransferable
import Foundation
import UniformTypeIdentifiers

/// In-app drag payloads. These UTIs are defined ad-hoc — they're not
/// declared in `Info.plist` because the drag is purely intra-app and we
/// don't want other apps to recognize or claim drops of our internal
/// IDs. SwiftUI matches `dropDestination(for:)` by Transferable type,
/// which in turn matches by `contentType`; distinct UTIs let us drop a
/// server onto a server target without accidentally satisfying a group
/// drop target (and vice versa).
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
