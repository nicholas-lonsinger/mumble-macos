# Qt → AppKit + SwiftUI migration

Tracking the removal of Qt's UI layer in favor of a native macOS UI.

## Architectural invariants

Canonical list in `CLAUDE.md` § "UI migration invariants". Summary:
AppKit frames everything, SwiftUI only for window content, AppKit → SwiftUI
bridge only (never the reverse, never double), Qt ↔ Swift goes through
Obj-C++ only, macOS 15 floor, Swift framework built by its own Xcode
project (`macos/MumbleUI/MumbleUI.xcodeproj`) and linked by CMake.

## Tracking

- Epic: [#3 — MIGRATION: Replace Qt UI with AppKit + SwiftUI](https://github.com/nicholas-lonsinger/mumble-macos/issues/3)
- Phase issues are sub-issues of the epic, labelled `migration` + `phase-N`.

## Layout

- `macos/MumbleUI/MumbleUI.xcodeproj` — Swift + Obj-C++ bridge framework
  (created in Phase 0, does not yet exist).
- `src/mumble/` — existing Qt UI, progressively retired.
- `src/` (non-`mumble`) — Qt core code; out of scope for this migration.
