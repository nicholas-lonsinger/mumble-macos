import Observation

@MainActor
@Observable
public final class HelloBridge {
	public private(set) var greeting: String

	private let bridge: MUMBridgeHost

	public init() {
		let bridge = MUMBridgeHost()
		self.bridge = bridge
		self.greeting = bridge.greeting

		bridge.onGreetingChanged = { [weak self] in
			MainActor.assumeIsolated {
				guard let self else { return }
				self.greeting = self.bridge.greeting
			}
		}
	}

	public func triggerChange() {
		bridge.simulateBackgroundGreetingUpdate()
	}
}
