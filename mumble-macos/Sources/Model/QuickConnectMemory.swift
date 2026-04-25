import Foundation
import Observation

/// In-memory holder for the password most recently typed into the Quick
/// Connect form. Survives sheet open/close within a session; wiped on
/// app quit. Saved bookmarks persist their passwords through
/// `ServerPasswordStore` (data-protection keychain) instead — see
/// CLAUDE.md and the spec in the chat for the rationale.
///
/// Host/port/username for Quick Connect remain in `@AppStorage` (their
/// values aren't sensitive). Only the password lives here.
@MainActor
@Observable
final class QuickConnectMemory {
    static let shared = QuickConnectMemory()

    var lastPassword: String = ""

    private init() {}
}
