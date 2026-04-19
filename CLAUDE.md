# mumble-macos

## Project identity
Fork of mumble-voip/mumble. The goal of this project is to build a
macOS-native application following the standard practices used for
macOS apps today. Code is being migrated toward native options, and
design decisions should favor that direction. Currently a fresh fork
(single seed commit) — the upstream tree is otherwise unchanged.

## UI migration invariants (Qt → AppKit + SwiftUI)

The Qt UI is being replaced with a native macOS UI. The rules below are
load-bearing for every UI change and must not be relaxed without explicit
discussion.

- **AppKit frames everything.** Windows, window controllers, main menu,
  toolbars, sheets, alerts, dock and status-bar items are AppKit. App
  entry is `NSApplication` + `AppDelegate`, not SwiftUI's `@main App`.
- **SwiftUI only for window content.** A window's content view is an
  `NSHostingView` rooted at a SwiftUI view. Compose freely inside that
  root.
- **Bridge direction is one-way.** AppKit hosts SwiftUI via
  `NSHostingView` / `NSHostingController`. Never the other direction —
  do not use `NSViewRepresentable` to embed AppKit inside SwiftUI.
- **No double bridges.** A SwiftUI root cannot contain an AppKit view
  that hosts another SwiftUI view. If SwiftUI cannot express a screen
  natively, the whole screen stays AppKit.
- **Qt core ↔ Swift bridge is Obj-C++ only.** Qt headers (`<Q…>`) appear
  only inside `.mm` files. They must never be exposed via a public
  umbrella header or anything Swift imports.
- **Minimum macOS is 15.0.**
- **Swift language mode is latest** (Swift 6 at time of writing).
  Strict concurrency is on; bridge methods get `@MainActor` or
  `nonisolated` per their threading guarantees.
- **Swift builds in its own Xcode project**
  (`macos/MumbleUI/MumbleUI.xcodeproj`), produces `MumbleUI.framework`,
  and is linked into `Mumble.app` by CMake. CMake stays the top-level
  driver for the duration of the Qt migration.

Migration tracking lives in `docs/dev/migration-qt-to-native.md` and its
linked epic/phase GitHub issues.

## Build (macOS client)
- Deps via Homebrew — see `docs/dev/build-instructions/build_macos.md`.
- Configure: `cmake ..` from a `build/` directory.
- Build: `cmake --build . -j <N>`. Artifact: `build/Mumble.app`.
- Faster iteration: add `-Dplugins=OFF` (80+ per-game plugin targets).

## Conventions
- Code style: see `CODING_GUIDELINES.md` (`.clang-format` is authoritative).
- Commits: see `COMMIT_GUIDELINES.md`. Format: `TYPE(Scope): Summary`.

## Tracking technical debt
When a change introduces a temporary fix, workaround, warning suppression,
or any other form of deliberate technical debt, open a GitHub issue
describing it before (or as part of) the commit that lands the debt.
Link the issue from the code comment next to the workaround and from the
commit message. The issue must include: what we did, why the real fix was
deferred, what the real fix looks like, and acceptance criteria for
closing it out. Use `gh issue create` — don't just leave a TODO in the
code. Example: issue #1 tracks the `-Wno-deprecated-declarations`
suppression on `TextToSpeech_macx.mm`.

## Testing
Configure with `-Dtests=ON`, then run `ctest` from `build/`. Tests live in
`src/tests/`; DB tests use SQLite by default.

## Hands-off areas
- `3rdparty/` — submodules; don't edit.
- `plugins/` — per-game, upstream-owned; touch only if asked.
- `overlay_winx64/`, `installer/` — Windows-only.
