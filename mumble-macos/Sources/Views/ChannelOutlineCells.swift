import AppKit

/// Stable boxed identity for channel-tree rows. NSOutlineView keys
/// expansion state and `reloadItem` targeting on item identity, and the
/// model snapshots are value types that change on every update — so the
/// sidebar interns one of these per channel/user ID and reuses it across
/// reloads.
final class ChannelOutlineItem: NSObject {
    enum Kind: Hashable {
        case channel(UInt32)
        case user(UInt32)
    }

    let kind: Kind
    init(_ kind: Kind) { self.kind = kind }

    override func isEqual(_ object: Any?) -> Bool {
        (object as? ChannelOutlineItem)?.kind == kind
    }
    override var hash: Int { kind.hashValue }
}

/// Channel row: `#` icon + name. Click joins (handled by the outline
/// view's action, not the cell).
final class ChannelCellView: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("channel-cell")

    private let icon = NSImageView()
    private let nameLabel = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier
        icon.image = NSImage(systemSymbolName: "number", accessibilityDescription: nil)
        icon.contentTintColor = .secondaryLabelColor
        nameLabel.lineBreakMode = .byTruncatingTail
        let stack = NSStackView(views: [icon, nameLabel])
        stack.orientation = .horizontal
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -2),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("ChannelCellView does not support NSCoding")
    }

    func configure(name: String) {
        nameLabel.stringValue = name.isEmpty ? "(unnamed)" : name
    }
}

/// User row: state icon, name (semibold when it's us), trailing badges.
/// Badges are fixed image views toggled via `isHidden` (the stack view
/// collapses hidden arranged subviews) so the per-voice-packet reload
/// path is allocation-free.
final class UserCellView: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("user-cell")

    private let stateIcon = NSImageView()
    private let nameLabel = NSTextField(labelWithString: "")
    private let recordingBadge = UserCellView.makeBadge("record.circle", tint: .systemRed)
    private let priorityBadge = UserCellView.makeBadge("star.fill", tint: .systemYellow)
    private let mutedBadge = UserCellView.makeBadge("mic.slash.fill", tint: .secondaryLabelColor)
    private let deafenedBadge = UserCellView.makeBadge("speaker.slash.fill", tint: .secondaryLabelColor)

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier
        nameLabel.lineBreakMode = .byTruncatingTail
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let stack = NSStackView(views: [stateIcon, nameLabel, spacer,
                                        recordingBadge, priorityBadge, mutedBadge, deafenedBadge])
        stack.orientation = .horizontal
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("UserCellView does not support NSCoding")
    }

    func configure(user: UserNode, isOwn: Bool, isSpeaking: Bool) {
        let symbol: String
        let tint: NSColor
        if isSpeaking {
            symbol = "waveform"
            tint = .systemGreen
        } else if isOwn {
            symbol = "person.crop.circle.badge.checkmark"
            tint = .controlAccentColor
        } else {
            symbol = "person.crop.circle"
            tint = .labelColor
        }
        stateIcon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        stateIcon.contentTintColor = tint

        nameLabel.stringValue = user.name
        nameLabel.font = NSFont.systemFont(ofSize: NSFont.systemFontSize,
                                           weight: isOwn ? .semibold : .regular)

        recordingBadge.isHidden = !user.isRecording
        priorityBadge.isHidden = !user.isPrioritySpeaker
        mutedBadge.isHidden = !(user.isMuted || user.isSelfMuted)
        deafenedBadge.isHidden = !(user.isDeafened || user.isSelfDeafened)
    }

    private static func makeBadge(_ symbol: String, tint: NSColor) -> NSImageView {
        let view = NSImageView(image: NSImage(systemSymbolName: symbol,
                                              accessibilityDescription: nil)!)
        view.contentTintColor = tint
        view.isHidden = true
        return view
    }
}
