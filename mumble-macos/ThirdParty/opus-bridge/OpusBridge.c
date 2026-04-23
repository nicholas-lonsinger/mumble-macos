#include "OpusBridge.h"

int mumble_opus_encoder_set_int(OpusEncoder *enc, int request, int value) {
    return opus_encoder_ctl(enc, request, value);
}

int mumble_opus_decoder_set_int(OpusDecoder *dec, int request, int value) {
    return opus_decoder_ctl(dec, request, value);
}
