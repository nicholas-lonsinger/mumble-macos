// Bridges the vendored libopus C API into Swift. Only the public Opus
// headers are exposed; internal helpers stay private to the C sources.
#ifndef MUMBLE_MACOS_BRIDGING_HEADER_H
#define MUMBLE_MACOS_BRIDGING_HEADER_H

#include "opus.h"
#include "opus_defines.h"
#include "opus_multistream.h"
#include "opus_types.h"
#include "OpusBridge.h"

#endif
