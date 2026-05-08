// Minimal config.h for vendored libopus 1.5.2 on Apple platforms.
// Derived from upstream config.h.in — only the knobs that actually affect
// the portable-C build on macOS are set. ARM NEON SIMD is wired below via
// libopus's runtime-CPU-detection (RTCD) layer for the arm64 slice; x86
// SIMD and MIPS SIMD are intentionally not enabled (see x86 section
// further down for the per-file `-msse4.1`/`-mavx -mfma` issue, and
// CLAUDE.md for the no-MIPS stance).

#ifndef OPUS_VENDORED_CONFIG_H
#define OPUS_VENDORED_CONFIG_H

// Match upstream's release version verbatim; libopus exposes this through
// its version-string API and any "-mumble-macos" suffix would be confusing
// for upstream issue triage if it ever surfaces in logs.
#define PACKAGE_VERSION "1.5.2"

// Build as a library, not a consumer.
#define OPUS_BUILD 1

// Apple libc has all of these.
#define HAVE_STDINT_H 1
#define HAVE_STDLIB_H 1
#define HAVE_STDIO_H 1
#define HAVE_STRING_H 1
#define HAVE_ALLOCA_H 1
#define HAVE_LRINT 1
#define HAVE_LRINTF 1

// Prefer C99 variable-length arrays over alloca to keep stack use bounded
// and portable across tool-chains.
#define VAR_ARRAYS 1

// Hot paths use float approximations; safe because we're float-point on
// desktop anyway.
#define FLOAT_APPROX 1

// === Runtime CPU detection (RTCD) ===
// libopus probes the CPU at startup (armcpu.c on ARM, x86cpu.c on x86)
// and dispatches SIMD-accelerated functions through tables populated by
// the `*_map.c` files. Compared to the previous static dispatch via
// `OPUS_ARM_PRESUME_NEON_INTR`, RTCD adds one function-pointer indirection
// per call but lets a single binary serve both arm64 (always-NEON) and
// x86_64 (where SSE/AVX support varies). The `MAY_HAVE` macros say which
// instruction sets the compiler can emit; without a matching `PRESUME`,
// the runtime probe gets the final say.
#define OPUS_HAVE_RTCD 1

// ARM: NEON intrinsics. arm64 always has NEON; the runtime probe will
// confirm this and pick the NEON-accelerated path on every Apple Silicon.
// Gated on `__aarch64__` (and i386's 32-bit-arm sibling) so the x86_64
// slice doesn't try to compile against ARM headers.
#if defined(__aarch64__) || defined(__arm__)
#define OPUS_ARM_MAY_HAVE_NEON_INTR 1
#endif

// x86: no SSE/AVX SIMD enabled. Each upstream `*_sse*.c` / `*_avx*.c` file
// requires its own per-file compile flag (`-msse4.1`, `-mavx -mfma`, etc.)
// because clang refuses to inline e.g. `_mm256_loadu_ps` into a function
// not compiled with `avx`. Xcode's synchronized-group source layout
// doesn't expose per-file compiler flags cleanly, and we don't need x86
// SIMD for correctness — the x86_64 slice falls through to libopus's
// reference C path, which is correct everywhere. RTCD remains active on
// arm64 and inactive on x86_64. If/when we actually ship x86_64 and
// performance becomes a concern, the migration path is to switch the x86
// SIMD files to explicit PBXBuildFile refs with `COMPILER_FLAGS` set
// per-file, and add the corresponding `OPUS_X86_MAY_HAVE_*` here.

// Hardening / assertions off in release paths — opt in later if we want
// extra validation during development.
// #define ENABLE_HARDENING 1
// #define ENABLE_ASSERTIONS 1

// No custom modes (non-standard frame sizes); Mumble uses 20 ms frames.
// #define CUSTOM_MODES 1

// Disable the 1.5 neural features. They require DNN weight tables in the
// dnn/ directory, which we haven't vendored.
// #define ENABLE_DEEP_PLC 1
// #define ENABLE_DRED 1
// #define ENABLE_OSCE 1

#endif // OPUS_VENDORED_CONFIG_H
