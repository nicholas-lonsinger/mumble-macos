import SwiftUI

public struct HelloView: View {
	private let bridge = MUMBridgeHost()

	public init() {}

	public var body: some View {
		VStack(spacing: 12) {
			Image(systemName: "mic.fill")
				.font(.system(size: 48))
				.foregroundStyle(.tint)
			Text(bridge.greeting)
				.font(.title2)
			Text("MumbleUI • Phase 0")
				.font(.footnote)
				.foregroundStyle(.secondary)
		}
		.padding(32)
		.frame(minWidth: 280, minHeight: 200)
	}
}

#Preview {
	HelloView()
}
