# mumble-macos

Native macOS Mumble VoIP client in Swift/AppKit/SwiftUI. Apple frameworks + vendored C only (no Qt, no package managers, no dynamic deps).

## Build model

- Xcode project uses `PBXFileSystemSynchronizedRootGroup` for `mumble-macos/`. Dropping a file under that directory adds it to the build automatically — no pbxproj edit needed.
- Swift ↔ C interop goes through `mumble-macos/mumble-macos-Bridging-Header.h` (set via `SWIFT_OBJC_BRIDGING_HEADER`).
- `ARCHS = arm64` only. Do not re-enable x86_64 / universal. libopus's `kiss_fft.h` and `float_cast.h` `#include <xmmintrin.h>` under `__SSE__`; clang loads the `_Builtin_intrinsics.intel` module at parse time even when the SSE code path isn't taken, which fails on non-x86 hosts.

## Vendored libopus (1.5.2, BSD)

Located at `mumble-macos/ThirdParty/opus/` with a handwritten `config.h`. Build flags:

- `GCC_PREPROCESSOR_DEFINITIONS` includes `OPUS_BUILD` and `HAVE_CONFIG_H`.
- `HEADER_SEARCH_PATHS` covers `ThirdParty/opus/{include,celt,silk,silk/float,src}`.
- Do **not** vendor `src/opus_custom_demo.c` — it pulls in `opus_custom_decode` which isn't built, causing a link error.
- Variadic `opus_encoder_ctl` / `opus_decoder_ctl` are unavailable from Swift. Reach them via the C shim at `ThirdParty/opus-bridge/OpusBridge.{c,h}`, which wraps each CTL we use as a typed function.

### Why not AudioToolbox

Apple's `kAudioFormatOpus` expects Ogg-framed Opus. Mumble sends raw Opus frames inside `MumbleUDP.Audio.opus_data`. The AudioToolbox path fails with OSStatus 1650549857 ("bdwa") on real packets. libopus is vendored specifically to decode/encode the raw frames — don't "simplify" back to AudioToolbox.

## Mumble protocol notes (v1.5)

- TCP control channel carries typed protobuf messages (`Mumble.proto`, types 0–26).
- Audio is tunneled over TCP as message type 1 (`UDPTunnel`). The payload is `[0x00 UDP-msg-type byte] + [serialized MumbleUDP.Audio]`. The leading 0x00 is the UDP-side message-type byte (audio); the rest is the protobuf.
- Key `MumbleUDP.Audio` fields used: `sender_session(3)`, `frame_number(4)`, `opus_data(5)`, `is_terminator(16)`. Outgoing frames set `target=0` (normal talking), no context.
- Self-mute / self-deaf is sent as an outgoing `UserState` with those fields set; do not mutate the local user model and wait for a round-trip.

## Performance invariant: gate sidebar on ServerSync

Large servers stream 700+ `ChannelState` + `UserState` messages between TLS handshake and `ServerSync`. Rendering the channel tree during that burst re-diffs the whole SwiftUI tree per message and pushes perceived handshake from ~1s to ~55s.

Rule: the tree in `MainView.swift` renders only when `client.state == .connected` (i.e., after `ServerSync`). Before then, show a placeholder. Benchmark server: `mumble.sh1t.space:64738` (~616 channels, ~120 users) — use it when touching the connect path to catch regressions.

`MumbleClient` logs `handshake=<ms>ms` on ServerSync; target is ~1s on that server.

## UI invariants worth preserving

- Channel row expansion uses `userOverride: Bool?` where `nil` falls through to live `subtreeHasOccupants` computed occupancy. Don't seed a plain `@State Bool` at first appearance — that snapshots occupancy before `UserState` messages arrive and leaves populated channels visually collapsed.
- PTT is Globe(Fn) + Control via `NSEvent.addLocalMonitorForEvents(.flagsChanged)`. Do **not** use ⌥Space or other key-based combos — macOS plays the system "funk" beep on keyup for unhandled key events, which bleeds into recordings.
- Connect form persists host/port/username via `@AppStorage`. Password stays `@State` (intentionally not persisted).

## Identity / keychain

- **Only touch the data-protection keychain. Never the login keychain — not even to clean up after our own mistakes.** Every `SecItem*` call in `IdentityStore` passes `kSecUseDataProtectionKeychain: true`. Without that flag the call hits the default (login) keychain, which in a sandboxed app can still see and delete items the user's dev signing cert lives in. This has already cost one dev signing cert; don't bet on "the sandbox will sort it out." If residue shows up in the login keychain (e.g. from old code or external tools), the user handles it with Keychain Access — we do not issue cleanup `SecItemDelete`s at that scope.
- **`SecPKCS12Import` also needs `kSecUseDataProtectionKeychain: true` in its options.** Without it, macOS's implementation silently drops the parsed cert + key into the default (login) keychain as a side effect *in addition* to returning them, so every connect-time import leaks another "Mumble User" cert into login.keychain-db. With the flag, behaviour matches iOS: parse-in-memory, no persistence side effect.
- The entitlement `keychain-access-groups = $(AppIdentifierPrefix)com.nicholas-lonsinger.mumble-macos` is required for the data-protection keychain on macOS. First build after touching entitlements or signing: `xcodebuild … -allowProvisioningUpdates -allowProvisioningDeviceRegistration build` so Xcode can re-issue the profile and auto-register the device.
- **Store the identity as a PKCS#12 envelope, not as split cert + key items.** The "natural" approach — `SecItemAdd(kSecValueRef: secIdentity)` or two `SecItemAdd` calls (one for cert, one for key) — parks bytes in the keychain but leaves the cert↔key pairing broken. `SecIdentityCreateWithCertificate(nil, cert, &identity)` returns a non-nil identity that can answer cert-side questions (CN, fingerprint, validity) but whose `SecIdentityCopyPrivateKey` gives NULL. When BoringSSL later calls `SecIdentityCopyPrivateKey` from the TLS challenge block, `CFRetain(NULL)` crashes the connections queue. Also `SecItemCopyMatching(kSecClassIdentity, kSecUseDataProtectionKeychain: true)` always returns `errSecItemNotFound` on macOS, so identity lookup by that class isn't an option either.
- Instead, `IdentityStore` stores a `kSecClassGenericPassword` item whose value is a JSON envelope of `{pkcs12, password}`. `currentIdentity()` re-runs `SecPKCS12Import` on the blob each time it's needed. That path consistently yields a `SecIdentity` whose `SecIdentityCopyPrivateKey` returns the real key, which is what TLS requires. One import per connection attempt is cheap.
- `kSecAttrKeyType` comes back as `NSNumber` on macOS (and `CFString` on iOS). Accept both when verifying the P12 is RSA.

## Concurrency

- `MumbleClient` is `@MainActor` + `@Observable`. All mutations of its state go through main. Network reads hop to main before touching the model.
- `VoiceController` owns `AVAudioEngine`; audio callbacks run on AU threads. Hand Opus frames back via the `onOpusFrame` closure — don't mutate `MumbleClient` from inside the tap.

## Testing reality

No automated test suite. Two things that need live verification when touched:
1. Voice audibility end-to-end — requires a second person on the server; we've only confirmed send-side cleanliness via logs.
2. Handshake time on the 616-channel server after any change to `MumbleClient` message handling or `MainView` rendering.
