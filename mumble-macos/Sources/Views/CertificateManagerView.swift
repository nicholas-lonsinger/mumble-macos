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

    func createNew() throws {
        try IdentityStore.shared.createNewIdentity()
        refresh()
    }

    func exportPKCS12(password: String) throws -> Data {
        try IdentityStore.shared.exportPKCS12(password: password)
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
    @State private var showingCreateConfirmation = false
    @State private var isCreating = false
    @State private var showingExportPasswordSheet = false
    @State private var exportPassword = ""
    @State private var exportPasswordConfirm = ""

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
                    .disabled(isCreating)
                Button("Export…") { beginExport() }
                    .disabled(model.summary == nil || isCreating)
                Button("Create New…") { showingCreateConfirmation = true }
                    .disabled(isCreating)
                Spacer()
                Button(role: .destructive) { deleteIdentity() } label: {
                    Text("Delete")
                }
                .disabled(model.summary == nil || isCreating)
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
        .sheet(isPresented: $showingExportPasswordSheet, onDismiss: {
            exportPassword = ""
            exportPasswordConfirm = ""
        }) {
            exportPasswordSheet
        }
        .alert("Certificate error",
               isPresented: Binding(get: { errorMessage != nil },
                                    set: { if !$0 { errorMessage = nil } })) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(errorMessage ?? "")
        }
        .confirmationDialog(createConfirmationTitle,
                            isPresented: $showingCreateConfirmation,
                            titleVisibility: .visible) {
            Button(model.summary == nil ? "Create" : "Replace", role: model.summary == nil ? nil : .destructive) {
                performCreate()
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text(createConfirmationMessage)
        }
    }

    private var createConfirmationTitle: String {
        model.summary == nil
            ? "Create a new Mumble identity?"
            : "Replace your current Mumble identity?"
    }

    private var createConfirmationMessage: String {
        if let summary = model.summary {
            return "This will replace “\(summary.commonName)” (fingerprint \(summary.sha1Fingerprint.prefix(16))…). The existing identity is not backed up — export it first if you want to keep it."
        }
        return "A fresh self-signed certificate will be generated (CN “Mumble User”, RSA 2048, 20-year validity) and stored in this Mac’s data-protection keychain."
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

    private var exportPasswordSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Export Password")
                .font(.headline)
            Text("The exported PKCS#12 file will be encrypted with this password. Remember it — you’ll need it to import the file on another machine.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            SecureField("Password", text: $exportPassword)
                .textFieldStyle(.roundedBorder)
            SecureField("Confirm password", text: $exportPasswordConfirm)
                .textFieldStyle(.roundedBorder)
            if !exportPasswordConfirm.isEmpty, exportPassword != exportPasswordConfirm {
                Text("Passwords don’t match.")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) {
                    showingExportPasswordSheet = false
                }
                .keyboardShortcut(.cancelAction)
                Button("Save…") {
                    performExport()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(exportPassword != exportPasswordConfirm)
            }
        }
        .padding(20)
        .frame(width: 400)
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

    private func beginExport() {
        exportPassword = ""
        exportPasswordConfirm = ""
        showingExportPasswordSheet = true
    }

    private func performExport() {
        let password = exportPassword
        showingExportPasswordSheet = false

        let p12: Data
        do {
            p12 = try model.exportPKCS12(password: password)
        } catch {
            errorMessage = error.localizedDescription
            return
        }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "p12") ?? .data]
        panel.nameFieldStringValue = defaultExportFileName()
        panel.message = "Save the exported Mumble identity."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try p12.write(to: url)
        } catch {
            errorMessage = "Couldn’t write the file: \(error.localizedDescription)"
        }
    }

    private func defaultExportFileName() -> String {
        let base: String
        if let cn = model.summary?.commonName, !cn.isEmpty, cn != "(no common name)" {
            base = cn.replacingOccurrences(of: "/", with: "-")
        } else {
            base = "Mumble Identity"
        }
        return "\(base).p12"
    }

    private func performCreate() {
        isCreating = true
        Task { @MainActor in
            defer { isCreating = false }
            do {
                try model.createNew()
            } catch {
                errorMessage = error.localizedDescription
            }
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
