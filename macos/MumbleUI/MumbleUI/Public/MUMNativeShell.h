#ifdef __cplusplus
extern "C" {
#endif

/// Entry point for the native AppKit shell. Installs the main menu,
/// instantiates the Swift AppDelegate, shows the main window, and
/// runs NSApplication. Must be called on the main thread. Returns
/// an exit code.
///
/// Intentionally pure C: included from plain C++ translation units
/// (e.g. src/mumble/main.cpp) that must not pull in Foundation/AppKit.
int MUMNativeShellRun(void);

#ifdef __cplusplus
}
#endif
