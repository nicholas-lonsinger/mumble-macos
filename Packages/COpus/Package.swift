// swift-tools-version: 6.0
//
// Local SwiftPM package wrapping libopus 1.5.2 (BSD).
//
// `Sources/COpus/` mirrors the upstream xiph/opus 1.5.2 release tree 1:1
// (extracted from https://github.com/xiph/opus/archive/refs/tags/v1.5.2.tar.gz).
// `config.h` is the one file we replace — handwritten, in lieu of upstream's
// autoconf-generated header.
//
// Why a local package: keeps third-party C in its own module/build-flag
// boundary so its warnings don't pollute the app's issue list, and so
// upstream-libopus quirks stay scoped here. The Swift ↔ C shim ("OpusBridge")
// deliberately lives in the app target so the our-code/their-code line stays
// visible.
//
// Updates: drop a new release tarball over `Sources/COpus/` (preserve our
// config.h), then revisit this exclude list.
import PackageDescription

let package = Package(
    name: "COpus",
    products: [
        .library(name: "COpus", targets: ["COpus"]),
    ],
    targets: [
        .target(
            name: "COpus",
            path: "Sources/COpus",
            exclude: [
                // === x86 SIMD ===
                // kiss_fft.h / float_cast.h #include <xmmintrin.h> under
                // __SSE__; clang loads the Intel intrinsics module at parse
                // time even when the SSE path isn't taken — fails on arm64.
                "celt/x86",
                "silk/x86",
                "silk/float/x86",
                "dnn/x86",

                // === ARM NEON SIMD ===
                // We compile the NEON intrinsic .c files (six in total) and
                // statically pick the NEON path via `OPUS_ARM_PRESUME_NEON_INTR`
                // in `config.h` — every arm64 chip has NEON, so we skip the
                // run-time CPU-detection layer (RTCD) entirely.
                //
                // The static dispatch is set up by `celt/arm/pitch_arm.h:47-54`
                // (and parallel headers in silk/arm): the `_PRESUME_NEON_INTR`
                // branch rewrites e.g. `celt_inner_prod(...)` directly to
                // `celt_inner_prod_neon(...)` with no function-pointer table.
                // That's why dropping `armcpu.c` and `*_map.c` is safe — the
                // dispatch tables they populate are no longer referenced.
                //
                // ARM DotProd (`OPUS_ARM_*_DOTPROD`) is intentionally NOT
                // enabled: in libopus 1.5.2 the `_dotprod` symbols are
                // referenced by macros in `celt/arm/armcpu.h:50,74` but no
                // `_dotprod` implementations exist outside of `dnn/arm/`,
                // which we don't compile. Enabling PRESUME_DOTPROD here
                // would expand to undefined symbols → link errors. Revisit
                // if a future libopus drops actual DotProd-accelerated
                // SILK/CELT implementations.
                //
                // From `celt/arm/` and `silk/arm/` we keep:
                //   celt_neon_intr.c, pitch_neon_intr.c,
                //   biquad_alt_neon_intr.c, LPC_inv_pred_gain_neon_intr.c,
                //   NSQ_del_dec_neon_intr.c, NSQ_neon.c
                // and exclude the per-file artefacts that would either fail
                // to compile under SwiftPM or pull in machinery we don't use:
                "celt/arm/arm_celt_map.c",         // RTCD dispatch table (gated by OPUS_HAVE_RTCD)
                "celt/arm/armcpu.c",                // RTCD CPU detect (ditto)
                "celt/arm/celt_fft_ne10.c",         // requires the external NE10 lib (not vendored)
                "celt/arm/celt_mdct_ne10.c",        // ditto
                "celt/arm/celt_pitch_xcorr_arm.s",  // GNU asm; Apple `as` can't consume it directly
                "celt/arm/armopts.s.in",            // autoconf-expanded asm template
                "celt/arm/arm2gnu.pl",              // perl script that translates GNU asm
                "celt/arm/meson.build",
                "silk/arm/arm_silk_map.c",          // RTCD dispatch table

                // dnn/arm/ is covered by the `dnn` exclude below.

                // === MIPS SIMD ===
                // We don't target MIPS.
                "celt/mips",
                "silk/mips",

                // === Fixed-point SILK ===
                // Alternative to silk/float/, picked by FIXED_POINT define.
                // Apple Silicon has FP for free; we use float.
                "silk/fixed",

                // === Demo programs (multiple main() symbols would break linking) ===
                "celt/opus_custom_demo.c",
                "celt/dump_modes",
                "src/opus_demo.c",
                "src/opus_compare.c",
                "src/repacketizer_demo.c",

                // === Test programs ===
                "celt/tests",
                "silk/tests",
                "tests",

                // === DNN / DRED neural-net packet loss concealment ===
                // 1.5.x feature: requires ENABLE_DRED + ships weight files;
                // Mumble doesn't negotiate it on the wire.
                "dnn",

                // === Documentation, training, build infrastructure ===
                // None of this compiles, but SwiftPM warns about any
                // "unhandled" non-source file under the target path.
                "doc",
                "training",
                "cmake",
                "scripts",
                "m4",
                "meson",
                ".github",
                "AUTHORS",
                "ChangeLog",
                "NEWS",
                "README",
                "README.draft",
                "LICENSE_PLEASE_READ.txt",
                "configure.ac",
                "Makefile.am",
                "Makefile.unix",
                "Makefile.mips",
                "CMakeLists.txt",
                "meson.build",
                "meson_options.txt",
                "autogen.sh",
                "autogen.bat",
                "opus.m4",
                "opus.pc.in",
                "opus-uninstalled.pc.in",
                "releases.sha2",
                "celt_headers.mk",
                "celt_sources.mk",
                "lpcnet_headers.mk",
                "lpcnet_sources.mk",
                "opus_headers.mk",
                "opus_sources.mk",
                "silk_headers.mk",
                "silk_sources.mk",
                // per-subdirectory meson.build files
                "celt/meson.build",
                "silk/meson.build",
                "src/meson.build",
                "include/meson.build",
            ],
            publicHeadersPath: "include",
            cSettings: [
                .headerSearchPath("."),
                .headerSearchPath("celt"),
                .headerSearchPath("silk"),
                .headerSearchPath("silk/float"),
                .headerSearchPath("src"),
                .define("OPUS_BUILD", to: "1"),
                .define("HAVE_CONFIG_H", to: "1"),
                .unsafeFlags(["-w"]),
            ]
        ),
    ]
)
