#ifdef __cplusplus
extern "C" {
#endif

/// Phase 0 sub-task 7 entry point. Runs a standalone AppKit
/// application hosting a SwiftUI `HelloView`, bypassing Qt
/// entirely. Must be called on the main thread. Returns an
/// exit code.
///
/// Intentionally pure C: included from plain C++ translation
/// units (e.g. src/mumble/main.cpp) that must not pull in
/// Foundation/AppKit.
int MUMHelloAppRun(void);

#ifdef __cplusplus
}
#endif
