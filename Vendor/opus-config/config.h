// Minimal config.h for vendored libopus 1.5.2 on Apple platforms.
// Derived from upstream config.h.in — only the knobs that actually affect
// the portable-C build on macOS are set. MIPS SIMD isn't vendored; ARM
// NEON and x86 SSE/AVX SIMD are wired below via libopus's runtime-CPU-
// detection (RTCD) layer so a single config can drive both arm64 and
// (future) x86_64 slices.

#ifndef OPUS_VENDORED_CONFIG_H
#define OPUS_VENDORED_CONFIG_H

#define PACKAGE_VERSION "1.5.2-mumble-macos"

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
#define OPUS_ARM_MAY_HAVE_NEON_INTR 1

// x86 SSE/AVX feature toggles are gated on `__x86_64__` further down so
// they only activate in the x86_64 slice — defining them unconditionally
// makes pitch.h #include x86/pitch_sse.h on arm64 too, which declares
// externs (XCORR_KERNEL_IMPL etc.) whose definitions live in
// celt/x86/x86_celt_map.c — files we exclude on arm64.

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
