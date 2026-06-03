import AppKit
import OSLog

/// Owns the Preferences window. Native macOS pattern: an `NSWindow` with an
/// `NSToolbar` in the title bar (Safari/Messages prefs aesthetic), each
/// toolbar item representing a tab. New tabs get appended to `tabs` and
/// the toolbar delegate auto-picks them up.
@MainActor
final class PreferencesWindowController: NSWindowController, NSToolbarDelegate {
    private let client: MumbleClient
    /// Held so the Shortcuts tab can `pause()` it while the user is
    /// capturing a new chord — otherwise the dispatcher would fire bindings
    /// for the very keys the user is trying to bind.
    private let dispatcher: ShortcutDispatcher

    private static let log = Logger(subsystem: "com.nicholas-lonsinger.mumble-macos",
                                    category: "preferences-window")

    /// One `Tab` per content pane. The order here drives toolbar order and
    /// also the initial selection (first tab is selected on first show).
    private let tabs: [Tab] = [
        Tab(identifier: .general,
            label: "General",
            symbol: "gearshape"),
        Tab(identifier: .shortcuts,
            label: "Shortcuts",
            symbol: "character.book.closed")
    ]

    init(client: MumbleClient, dispatcher: ShortcutDispatcher) {
        self.client = client
        self.dispatcher = dispatcher

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 700, height: 500),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Mumble Preferences"
        window.setFrameAutosaveName(Self.autosaveName)
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 600, height: 400)

        super.init(window: window)

        configureToolbar(on: window)
        showTab(identifier: tabs[0].identifier)
        // Setting `contentViewController` can snap the window to the view's
        // fitting size. Pin to the intended frame explicitly — but only if
        // the user doesn't already have a saved frame, otherwise we'd
        // clobber their resized/repositioned window every relaunch.
        if !Self.hasSavedFrame(autosaveName: Self.autosaveName) {
            window.setContentSize(NSSize(width: 700, height: 500))
            window.center()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("PreferencesWindowController does not support NSCoding")
    }

    private static let autosaveName = "PreferencesWindow"

    /// AppKit stores autosaved window frames in `UserDefaults` under the
    /// key `"NSWindow Frame <autosaveName>"`. We can't rely on
    /// `setFrameAutosaveName(_:)` returning a Bool because it's no-return
    /// on macOS; checking the defaults directly is the documented dodge.
    nonisolated private static func hasSavedFrame(autosaveName: String) -> Bool {
        UserDefaults.standard.object(forKey: "NSWindow Frame \(autosaveName)") != nil
    }

    // MARK: - Tab content swap

    private func showTab(identifier: NSToolbarItem.Identifier) {
        guard let window else { return }
        // Frame-preserving swap: a plain assignment would shrink the
        // user's window to the new tab's fitting size on every switch.
        window.setContentViewControllerPreservingFrame(makeViewController(for: identifier),
                                                       display: true)
        window.toolbar?.selectedItemIdentifier = identifier
    }

    private func makeViewController(for identifier: NSToolbarItem.Identifier) -> NSViewController {
        switch identifier {
        case .general:
            return GeneralViewController()
        case .shortcuts:
            return ShortcutsViewController(client: client, dispatcher: dispatcher)
        default:
            // Defensive: an unknown identifier means we forgot to wire a tab.
            // Render a placeholder so the window stays usable instead of
            // hosting nothing.
            Self.log.error("No view controller wired for toolbar tab \(identifier.rawValue, privacy: .public)")
            let controller = NSViewController()
            let root = NSView()
            let label = NSTextField(labelWithString: "Not yet implemented.")
            label.textColor = .secondaryLabelColor
            label.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(label)
            NSLayoutConstraint.activate([
                label.centerXAnchor.constraint(equalTo: root.centerXAnchor),
                label.centerYAnchor.constraint(equalTo: root.centerYAnchor),
            ])
            controller.view = root
            return controller
        }
    }

    // MARK: - Toolbar

    private func configureToolbar(on window: NSWindow) {
        let toolbar = NSToolbar(identifier: "PreferencesToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconAndLabel
        toolbar.allowsUserCustomization = false
        toolbar.autosavesConfiguration = false
        if #available(macOS 11.0, *) {
            window.toolbarStyle = .preference
        }
        window.toolbar = toolbar
    }

    // MARK: NSToolbarDelegate

    nonisolated func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        MainActor.assumeIsolated { tabs.map(\.identifier) }
    }

    nonisolated func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        MainActor.assumeIsolated { tabs.map(\.identifier) }
    }

    nonisolated func toolbarSelectableItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        MainActor.assumeIsolated { tabs.map(\.identifier) }
    }

    nonisolated func toolbar(_ toolbar: NSToolbar,
                             itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
                             willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        MainActor.assumeIsolated {
            guard let tab = tabs.first(where: { $0.identifier == itemIdentifier }) else { return nil }
            let item = NSToolbarItem(itemIdentifier: tab.identifier)
            item.label = tab.label
            item.paletteLabel = tab.label
            item.image = NSImage(systemSymbolName: tab.symbol, accessibilityDescription: tab.label)
            item.target = self
            item.action = #selector(toolbarItemSelected(_:))
            return item
        }
    }

    @objc private func toolbarItemSelected(_ sender: NSToolbarItem) {
        showTab(identifier: sender.itemIdentifier)
    }

    private struct Tab {
        let identifier: NSToolbarItem.Identifier
        let label: String
        let symbol: String
    }
}

extension NSToolbarItem.Identifier {
    static let general = NSToolbarItem.Identifier("preferences.general")
    static let shortcuts = NSToolbarItem.Identifier("preferences.shortcuts")
}
