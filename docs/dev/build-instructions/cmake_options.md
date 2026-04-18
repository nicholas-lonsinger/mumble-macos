# CMake options

Using CMake the build can be customized in a number of ways. The most prominent examples for this is the usage of different
options (flags). These can be set by using `-D<optionName>=<value>` where `<optionName>` is the name of the respective option
as listed below and `<value>` is either `ON` or `OFF` depending on whether the option shall be activated or inactivated.

An example would be `cmake -Dtests=ON ..`.


## Available options

### benchmarks

Build benchmarks
(Default: OFF)

### bundle-qt-translations

Bundle Qt's translations as well
(Default: ${static})

### bundled-cli11

Use the bundled CLI11 version instead of looking for one on the system
(Default: ON)

### bundled-json

Build the included version of nlohmann_json instead of looking for one on the system
(Default: ON)

### bundled-rnnoise

Build the included version of RNNoise instead of looking for one on the system.
(Default: ${rnnoise})

### bundled-spdlog

Use the bundled spdlog version instead of looking for one on the system
(Default: ON)

### bundled-speex

Build the included version of Speex instead of looking for one on the system.
(Default: ON)

### bundled-utfcpp

Use the bundled utf8cpp version instead of looking for one on the system
(Default: ON)

### client

Build the client (Mumble)
(Default: ON)

### coreaudio

Build support for CoreAudio.
(Default: ON)

### crash-report

Include support for reporting crashes to the Mumble developers.
(Default: ON)

### debug-dependency-search

Prints extended information during the search for the needed dependencies
(Default: OFF)

### display-install-paths

Print out base install paths during project configuration
(Default: OFF)

### lto

Enables link-time optimizations for release builds
(Default: ${LTO_DEFAULT})

### manual-plugin

Include the built-in \"manual\
(Default: positional audio plugin." ON)

### online-tests

Whether or not tests that need a working internet connection should be included
(Default: OFF)

### optimize

Build a heavily optimized version, specific to the machine it's being compiled on.
(Default: OFF)

### packaging

Build package.
(Default: OFF)

### plugin-callback-debug

Build Mumble with debug output for plugin callbacks inside of Mumble.
(Default: OFF)

### plugin-debug

Build Mumble with debug output for plugin developers.
(Default: OFF)

### plugins

Build plugins.
(Default: ON)

### qssldiffiehellmanparameters

Build support for custom Diffie-Hellman parameters.
(Default: ON)

### qtspeech

Use Qt's text-to-speech system (part of the Qt Speech module) instead of Mumble's own OS-specific text-to-speech implementations.
(Default: OFF)

### retracted-plugins

Build redacted (outdated) plugins as well
(Default: OFF)

### rnnoise

Use RNNoise for machine learning noise reduction.
(Default: ON)

### static

Build static binaries.
(Default: OFF)

### symbols

Build binaries in a way that allows easier debugging.
(Default: OFF)

### test-lto

Whether to use LTO when building test cases
(Default: ${lto})

### tests

Build tests.
(Default: ${packaging})

### tracy

Enable the tracy profiler.
(Default: OFF)

### translations

Include languages other than English.
(Default: ON)

### update

Check for updates by default.
(Default: ON)

### use-timestamps

Allow using compile-time timestamps
(Default: ON)

### warnings-as-errors

All warnings are treated as errors.
(Default: ON)

### zeroconf

Build support for zeroconf (mDNS/DNS-SD).
(Default: ON)


