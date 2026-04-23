// Tiny shim around libopus's variadic ctl API so Swift can reach it without
// variadic function interop quirks. Each wrapper pins the value type.
#ifndef OPUS_BRIDGE_H
#define OPUS_BRIDGE_H

#include "opus.h"

int mumble_opus_encoder_set_int(OpusEncoder *enc, int request, int value);
int mumble_opus_decoder_set_int(OpusDecoder *dec, int request, int value);

#endif
