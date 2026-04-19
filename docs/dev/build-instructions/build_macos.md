# Building on macOS

These instructions are for performing a regular build of Mumble that will only run on systems that have the necessary libraries installed on them. For
building a static version, checkout [this file](build_static.md).

## Dependencies

On macOS, you can use [homebrew](https://brew.sh/) to install the needed packages. If you don't have it installed already, you can follow the
instruction on their official website to install homebrew itself.

Once homebrew is installed, you can run the following command to install all required packages:
```bash
brew update && brew install \
  cmake \
  pkg-config \
  qt6 \
  boost \
  opus \
  libsndfile \
  protobuf \
  openssl \
  poco
```

You also need a current Xcode install (not just the command-line tools) so
that `xcodebuild` can build `MumbleUI.framework`, the native UI framework
that CMake embeds into `Mumble.app`. See [the migration
doc](../migration-qt-to-native.md) for context.


## Running cmake

It is recommended to perform a so-called "out-of-source-build". In order to do so, navigate to the root of the Mumble directory and the issue the
following commands:
1. `mkdir build` (Creates a build directory)
2. `cd build` (Switches into the build directory)
3. `cmake ..` (Actually runs cmake)

This will cause cmake to create the necessary build files for you. If you want to customize your build, you can pass special flags to cmake in step 3.
For all available build options, have a look [here](cmake_options.md).


## Building

Once cmake has been run, you can issue `cmake --build .` from the build directory in order to actually start compiling the sources. If you want to
parallelize the build, use `cmake --build . -j <jobs>` where `<jobs>` is the amount of parallel jobs to be run concurrently.


## MumbleUI (native UI framework)

On macOS, CMake drives a secondary `xcodebuild` invocation that produces
`MumbleUI.framework` from the Xcode project at
`macos/MumbleUI/MumbleUI.xcodeproj`. The framework is embedded into
`Mumble.app/Contents/Frameworks/` and linked into the main `Mumble`
binary. No extra step is required — it all happens inside `cmake --build .`.

CMake writes `macos/MumbleUI/MumbleUI/Local.xcconfig` at configure time
with the Qt prefix it discovered via `qmake -query QT_INSTALL_PREFIX`.
The file is gitignored; regenerate it by re-running `cmake ..`.

### `-DMUMBLE_NATIVE_SHELL=ON`

Enables the native AppKit shell. When ON, `Mumble --native` skips
`QApplication` entirely and launches an `NSApplication`-backed shell
(main menu, window controller, SwiftUI content via `NSHostingView`).
Off by default; the Qt shell continues to ship without the flag. The
two shells share one binary — the flag and CLI switch together route
to the native entry point.

### SwiftUI Previews

Xcode Previews only work when you open `macos/MumbleUI/MumbleUI.xcodeproj`
directly in Xcode. Building through CMake is the right path for the
shipping app; Xcode is the right path for iterating on SwiftUI views.


## FAQ

See the general [build-FAQ](faq.md).


### CMake chooses Apple's SSL library

It can happen that cmake will find Apple's own SSL library that comes pre-installed on your system. This is usually incompatible with Mumble though
and you'll usually get errors about undefined OpenSSL symbols during link-time:
```
ld: symbol(s) not found
```

You can circumvent this problem by pointing cmake to the OpenSSL version you installed following the instructions from above. For how to do this,
please refer to [our build-FAQ](faq.md#cmake-selects-wrong-openssl-version).
