import AppKit
import Observation
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

/// Certificate Manager window content: shows the stored Mumble identity
/// (or the no-certificate / keychain-error states) and drives the
/// import / export / create / delete flows against `IdentityStore`.
@MainActor
final class CertificateManagerViewController: NSViewController {
    private let model = CertificateManagerModel()
    private var tracker: ObservationTracker?

    private var pendingImportData: Data?
    private var isCreating = false {
        didSet { updateButtonEnablement() }
    }

    // Content area — exactly one of these is visible per render.
    private let summaryBox = NSBox()
    private let summaryGrid: NSGridView
    private let noCertLabel = makeIconLabel(symbol: "person.badge.key",
                                            text: "No certificate configured",
                                            color: .secondaryLabelColor)
    private let errorStack = NSStackView()
    private let errorDetailLabel = NSTextField(wrappingLabelWithString: "")

    // Summary grid value fields, updated in place per render.
    private let commonNameValue = NSTextField(labelWithString: "")
    private let validFromValue = NSTextField(labelWithString: "")
    private let validUntilValue = NSTextField(labelWithString: "")
    private let sha256Value = CertificateManagerViewController.makeFingerprintField()
    private let sha1Value = CertificateManagerViewController.makeFingerprintField()

    private var importButton: NSButton!
    private var exportButton: NSButton!
    private var createButton: NSButton!
    private var deleteButton: NSButton!

    init() {
        let grid = NSGridView(views: [])
        self.summaryGrid = grid
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("CertificateManagerViewController does not support NSCoding")
    }

    // MARK: - View construction

    override func loadView() {
        let root = NSView()

        let title = NSTextField(labelWithString: "Mumble Identity")
        title.font = NSFont.systemFont(ofSize: NSFont.preferredFont(forTextStyle: .title2).pointSize,
                                       weight: .semibold)

        let explainer = NSTextField(wrappingLabelWithString:
            "Your client certificate is how Mumble servers recognise you across sessions. It never leaves this Mac and is stored in the app’s per-bundle keychain."
        )
        explainer.font = NSFont.preferredFont(forTextStyle: .callout)
        explainer.textColor = .secondaryLabelColor
        explainer.isSelectable = false

        let divider = NSBox()
        divider.boxType = .separator

        // Summary grid: right-aligned label column, left-aligned values.
        let rows: [(String, NSTextField)] = [
            ("Common name", commonNameValue),
            ("Valid from", validFromValue),
            ("Valid until", validUntilValue),
            ("Fingerprint (SHA-256)", sha256Value),
            ("Mumble hash (SHA-1)", sha1Value),
        ]
        for (label, value) in rows {
            let labelField = NSTextField(labelWithString: label)
            labelField.textColor = .secondaryLabelColor
            labelField.alignment = .right
            summaryGrid.addRow(with: [labelField, value])
        }
        summaryGrid.rowSpacing = 6
        summaryGrid.columnSpacing = 12
        summaryGrid.column(at: 0).xPlacement = .trailing
        summaryGrid.setContentHuggingPriority(.defaultLow, for: .horizontal)
        summaryBox.titlePosition = .noTitle
        summaryBox.contentView = summaryGrid
        summaryBox.contentViewMargins = NSSize(width: 10, height: 10)

        // Error state.
        let errorHeadline = Self.makeIconLabel(symbol: "exclamationmark.triangle.fill",
                                               text: "Couldn’t read keychain",
                                               color: .systemRed)
        errorDetailLabel.font = NSFont.preferredFont(forTextStyle: .callout)
        errorDetailLabel.textColor = .secondaryLabelColor
        errorDetailLabel.isSelectable = false
        errorStack.orientation = .vertical
        errorStack.alignment = .leading
        errorStack.spacing = 4
        errorStack.addArrangedSubview(errorHeadline)
        errorStack.addArrangedSubview(errorDetailLabel)

        // Buttons.
        importButton = NSButton(title: "Import…", target: self, action: #selector(pickAndImport(_:)))
        exportButton = NSButton(title: "Export…", target: self, action: #selector(beginExport(_:)))
        createButton = NSButton(title: "Create New…", target: self, action: #selector(confirmCreate(_:)))
        deleteButton = NSButton(title: "Delete", target: self, action: #selector(deleteIdentity(_:)))
        deleteButton.hasDestructiveAction = true
        deleteButton.bezelColor = .systemRed
        let buttonSpacer = NSView()
        buttonSpacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let buttonRow = NSStackView(views: [importButton, exportButton, createButton,
                                            buttonSpacer, deleteButton])
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 8

        let contentSpacer = NSView()
        contentSpacer.setContentHuggingPriority(.init(1), for: .vertical)

        let stack = NSStackView(views: [title, explainer, divider,
                                        summaryBox, errorStack, noCertLabel,
                                        contentSpacer, buttonRow])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 24),
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -24),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -24),
            explainer.widthAnchor.constraint(equalTo: stack.widthAnchor),
            divider.widthAnchor.constraint(equalTo: stack.widthAnchor),
            summaryBox.widthAnchor.constraint(equalTo: stack.widthAnchor),
            buttonRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            root.widthAnchor.constraint(greaterThanOrEqualToConstant: 560),
            root.heightAnchor.constraint(greaterThanOrEqualToConstant: 360),
        ])

        view = root
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        tracker = ObservationTracker { [weak self] in
            guard let self else { return }
            self.render(summary: self.model.summary, error: self.model.error)
        }
        tracker?.start()
    }

    private func render(summary: StoredIdentitySummary?, error: String?) {
        summaryBox.isHidden = (summary == nil)
        errorStack.isHidden = !(summary == nil && error != nil)
        noCertLabel.isHidden = !(summary == nil && error == nil)

        if let summary {
            commonNameValue.stringValue = summary.commonName
            validFromValue.stringValue = Self.dateFormatter.string(from: summary.notBefore)
            validUntilValue.stringValue = Self.dateFormatter.string(from: summary.notAfter)
            sha256Value.stringValue = summary.sha256Fingerprint
            sha1Value.stringValue = summary.sha1Fingerprint
        }
        if let error {
            errorDetailLabel.stringValue = error
        }
        updateButtonEnablement()
    }

    private func updateButtonEnablement() {
        importButton.isEnabled = !isCreating
        createButton.isEnabled = !isCreating
        exportButton.isEnabled = (model.summary != nil && !isCreating)
        deleteButton.isEnabled = (model.summary != nil && !isCreating)
    }

    // MARK: - Import

    @objc private func pickAndImport(_ sender: Any?) {
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
            let sheet = ImportPasswordViewController { [weak self] password in
                self?.performImport(password: password)
            } onCancel: { [weak self] in
                self?.pendingImportData = nil
            }
            view.window?.beginSheet(controller: sheet, title: "PKCS#12 Password")
        } catch {
            presentError(message: "Couldn’t read the file: \(error.localizedDescription)")
        }
    }

    private func performImport(password: String) {
        guard let data = pendingImportData else { return }
        pendingImportData = nil
        do {
            try model.importPKCS12(data: data, password: password)
        } catch {
            presentError(message: error.localizedDescription)
        }
    }

    // MARK: - Export

    @objc private func beginExport(_ sender: Any?) {
        let sheet = ExportPasswordViewController { [weak self] password in
            self?.performExport(password: password)
        }
        view.window?.beginSheet(controller: sheet, title: "Export Password")
    }

    private func performExport(password: String) {
        let p12: Data
        do {
            p12 = try model.exportPKCS12(password: password)
        } catch {
            presentError(message: error.localizedDescription)
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
            presentError(message: "Couldn’t write the file: \(error.localizedDescription)")
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

    // MARK: - Create

    @objc private func confirmCreate(_ sender: Any?) {
        let alert = NSAlert()
        let replacing = (model.summary != nil)
        alert.messageText = replacing
            ? "Replace your current Mumble identity?"
            : "Create a new Mumble identity?"
        if let summary = model.summary {
            alert.informativeText = "This will replace “\(summary.commonName)” (fingerprint \(summary.sha1Fingerprint.prefix(16))…). The existing identity is not backed up — export it first if you want to keep it."
        } else {
            alert.informativeText = "A fresh self-signed certificate will be generated (CN “Mumble User”, RSA 2048, 20-year validity) and stored in this Mac’s data-protection keychain."
        }
        let confirm = alert.addButton(withTitle: replacing ? "Replace" : "Create")
        confirm.hasDestructiveAction = replacing
        alert.addButton(withTitle: "Cancel")
        guard let window = view.window else { return }
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            self?.performCreate()
        }
    }

    private func performCreate() {
        isCreating = true
        defer { isCreating = false }
        do {
            try model.createNew()
        } catch {
            presentError(message: error.localizedDescription)
        }
    }

    // MARK: - Delete

    @objc private func deleteIdentity(_ sender: Any?) {
        do {
            try model.delete()
        } catch {
            presentError(message: error.localizedDescription)
        }
    }

    // MARK: - Errors

    private func presentError(message: String) {
        let alert = NSAlert()
        alert.messageText = "Certificate error"
        alert.informativeText = message
        alert.alertStyle = .warning
        if let window = view.window {
            alert.beginSheetModal(for: window) { _ in }
        } else {
            alert.runModal()
        }
    }

    // MARK: - Pieces

    private static func makeIconLabel(symbol: String, text: String, color: NSColor) -> NSStackView {
        let icon = NSImageView(image: NSImage(systemSymbolName: symbol,
                                              accessibilityDescription: nil)!)
        icon.contentTintColor = color
        let label = NSTextField(labelWithString: text)
        label.textColor = (color == .secondaryLabelColor) ? .secondaryLabelColor : .labelColor
        let stack = NSStackView(views: [icon, label])
        stack.orientation = .horizontal
        stack.spacing = 6
        return stack
    }

    private static func makeFingerprintField() -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: "")
        field.font = NSFont.monospacedSystemFont(
            ofSize: NSFont.preferredFont(forTextStyle: .caption1).pointSize, weight: .regular)
        field.isSelectable = true
        field.maximumNumberOfLines = 2
        field.lineBreakMode = .byCharWrapping
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()
}

// MARK: - Password sheets

/// "Enter the password that protects this PKCS#12 file." Import is the
/// default button; an empty password is valid (unprotected archives).
@MainActor
private final class ImportPasswordViewController: NSViewController {
    private let onImport: (String) -> Void
    private let onCancel: () -> Void
    private let passwordField = NSSecureTextField(string: "")

    init(onImport: @escaping (String) -> Void, onCancel: @escaping () -> Void) {
        self.onImport = onImport
        self.onCancel = onCancel
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("ImportPasswordViewController does not support NSCoding")
    }

    override func loadView() {
        let root = NSView()

        let title = NSTextField(labelWithString: "PKCS#12 Password")
        title.font = NSFont.preferredFont(forTextStyle: .headline)

        let explainer = NSTextField(wrappingLabelWithString:
            "Enter the password that protects this PKCS#12 file. Leave blank if it has no password."
        )
        explainer.font = NSFont.preferredFont(forTextStyle: .callout)
        explainer.textColor = .secondaryLabelColor
        explainer.isSelectable = false

        let cancelButton = NSButton(title: "Cancel", target: self, action: #selector(cancel(_:)))
        cancelButton.keyEquivalent = "\u{1b}"
        let importButton = NSButton(title: "Import", target: self, action: #selector(doImport(_:)))
        importButton.keyEquivalent = "\r"
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let buttonRow = NSStackView(views: [spacer, cancelButton, importButton])
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 8

        passwordField.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView(views: [title, explainer, passwordField, buttonRow])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 20),
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -20),
            explainer.widthAnchor.constraint(equalTo: stack.widthAnchor),
            passwordField.widthAnchor.constraint(equalTo: stack.widthAnchor),
            buttonRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            root.widthAnchor.constraint(equalToConstant: 400),
        ])

        view = root
    }

    @objc private func doImport(_ sender: Any?) {
        let password = passwordField.stringValue
        endHostingSheet()
        onImport(password)
    }

    @objc private func cancel(_ sender: Any?) {
        endHostingSheet()
        onCancel()
    }
}

/// "The exported PKCS#12 file will be encrypted with this password."
/// Save… stays disabled while the confirmation doesn't match.
@MainActor
private final class ExportPasswordViewController: NSViewController, NSTextFieldDelegate {
    private let onSave: (String) -> Void
    private let passwordField = NSSecureTextField(string: "")
    private let confirmField = NSSecureTextField(string: "")
    private let mismatchLabel = NSTextField(labelWithString: "Passwords don’t match.")
    private var saveButton: NSButton!

    init(onSave: @escaping (String) -> Void) {
        self.onSave = onSave
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("ExportPasswordViewController does not support NSCoding")
    }

    override func loadView() {
        let root = NSView()

        let title = NSTextField(labelWithString: "Export Password")
        title.font = NSFont.preferredFont(forTextStyle: .headline)

        let explainer = NSTextField(wrappingLabelWithString:
            "The exported PKCS#12 file will be encrypted with this password. Remember it — you’ll need it to import the file on another machine."
        )
        explainer.font = NSFont.preferredFont(forTextStyle: .callout)
        explainer.textColor = .secondaryLabelColor
        explainer.isSelectable = false

        passwordField.placeholderString = "Password"
        confirmField.placeholderString = "Confirm password"
        passwordField.delegate = self
        confirmField.delegate = self

        mismatchLabel.font = NSFont.preferredFont(forTextStyle: .caption1)
        mismatchLabel.textColor = .systemRed
        mismatchLabel.isHidden = true

        let cancelButton = NSButton(title: "Cancel", target: self, action: #selector(cancel(_:)))
        cancelButton.keyEquivalent = "\u{1b}"
        saveButton = NSButton(title: "Save…", target: self, action: #selector(save(_:)))
        saveButton.keyEquivalent = "\r"
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let buttonRow = NSStackView(views: [spacer, cancelButton, saveButton])
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 8

        passwordField.translatesAutoresizingMaskIntoConstraints = false
        confirmField.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView(views: [title, explainer, passwordField, confirmField,
                                        mismatchLabel, buttonRow])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 20),
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -20),
            explainer.widthAnchor.constraint(equalTo: stack.widthAnchor),
            passwordField.widthAnchor.constraint(equalTo: stack.widthAnchor),
            confirmField.widthAnchor.constraint(equalTo: stack.widthAnchor),
            buttonRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            root.widthAnchor.constraint(equalToConstant: 400),
        ])

        view = root
    }

    func controlTextDidChange(_ obj: Notification) {
        let matches = (passwordField.stringValue == confirmField.stringValue)
        saveButton.isEnabled = matches
        mismatchLabel.isHidden = matches || confirmField.stringValue.isEmpty
    }

    @objc private func save(_ sender: Any?) {
        let password = passwordField.stringValue
        endHostingSheet()
        onSave(password)
    }

    @objc private func cancel(_ sender: Any?) {
        endHostingSheet()
    }
}
