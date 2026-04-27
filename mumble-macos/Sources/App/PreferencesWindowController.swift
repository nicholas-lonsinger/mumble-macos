import AppKit
import OSLog
import SwiftUI

/// Owns the Preferences window. Native macOS pattern: an `NSWindow` with an
/// `NSToolbar` in the title bar (Safari/Messages prefs aesthetic), each
/// toolbar item representing a tab. For this MVP only the "Shortcuts" tab
/// exists; future tabs (Audio Input, Network, …) get appended to
/// `tabs` and the toolbar delegate auto-picks them up.
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
        // NSHostingView reports the SwiftUI view's intrinsic size, which
        // (for a single-row table) shrinks the window below `contentRect`.
        // Pin to the intended frame explicitly — but only if the user
        // doesn't already have a saved frame, otherwise we'd clobber
        // their resized/repositioned window every relaunch.
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
        let view = contentView(for: identifier)
        let hosting = NSHostingView(rootView: view)
        // Without this, NSHostingView reports the SwiftUI view's intrinsic
        // size as the content view bounds, so the window snaps tight to
        // whatever the view minimally needs and the bottom toolbar gets
        // clipped. autoresizing keeps the host filling the window frame.
        hosting.autoresizingMask = [.width, .height]
        window.contentView = hosting
        window.toolbar?.selectedItemIdentifier = identifier
    }

    @ViewBuilder
    private func contentView(for identifier: NSToolbarItem.Identifier) -> some View {
        switch identifier {
        case .shortcuts:
            ShortcutsTab(dispatcher: dispatcher).environment(client)
        default:
            // Defensive: an unknown identifier means we forgot to wire a tab.
            // Render a placeholder so the window stays usable instead of
            // hosting nothing.
            VStack {
                Text("Not yet implemented.")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
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
    static let shortcuts = NSToolbarItem.Identifier("preferences.shortcuts")
}
