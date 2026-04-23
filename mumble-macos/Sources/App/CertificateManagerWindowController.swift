import AppKit
import SwiftUI

@MainActor
final class CertificateManagerWindowController: NSWindowController {
    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 580, height: 420),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Certificate Manager"
        window.setFrameAutosaveName("CertificateManagerWindow")
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: CertificateManagerView())
        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("CertificateManagerWindowController does not support NSCoding")
    }
}
