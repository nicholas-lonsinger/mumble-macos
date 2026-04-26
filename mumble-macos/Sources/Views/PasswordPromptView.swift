import SwiftUI

/// Tiny "type the password to connect" sheet shown when the user picks a
/// saved server whose password isn't remembered (or whose keychain entry
/// is missing). The password is consumed for the connect attempt and is
/// not written back to the keychain — that's a separate "remember
/// password" toggle on the bookmark.
struct PasswordPromptView: View {
    let serverLabel: String
    let serverDetails: String
    @Binding var password: String
    let onConnect: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Password for \(serverLabel)")
                .font(.headline)
            Text(serverDetails)
                .font(.caption)
                .foregroundStyle(.secondary)
            SecureField("Password", text: $password)
                .textFieldStyle(.roundedBorder)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Connect", action: onConnect)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 360)
    }
}

#Preview {
    PasswordPromptView(
        serverLabel: "Test Server",
        serverDetails: "test.example.com:64738 — alice",
        password: .constant(""),
        onConnect: {},
        onCancel: {}
    )
}
