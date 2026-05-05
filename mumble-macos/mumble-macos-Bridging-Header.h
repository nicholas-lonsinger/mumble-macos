// Bridges our local Swift ↔ C shim for libopus. The shim itself transitively
// pulls in opus.h. Raw libopus types/constants reach Swift via `import COpus`,
// not through this header.
#ifndef MUMBLE_MACOS_BRIDGING_HEADER_H
#define MUMBLE_MACOS_BRIDGING_HEADER_H

#include "OpusBridge.h"

#endif
