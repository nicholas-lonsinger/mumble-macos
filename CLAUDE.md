# mumble-macos

## Project identity
Fork of mumble-voip/mumble. The goal of this project is to build a
macOS-native application following the standard practices used for
macOS apps today. Code is being migrated toward native options, and
design decisions should favor that direction. Currently a fresh fork
(single seed commit) — the upstream tree is otherwise unchanged.

## Build (macOS client)
- Deps via Homebrew — see `docs/dev/build-instructions/build_macos.md`.
- Configure: `cmake -Dserver=OFF ..` from a `build/` directory.
  The default config pulls soci → MySQL and fails without it.
- Build: `cmake --build . -j <N>`. Artifact: `build/Mumble.app`.
- Faster iteration: add `-Dplugins=OFF` (80+ per-game plugin targets).

## Conventions
- Code style: see `CODING_GUIDELINES.md` (`.clang-format` is authoritative).
- Commits: see `COMMIT_GUIDELINES.md`. Format: `TYPE(Scope): Summary`.

## Testing
Configure with `-Dtests=ON`, then run `ctest` from `build/`. Tests live in
`src/tests/`; DB tests use SQLite by default.

## Hands-off areas
- `3rdparty/` — submodules; don't edit.
- `plugins/` — per-game, upstream-owned; touch only if asked.
- `overlay_winx64/`, `installer/` — Windows-only.
