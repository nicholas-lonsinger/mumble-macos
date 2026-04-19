import AppKit
import SwiftUI

@MainActor
private final class HelloAppDelegate: NSObject, NSApplicationDelegate {
	func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
		return true
	}
}

@MainActor private var helloDelegate: HelloAppDelegate?
@MainActor private var helloWindow: NSWindow?

@_cdecl("MUMHelloAppRun")
public func MUMHelloAppRun() -> Int32 {
	MainActor.assumeIsolated {
		let app = NSApplication.shared
		app.setActivationPolicy(.regular)

		let delegate = HelloAppDelegate()
		app.delegate = delegate
		helloDelegate = delegate

		let window = NSWindow(
			contentRect: NSRect(x: 0, y: 0, width: 480, height: 320),
			styleMask: [.titled, .closable, .miniaturizable, .resizable],
			backing: .buffered,
			defer: false
		)
		window.title = "MumbleUI Hello"
		window.contentViewController = NSHostingController(rootView: HelloView())
		window.center()
		window.makeKeyAndOrderFront(nil)
		helloWindow = window

		app.activate()
		app.run()
	}
	return 0
}
