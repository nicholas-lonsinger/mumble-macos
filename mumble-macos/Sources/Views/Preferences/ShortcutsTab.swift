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
    /// Snapshot of the in-flight capture state. A struct (not a class) so
    /// SwiftUI re-renders the live-preview cell whenever `liveModifiers`
    /// or `maxModifiers` change — `@State` keys re-renders on the value's
    /// equality, which a class would defeat by sharing identity.
    @State private var captureState: CaptureState?
    /// `Any` is the NSEvent monitor token. Held in `@State` separately so
    /// `CaptureState` can stay a pure-data Equatable struct.
    @State private var captureMonitor: AnyHolder = AnyHolder()
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
        }
    }

    // MARK: - Data cell

    @ViewBuilder
    private func dataCell(for binding: ShortcutBinding) -> some View {
        if binding.action == .whisperShout {
            let summary = binding.whisperTarget?.summary(channelName: { id in
                client.channels[id]?.name
            }) ?? "Configure…"
            Button {
                whisperEditingID = binding.id
            } label: {
                Text(summary)
                    .underline(binding.whisperTarget == nil)
                    .foregroundStyle(binding.whisperTarget == nil ? .blue : .primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .buttonStyle(.plain)
            // Surface the full target name on hover for channels whose
            // names exceed the column width (Mumble subchannel naming
            // conventions can run long).
            .help(summary)
        } else {
            Text("")
        }
    }

    // MARK: - Shortcut cell

    @ViewBuilder
    private func shortcutCell(for binding: ShortcutBinding) -> some View {
        let isCapturing = (captureState?.bindingID == binding.id)
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
            let live = captureState?.liveModifiers.displayString ?? ""
            return live.isEmpty ? "Press a key, modifier chord, or mouse button…" : "\(live) …"
        }
        return binding.trigger?.displayString ?? "Click to set"
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack(spacing: 4) {
            Menu {
                ForEach(ShortcutAction.allCases, id: \.self) { action in
                    Button(action.displayName) {
                        addBinding(action: action)
                    }
                }
            } label: {
                Image(systemName: "plus")
                    .frame(width: Self.iconButtonSize.width,
                           height: Self.iconButtonSize.height)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Add shortcut")

            Button {
                removeSelected()
            } label: {
                Image(systemName: "minus")
                    .frame(width: Self.iconButtonSize.width,
                           height: Self.iconButtonSize.height)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .disabled(selectedID == nil)
            .help("Remove selected shortcut")

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
        if captureState?.bindingID == id { cancelCapture() }
        store.remove(id: id)
        selectedID = nil
    }

    // MARK: - Capture flow

    private func beginCapture(rowID: UUID) {
        cancelCapture()
        dispatcher.pause()
        captureState = CaptureState(bindingID: rowID)
        captureMonitor.value = NSEvent.addLocalMonitorForEvents(
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
        guard var state = captureState else { return }
        switch event.type {
        case .flagsChanged:
            let mods = ShortcutModifiers.from(event.modifierFlags)
            state.liveModifiers = mods
            if mods.isEmpty, !state.maxModifiers.isEmpty {
                // All modifiers released — commit a modifier-only chord
                // using the peak set the user held during this capture.
                commitCapture(.modifiersOnly(modifiers: state.maxModifiers))
            } else {
                state.maxModifiers.formUnion(mods)
                captureState = state
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
        guard let state = captureState,
              var binding = store.bindings.first(where: { $0.id == state.bindingID }) else {
            cancelCapture()
            return
        }
        binding.trigger = trigger
        store.update(binding)
        cancelCapture()
    }

    private func cancelCapture() {
        if let monitor = captureMonitor.value {
            NSEvent.removeMonitor(monitor)
            captureMonitor.value = nil
        }
        captureState = nil
        dispatcher.resume()
    }

    // MARK: - Layout constants

    private static let functionWidth: CGFloat = 150
    private static let dataWidth: CGFloat = 160
    /// Hit-target for the +/− icon buttons. The default `Button` + `Image`
    /// combination only makes the glyph itself tappable, which leaves a
    /// pixel-precise click target — so we pad the label out to a more
    /// finger/cursor-friendly area via an explicit frame + contentShape.
    private static let iconButtonSize = CGSize(width: 26, height: 22)
}

// MARK: - Capture state

/// In-flight binding-capture state. A pure-data struct so SwiftUI's
/// `@State` re-renders on every internal change (`liveModifiers` updates
/// during a held chord, `maxModifiers` accumulates the peak set).
private struct CaptureState: Equatable {
    let bindingID: UUID
    /// Currently held modifiers — drives the live preview text.
    var liveModifiers: ShortcutModifiers = []
    /// Largest modifier set seen during this capture. Committed when the
    /// user releases all modifiers (transitions liveModifiers → empty).
    var maxModifiers: ShortcutModifiers = []
}

/// Box for the NSEvent monitor token. The token is `Any` (returned by
/// `addLocalMonitorForEvents` as an opaque object) which isn't `Equatable`,
/// so it can't live inside `CaptureState`. A reference-typed holder lets
/// us mutate it without re-rendering the table.
@MainActor
private final class AnyHolder {
    var value: Any?
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
