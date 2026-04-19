import AppKit

@MainActor private var appDelegate: AppDelegate?

@_cdecl("MUMNativeShellRun")
public func MUMNativeShellRun() -> Int32 {
	MainActor.assumeIsolated {
		let app = NSApplication.shared
		app.setActivationPolicy(.regular)

		MainMenuBuilder.install(on: app)

		let delegate = AppDelegate()
		app.delegate = delegate
		appDelegate = delegate

		app.activate()
		app.run()
	}
	return 0
}
