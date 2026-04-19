import SwiftUI

public struct HelloView: View {
	@State private var bridge = HelloBridge()

	public init() {}

	public var body: some View {
		VStack(spacing: 12) {
			Image(systemName: "mic.fill")
				.font(.system(size: 48))
				.foregroundStyle(.tint)
			Text(bridge.greeting)
				.font(.title2)
				.multilineTextAlignment(.center)
			Text("hello.subtitle", bundle: Bundle(for: MUMBridgeHost.self))
				.font(.footnote)
				.foregroundStyle(Color("BrandTint", bundle: Bundle(for: MUMBridgeHost.self)))
			Button("Trigger bridge update") {
				bridge.triggerChange()
			}
			.buttonStyle(.borderedProminent)
		}
		.padding(32)
		.frame(minWidth: 320, minHeight: 240)
	}
}

#Preview {
	HelloView()
}
