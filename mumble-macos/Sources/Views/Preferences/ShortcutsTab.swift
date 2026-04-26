import AppKit
import SwiftUI

/// Shortcuts preferences tab. Lists the user's `ShortcutBinding`s and lets
/// them rebind, add, or remove rows. Click-to-capture in the Shortcut
/// column accepts modifier-only chords, keys, or mouse buttons.
struct ShortcutsTab: View {
    let dispatcher: ShortcutDispatcher

    @State private var store = ShortcutsStore.shared
    @Environment(MumbleClient.self) private var client

    @State private var selectedID: UUID?
    @State private var captureSession: CaptureSession?
    @State private var whisperEditingID: UUID?

    var body: some View {
        VStack(spacing: 0) {
            headerNote
                .padding(.horizontal, 12)
                .padding(.top, 12)
                .padding(.bottom, 8)
            columnHeader
                .padding(.horizontal, 12)
            Divider()
            list
            Divider()
            toolbar
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
        }
        .frame(
            minWidth: 600,
            idealWidth: 700,
            maxWidth: .infinity,
            minHeight: 400,
            idealHeight: 500,
            maxHeight: .infinity
        )
        .sheet(item: Binding(
            get: { whisperEditingID.map(WhisperEditing.init(id:)) },
            set: { whisperEditingID = $0?.id }
        )) { editing in
            if let binding = store.bindings.first(where: { $0.id == editing.id }) {
                WhisperTargetSheet(
                    initial: binding.whisperTarget ?? WhisperTarget(),
                    channels: client.channels,
                    rootChannelID: client.rootChannelID,
                    onSave: { newTarget in
                        var updated = binding
                        updated.whisperTarget = newTarget
                        store.update(updated)
                        whisperEditingID = nil
                    },
                    onCancel: { whisperEditingID = nil }
                )
            }
        }
    }

    // MARK: - Header note

    private var headerNote: some View {
        Text("Shortcuts work system-wide and are not suppressed — bound keys still type into focused fields and bound mouse buttons still click through. macOS will ask for Input Monitoring permission the first time you bind a key or modifier.")
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - Columns

    private var columnHeader: some View {
        HStack(spacing: 0) {
            Text("Function").columnHeader(width: Self.functionWidth)
            Text("Data").columnHeader(width: Self.dataWidth)
            Text("Shortcut").columnHeader(width: nil)
            Text("Suppress").columnHeader(width: Self.suppressWidth, alignment: .trailing)
        }
        .padding(.vertical, 4)
    }

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(store.bindings) { binding in
                    row(for: binding)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(rowBackground(binding.id))
                        .contentShape(Rectangle())
                        .onTapGesture { selectedID = binding.id }
                }
            }
        }
        .frame(maxHeight: .infinity)
    }

    private func rowBackground(_ id: UUID) -> some View {
        Group {
            if id == selectedID {
                Color.accentColor.opacity(0.18)
            } else {
                Color.clear
            }
        }
    }

    @ViewBuilder
    private func row(for binding: ShortcutBinding) -> some View {
        HStack(spacing: 0) {
            Text(binding.action.displayName)
                .columnCell(width: Self.functionWidth)
            dataCell(for: binding)
                .columnCell(width: Self.dataWidth)
            shortcutCell(for: binding)
                .columnCell(width: nil)
            Toggle("", isOn: .constant(false))
                .labelsHidden()
                .disabled(true)
                .help("Suppression isn't implemented in this MVP — bound input always passes through to the focused app.")
                .columnCell(width: Self.suppressWidth, alignment: .trailing)
        }
    }

    // MARK: - Data cell

    @ViewBuilder
    private func dataCell(for binding: ShortcutBinding) -> some View {
        if binding.action == .whisperShout {
            Button {
                whisperEditingID = binding.id
            } label: {
                Text(binding.whisperTarget?.summary(channelName: { id in
                    client.channels[id]?.name
                }) ?? "Configure…")
                .underline(binding.whisperTarget == nil)
                .foregroundStyle(binding.whisperTarget == nil ? .blue : .primary)
            }
            .buttonStyle(.plain)
        } else {
            Text("")
        }
    }

    // MARK: - Shortcut cell

    @ViewBuilder
    private func shortcutCell(for binding: ShortcutBinding) -> some View {
        let isCapturing = (captureSession?.bindingID == binding.id)
        Button {
            beginCapture(rowID: binding.id)
        } label: {
            HStack {
                Text(captureLabel(for: binding, isCapturing: isCapturing))
                    .foregroundStyle(isCapturing ? .secondary : .primary)
                    .italic(isCapturing)
                Spacer()
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(isCapturing ? Color.accentColor.opacity(0.15) : Color.gray.opacity(0.08))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .stroke(isCapturing ? Color.accentColor : Color.clear, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    private func captureLabel(for binding: ShortcutBinding, isCapturing: Bool) -> String {
        if isCapturing {
            let live = captureSession?.liveModifiers.displayString ?? ""
            return live.isEmpty ? "Press a key, modifier chord, or mouse button…" : "\(live) …"
        }
        return binding.trigger?.displayString ?? "Click to set"
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack(spacing: 8) {
            Menu {
                ForEach(ShortcutAction.allCases, id: \.self) { action in
                    Button(action.displayName) {
                        addBinding(action: action)
                    }
                }
            } label: {
                Image(systemName: "plus")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()

            Button {
                removeSelected()
            } label: {
                Image(systemName: "minus")
            }
            .buttonStyle(.borderless)
            .disabled(selectedID == nil)

            Spacer()

            Button("Restore Defaults") {
                cancelCapture()
                store.restoreDefaults()
                selectedID = nil
            }
            .buttonStyle(.borderless)
        }
    }

    // MARK: - Mutations

    private func addBinding(action: ShortcutAction) {
        let binding = ShortcutBinding(
            action: action,
            trigger: nil,
            whisperTarget: action.requiresWhisperTarget ? WhisperTarget() : nil
        )
        store.add(binding)
        selectedID = binding.id
    }

    private func removeSelected() {
        guard let id = selectedID else { return }
        if captureSession?.bindingID == id { cancelCapture() }
        store.remove(id: id)
        selectedID = nil
    }

    // MARK: - Capture flow

    private func beginCapture(rowID: UUID) {
        cancelCapture()
        dispatcher.pause()
        let session = CaptureSession(bindingID: rowID)
        captureSession = session
        session.monitor = NSEvent.addLocalMonitorForEvents(
            matching: [.flagsChanged, .keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { event in
            handleCaptureEvent(event)
            // Suppress during capture so the press doesn't also reach a
            // text field, fire menu shortcuts, or click through. This is
            // distinct from the "no suppression" rule for live shortcuts.
            return nil
        }
    }

    private func handleCaptureEvent(_ event: NSEvent) {
        guard let session = captureSession else { return }
        switch event.type {
        case .flagsChanged:
            let mods = ShortcutModifiers.from(event.modifierFlags)
            session.liveModifiers = mods
            if mods.isEmpty, !session.maxModifiers.isEmpty {
                // All modifiers released — commit a modifier-only chord
                // using the peak set the user held during this capture.
                commitCapture(.modifiersOnly(modifiers: session.maxModifiers))
            } else {
                session.maxModifiers.formUnion(mods)
                // Force re-render to update the live preview.
                captureSession = session
            }
        case .keyDown:
            // Esc cancels.
            if event.keyCode == 0x35 {
                cancelCapture()
                return
            }
            let mods = ShortcutModifiers.from(event.modifierFlags)
            let name = ShortcutTrigger.keyDisplayName(
                forKeyCode: event.keyCode,
                characters: event.charactersIgnoringModifiers
            )
            commitCapture(.key(modifiers: mods, keyCode: event.keyCode, displayName: name))
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            let mods = ShortcutModifiers.from(event.modifierFlags)
            commitCapture(.mouseButton(modifiers: mods, buttonNumber: event.buttonNumber))
        default:
            break
        }
    }

    private func commitCapture(_ trigger: ShortcutTrigger) {
        guard let session = captureSession,
              var binding = store.bindings.first(where: { $0.id == session.bindingID }) else {
            cancelCapture()
            return
        }
        binding.trigger = trigger
        store.update(binding)
        cancelCapture()
    }

    private func cancelCapture() {
        if let session = captureSession {
            if let monitor = session.monitor {
                NSEvent.removeMonitor(monitor)
            }
            captureSession = nil
        }
        dispatcher.resume()
    }

    // MARK: - Layout constants

    private static let functionWidth: CGFloat = 150
    private static let dataWidth: CGFloat = 110
    private static let suppressWidth: CGFloat = 80
}

// MARK: - Capture session

/// One in-flight binding-capture. Mutable reference type so the SwiftUI
/// body can observe live updates of `liveModifiers` while we accumulate
/// `maxModifiers` for the "release-to-commit" flow.
@MainActor
private final class CaptureSession {
    let bindingID: UUID
    var monitor: Any?
    /// Currently held modifiers — drives the live preview text.
    var liveModifiers: ShortcutModifiers = []
    /// Largest modifier set seen during this capture. Committed when the
    /// user releases all modifiers (transitions liveModifiers → empty).
    var maxModifiers: ShortcutModifiers = []

    init(bindingID: UUID) {
        self.bindingID = bindingID
    }
}

// MARK: - Whisper sheet identity adapter

/// `Binding<Identifiable?>` for `.sheet(item:)` — `UUID` is `Identifiable`
/// only via this thin wrapper.
private struct WhisperEditing: Identifiable {
    let id: UUID
}

// MARK: - Column layout helpers

private extension View {
    func columnHeader(width: CGFloat?, alignment: Alignment = .leading) -> some View {
        font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .modifier(ColumnSize(width: width, alignment: alignment))
    }

    func columnCell(width: CGFloat?, alignment: Alignment = .leading) -> some View {
        modifier(ColumnSize(width: width, alignment: alignment))
    }
}

private struct ColumnSize: ViewModifier {
    let width: CGFloat?
    let alignment: Alignment

    func body(content: Content) -> some View {
        if let width {
            content.frame(width: width, alignment: alignment)
        } else {
            content.frame(maxWidth: .infinity, alignment: alignment)
        }
    }
}
