import AppKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor
@Observable
final class CertificateManagerModel {
    var summary: StoredIdentitySummary?
    var error: String?

    init() {
        refresh()
    }

    func refresh() {
        do {
            summary = try IdentityStore.shared.currentSummary()
            error = nil
        } catch {
            summary = nil
            self.error = error.localizedDescription
        }
    }

    func importPKCS12(data: Data, password: String) throws {
        try IdentityStore.shared.importPKCS12(data, password: password)
        refresh()
    }

    func delete() throws {
        try IdentityStore.shared.delete()
        refresh()
    }
}

struct CertificateManagerView: View {
    @State private var model = CertificateManagerModel()
    @State private var showingPasswordSheet = false
    @State private var pendingImportData: Data?
    @State private var importPassword = ""
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Mumble Identity")
                .font(.title2)
                .fontWeight(.semibold)

            Text("Your client certificate is how Mumble servers recognise you across sessions. It never leaves this Mac and is stored in the app’s per-bundle keychain.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Divider()

            if let summary = model.summary {
                summaryView(summary)
            } else if let lookupError = model.error {
                VStack(alignment: .leading, spacing: 4) {
                    Label("Couldn’t read keychain", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                    Text(lookupError)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            } else {
                Label("No certificate configured", systemImage: "person.badge.key")
                    .foregroundStyle(.secondary)
            }

            Spacer()

            HStack {
                Button("Import…") { pickAndImport() }
                Button("Export…") { }
                    .disabled(true)
                    .help("Coming in a later commit.")
                Button("Create New…") { }
                    .disabled(true)
                    .help("Coming in a later commit.")
                Spacer()
                Button(role: .destructive) { deleteIdentity() } label: {
                    Text("Delete")
                }
                .disabled(model.summary == nil)
            }
        }
        .padding(24)
        .frame(minWidth: 560, minHeight: 360)
        .sheet(isPresented: $showingPasswordSheet, onDismiss: {
            pendingImportData = nil
            importPassword = ""
        }) {
            importPasswordSheet
        }
        .alert("Certificate error",
               isPresented: Binding(get: { errorMessage != nil },
                                    set: { if !$0 { errorMessage = nil } })) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func summaryView(_ summary: StoredIdentitySummary) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 6) {
                LabeledContent("Common name", value: summary.commonName)
                LabeledContent("Valid from", value: Self.dateFormatter.string(from: summary.notBefore))
                LabeledContent("Valid until", value: Self.dateFormatter.string(from: summary.notAfter))
                LabeledContent("Fingerprint (SHA-256)") {
                    Text(summary.sha256Fingerprint)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .lineLimit(2)
                }
                LabeledContent("Mumble hash (SHA-1)") {
                    Text(summary.sha1Fingerprint)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .lineLimit(2)
                }
            }
            .padding(6)
        }
    }

    private var importPasswordSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("PKCS#12 Password")
                .font(.headline)
            Text("Enter the password that protects this PKCS#12 file. Leave blank if it has no password.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            SecureField("Password", text: $importPassword)
                .textFieldStyle(.roundedBorder)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) {
                    showingPasswordSheet = false
                }
                .keyboardShortcut(.cancelAction)
                Button("Import") {
                    performImport()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 400)
    }

    private func pickAndImport() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Import"
        panel.message = "Choose a PKCS#12 (.p12 / .pfx) file to import."
        panel.allowedContentTypes = [
            UTType(filenameExtension: "p12") ?? .data,
            UTType(filenameExtension: "pfx") ?? .data
        ]
        let response = panel.runModal()
        guard response == .OK, let url = panel.url else { return }
        do {
            pendingImportData = try Data(contentsOf: url)
            importPassword = ""
            showingPasswordSheet = true
        } catch {
            errorMessage = "Couldn’t read the file: \(error.localizedDescription)"
        }
    }

    private func performImport() {
        guard let data = pendingImportData else {
            showingPasswordSheet = false
            return
        }
        do {
            try model.importPKCS12(data: data, password: importPassword)
            showingPasswordSheet = false
        } catch {
            errorMessage = error.localizedDescription
            showingPasswordSheet = false
        }
    }

    private func deleteIdentity() {
        do {
            try model.delete()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()
}

#Preview {
    CertificateManagerView()
}
