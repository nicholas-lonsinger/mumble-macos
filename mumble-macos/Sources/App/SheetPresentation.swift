import AppKit

/// Sheet plumbing shared by every form sheet in the app. One pattern,
/// matching the original Quick Connect sheet: a titled, non-resizable
/// window whose content is a plain view controller, attached with
/// `beginSheet`. Buttons inside the controller end the sheet via
/// `endHostingSheet()`.
extension NSWindow {
    /// Presents `controller` as a titled sheet of this window and returns
    /// the sheet window (callers rarely need it — the controller can end
    /// itself with `endHostingSheet()`).
    @discardableResult
    func beginSheet(controller: NSViewController, title: String) -> NSWindow {
        let sheetWindow = NSWindow(contentViewController: controller)
        sheetWindow.styleMask = [.titled]
        sheetWindow.title = title
        // NSWindow(contentViewController:) sizes to the view's Auto Layout
        // fitting size and ignores preferredContentSize (that's only
        // honored by the NSViewController presentation APIs). Honor it
        // here so sheets can spec a size larger than their fitting size.
        let preferred = controller.preferredContentSize
        if preferred != .zero {
            sheetWindow.setContentSize(preferred)
        }
        beginSheet(sheetWindow)
        return sheetWindow
    }

    /// Replaces `contentViewController` without letting the window snap to
    /// the new content's Auto Layout fitting size (`minSize` only
    /// constrains *user* resizing, so the snap can shrink a window below
    /// it — and the shrunken frame then gets autosaved).
    func setContentViewControllerPreservingFrame(_ controller: NSViewController,
                                                 display: Bool = false) {
        let frame = self.frame
        contentViewController = controller
        setFrame(frame, display: display)
    }
}

extension NSViewController {
    /// Ends the sheet this controller's view is hosted in. No-op when the
    /// view isn't currently presented as a sheet.
    func endHostingSheet() {
        guard let window = view.window, let parent = window.sheetParent else { return }
        parent.endSheet(window)
    }
}

extension NSStackView {
    /// The standard sheet button row: optional leading views, a flexible
    /// spacer, then the trailing buttons (conventionally Cancel + the
    /// default button). Every form sheet uses this shape.
    @MainActor
    static func sheetButtonRow(leading: [NSView] = [], trailing: [NSView]) -> NSStackView {
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let row = NSStackView(views: leading + [spacer] + trailing)
        row.orientation = .horizontal
        row.spacing = 8
        return row
    }
}
