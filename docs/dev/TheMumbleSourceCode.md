# Introduction to the Mumble source code

This file is an orientation for anyone working in this macOS-only fork.
Most of the material is inherited from upstream Mumble and still applies
to the client; what differs is the tree layout, since the server,
overlay, Windows installer, Linux helpers, and their associated
directories have been stripped out.

If something isn't covered here, the upstream Mumble Matrix channel
(https://matrix.to/#/#mumble-dev:matrix.org) is still a good resource
for general client-side questions. Fork-specific issues belong in this
repository's tracker.


## Source tree layout

```
<repo root>
├── 3rdparty            — bundled libraries (arc4random, CLI11,
│                         flag-icons, nlohmann_json, qqbonjour,
│                         rnnoise, smallft, spdlog, speexdsp, tracy,
│                         utfcpp, …)
├── 3rdPartyLicenses    — licenses for libraries shipped in the bundle
├── cmake
│   └── FindModules
├── docs
│   ├── dev             — development docs (you are reading one)
│   └── media
├── icons
├── plugins             — per-game positional-audio plugins
├── samples             — audio cue .ogg files
├── screenshots
├── scripts             — build-time code generators and dev tooling
├── src
│   ├── crypto          — OCB2 / CryptState
│   ├── mumble          — client sources
│   └── tests
└── themes
    └── Default         — Lite + Dark variants
```

`3rdparty/` libraries are checked in directly (not submodules in this
fork). `cmake/` holds the find-modules and build helpers. `src/` is
where the bulk of the work lives — shared code at the top level,
client-specific code in `src/mumble/`. `themes/Default` contains the
Lite and Dark variants.


## Important files

Now that we have established our general bearings, it is time to get a little bit more specific about the individual files in the source tree
(`src/*`).

To begin with a general note: In Mumble the name of the header file in which a class and its function is declared, is not necessarily a guarantee that
the implementation of that function is also in the source file with the corresponding name. So it can happen that the file `MyClass.h` defines a class
`MyClass` that declares a function `X`. That function may not end up being implemented in `MyClass.cpp`. A class that makes extensive use of this
pattern is `MainWindow`. If the header doesn't mention where the given set of functions is implemented, your best chance is to search the source
files in the same directory for a matching implementation (in almost all cases, the implementation lives in a source file within the same directory
as the header in question).


### Client

First off: all the `*.ts` are used for localizations (translations) are are handled by external services. Thus, you should not modify them by hand
as your changes would likely be overwritten by said service.

- `main.cpp`: This contains the main entry point into the client (the "main" function) in which all command-line arguments are processed and a bunch
  of objects are instantiated and prepared for further use. The main purpose (as far as most developers are concerned) is the instantiation of the
  `MumbleApplication` which mostly is just a `QApplication`. That means that from this point on the program is mainly event-driven.
- `MainWindow.cpp`: This can be pretty much be considered the heart of the Mumble client. It is responsible for managing the main Mumble UI and also
  for coordinating all sorts of events that are received and sent. If you are tracing down some functionality, chances are high that the `MainWindow`
  class is involved in it in one way or another.
- `UserModel.cpp`: This class is responsible for managing the in-memory representation of the channel and user tree. All user and channel objects on
  the client are created here.
- `Messages.cpp`: This class implements all Protobuf message handling that is performed on the client-side. Technically all these functions belong to
  the `MainWindow` class, but their implementation is separated into this dedicated source file.
- `ServerHandler.cpp`: This class is responsible for managing a connection to a given server. It handles the immediate network connection to the
  server and makes sure that all messages are sent and received in the appropriate thread. If you need to send any request to the server, the server
  handler is the one to perform the request for you.
- `AudioInput.cpp`, `AudioOutput.cpp`: These classes implement the general audio input and output handling. The actual interaction with the system
  audio backend (CoreAudio) is handled by a dedicated sub-class implemented in `CoreAudio.mm`. That file contains both input and output.
- `PluginManager.cpp`: Everything that is related to loading and running plugins within Mumble, is handled by the `PluginManager` class.
- `API_v*`: These are the various implementations of the plugin API functions. These are the functions plugins may call in order to interact with
  Mumble.
- `Global.cpp`: The `Global` class is a singleton accessed via `Global::get()` and it holds a variety of shared data used throughout the client.

For many UI elements, we use `.ui` files which are XML-files that describe the UI elements in a way that is understood by
[Qt Designer](https://doc.qt.io/qt-5/qtdesigner-manual.html). With this tool, you can edit the elements in a WYSIWYG fashion (at least for the most
part). In any case, it is a great tool, when you are trying to figure out what will happen once you click a certain button in a given UI element. Just
open the element in Qt Designer, check the button's name and search for that in the corresponding `.cpp` implementation. Note that we are using
implicit signal-connecting which is based on a special naming scheme of slots in a given UI class (e.g. `on_xy_actived` where `xy` is the name of the
corresponding UI element).

When creating or changing existing UI elements, always consider the [accessibility checklist](/docs/dev/Accessibility.md).
