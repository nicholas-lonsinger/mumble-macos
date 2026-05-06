import SwiftUI

/// Audio preferences tab. Currently exposes one knob: the release-linger
/// duration that defends against the AVAudioEngine input tap delivering
/// audio in chunks (~100 ms in a VM / over Bluetooth) — without the
/// linger, the buffer carrying the user's last syllable is still in
/// flight at key release and gets dropped by `VoiceController`. See
/// `AudioSettingsStore.releaseLingerMS` for the full reasoning.
struct AudioTab: View {
    @State private var store = AudioSettingsStore.shared

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
                lingerRow
            } header: {
                Text("Push-to-Talk")
                    .font(.headline)
            } footer: {
                Text("Keeps the microphone open briefly after you release a Push-to-Talk, Whisper, or Shout key. Without this, the last word can be cut off because the audio buffer carrying it is still in flight when the key comes up. 200 ms covers most setups; raise it if your tail still feels clipped (common in VMs or over Bluetooth).")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
    }

    private var lingerRow: some View {
        HStack(alignment: .center, spacing: 12) {
            Text("Release linger")
                .frame(width: 140, alignment: .trailing)
            Slider(
                value: Binding(
                    get: { Double(store.releaseLingerMS) },
                    set: { store.releaseLingerMS = Int($0.rounded()) }
                ),
                in: Double(AudioSettingsStore.releaseLingerMSRange.lowerBound)
                    ... Double(AudioSettingsStore.releaseLingerMSRange.upperBound),
                step: 10
            )
            .frame(maxWidth: 320)
            Text("\(store.releaseLingerMS) ms")
                .monospacedDigit()
                .frame(width: 64, alignment: .leading)
        }
    }
}
