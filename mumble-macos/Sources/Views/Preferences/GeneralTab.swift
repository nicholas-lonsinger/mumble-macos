import SwiftUI

/// General preferences tab. First in the toolbar order.
///
/// Today this hosts a single knob: re-establish the most recent
/// connection on app launch. The companion `LastConnectedServerStore`
/// captures the params on `ServerSync` and clears them when the user
/// disconnects deliberately, so this only fires if the previous session
/// ended via "quit while still connected" (or a crash).
struct GeneralTab: View {
    @State private var store = GeneralSettingsStore.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            content
                .padding(20)
            Spacer()
        }
        .frame(
            minWidth: 600,
            idealWidth: 700,
            maxWidth: .infinity,
            minHeight: 400,
            idealHeight: 500,
            maxHeight: .infinity
        )
    }

    @ViewBuilder
    private var content: some View {
        Form {
            Section {
                Toggle("Reconnect to last server on launch", isOn: $store.reconnectOnLaunch)
            } header: {
                Text("Startup")
                    .font(.headline)
            } footer: {
                Text("When you quit while still connected, the next launch will reconnect to that server automatically. Disconnecting from the File menu before you quit clears the saved server, so the app won't reconnect to somewhere you intentionally left.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
    }
}
