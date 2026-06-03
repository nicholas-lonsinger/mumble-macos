import AppKit

/// Validation shared by the two places a bookmark can be written (the
/// bookmark editor and Quick Connect's Save sheet) so the rules — and
/// their wording — can't drift apart.
enum BookmarkFormValidation {
    /// Returns a user-facing message, or nil when the values are saveable.
    static func validationError(port: String,
                                handling: PasswordHandling,
                                password: String) -> String? {
        guard UInt16(port) != nil else {
            return "Port must be 0–65535."
        }
        if handling == .useStoredPassword, password.isEmpty {
            return "Password is required when 'Use saved password' is selected."
        }
        return nil
    }
}

/// "Top Level" + the sorted groups, with the selection ↔ groupID mapping
/// (the +1 offset for the synthetic first item) owned in one place.
@MainActor
final class GroupPopup {
    let control = NSPopUpButton(frame: .zero, pullsDown: false)
    private let groups: [ServerGroup]

    init(groups: [ServerGroup], selected: UUID? = nil) {
        self.groups = groups
        control.addItem(withTitle: "Top Level")
        for group in groups {
            control.addItem(withTitle: group.name)
        }
        select(selected)
    }

    func select(_ groupID: UUID?) {
        if let groupID, let index = groups.firstIndex(where: { $0.id == groupID }) {
            control.selectItem(at: index + 1)   // +1 for "Top Level"
        } else {
            control.selectItem(at: 0)
        }
    }

    var selectedGroupID: UUID? {
        let index = control.indexOfSelectedItem
        return index > 0 ? groups[index - 1].id : nil
    }
}
