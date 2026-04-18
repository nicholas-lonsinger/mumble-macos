# mumble-macos

## Project identity
Fork of mumble-voip/mumble. The goal of this project is to build a
macOS-native application following the standard practices used for
macOS apps today. Code is being migrated toward native options, and
design decisions should favor that direction. Currently a fresh fork
(single seed commit) — the upstream tree is otherwise unchanged.

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
