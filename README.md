# mumble-macos

A native macOS [Mumble](https://www.mumble.info) VoIP client built with Swift, AppKit, and SwiftUI. No Qt, no package managers, no dynamic dependencies — just Apple frameworks and a small amount of vendored C.

> **Status: work in progress.** The client connects to Mumble 1.5 servers, browses the channel tree, and can transmit voice. End-to-end voice audibility with another participant has not yet been verified outside the developer's own setup. Expect rough edges; not yet recommended for general use.

## Requirements

- macOS (Apple Silicon / arm64 only — see notes below)
- Xcode 15 or newer
- A Mumble 1.5 server to connect to

## Build

Open `mumble-macos.xcodeproj` in Xcode and build the `mumble-macos` scheme.

The first build after a fresh checkout (or after touching entitlements) should be run from the command line so Xcode can re-issue the provisioning profile:

```sh
xcodebuild -project mumble-macos.xcodeproj \
  -scheme mumble-macos \
  -allowProvisioningUpdates \
  -allowProvisioningDeviceRegistration \
  build
```

Subsequent builds work normally from inside Xcode.

### Why arm64-only

libopus's `kiss_fft.h` and `float_cast.h` `#include <xmmintrin.h>` under `__SSE__`. Clang loads the `_Builtin_intrinsics.intel` module at parse time on any host that advertises SSE, which fails on Apple Silicon when targeting universal builds. Restricting `ARCHS` to `arm64` sidesteps this. Intel Mac support is not currently a goal.

## What's implemented

- TLS connection to Mumble servers, including self-signed certificate trust prompt
- Mumble 1.5 control protocol (TCP) — channel/user state, join, move, mute/deaf
- Voice send/receive over the TCP UDPTunnel using vendored libopus 1.5.2
- Push-to-talk via Globe(Fn) + Control
- Per-user identity stored as a PKCS#12 envelope in the data-protection keychain, with import/export

## What's not implemented

- Direct UDP audio path (we tunnel everything over TCP today)
- Plugins, overlays, positional audio
- Text-message UI (messages are received but not surfaced)
- Settings UI for audio devices, gain, voice activity detection, etc.

See [`CLAUDE.md`](CLAUDE.md) for build invariants and protocol notes worth knowing before contributing.

## License

This project is licensed under the BSD 3-Clause License (see `LICENSE`).

Vendored libopus is also BSD 3-Clause; its license text is preserved at `mumble-macos/ThirdParty/opus/COPYING`.

## Acknowledgements

- The [Mumble](https://www.mumble.info) project for the protocol and the server we test against.
- [Xiph.Org / libopus](https://opus-codec.org) for the audio codec.

## Disclaimer

This is an independent client. It is not affiliated with or endorsed by the Mumble project.
