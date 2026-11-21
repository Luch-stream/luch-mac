// libopus headers plus tiny wrappers: opus_encoder_ctl is variadic, which Swift cannot call.
#include <opus.h>

static inline int luch_opus_set_bitrate(OpusEncoder *enc, int bitrate) {
    return opus_encoder_ctl(enc, OPUS_SET_BITRATE_REQUEST, bitrate);
}

static inline int luch_opus_set_vbr(OpusEncoder *enc, int vbr) {
    return opus_encoder_ctl(enc, OPUS_SET_VBR_REQUEST, vbr);
}

static inline int luch_opus_lookahead(OpusEncoder *enc, int *samples) {
    return opus_encoder_ctl(enc, OPUS_GET_LOOKAHEAD_REQUEST, samples);
}
