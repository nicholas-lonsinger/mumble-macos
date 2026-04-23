import SwiftUI

struct ConnectView: View {
    let onConnect: (ServerConnectionParameters) -> Void
    let onCancel: () -> Void

    // Host/port/username persist across launches. Password stays session-scoped
    // until we add Keychain-backed storage (or client certs, which make it moot).
    @AppStorage("lastServerHost") private var host = ServerConnectionParameters.defaultPublicTestServer.host
    @AppStorage("lastServerPort") private var port = String(ServerConnectionParameters.defaultPublicTestServer.port)
    @AppStorage("lastServerUsername") private var username = ServerConnectionParameters.defaultPublicTestServer.username
    @State private var password = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Connect to Mumble Server")
                .font(.headline)

            Form {
                TextField("Host", text: $host)
                TextField("Port", text: $port)
                TextField("Username", text: $username)
                SecureField("Password", text: $password)
            }
            .formStyle(.grouped)

            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Connect") {
                    onConnect(currentParameters)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canConnect)
            }
        }
        .padding(20)
        .frame(width: 420)
    }

    private var canConnect: Bool {
        !host.trimmingCharacters(in: .whitespaces).isEmpty
            && UInt16(port) != nil
            && !username.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private var currentParameters: ServerConnectionParameters {
        ServerConnectionParameters(
            host: host.trimmingCharacters(in: .whitespaces),
            port: UInt16(port) ?? 64738,
            username: username.trimmingCharacters(in: .whitespaces),
            password: password
        )
    }
}

#Preview {
    ConnectView(onConnect: { _ in }, onCancel: { })
}
