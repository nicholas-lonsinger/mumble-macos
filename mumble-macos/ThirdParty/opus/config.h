// Minimal config.h for vendored libopus 1.5.2 on Apple platforms.
// Derived from upstream config.h.in — only the knobs that actually affect
// the portable-C build on macOS are set. SIMD paths aren't vendored here
// (no x86/arm/mips dirs) so no CPU feature flags are enabled.

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
