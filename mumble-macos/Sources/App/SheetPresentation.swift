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
        beginSheet(sheetWindow)
        return sheetWindow
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
