/* Stream constants shared by the driver, its media connection (gpu_media.h) and the
 * test tools, and the capture format: tools/cbva-phone writes what the driver sends
 * the phone as a capture, and `cbva-capture split` turns a capture into elementary
 * streams. A capture is a sequence of records, each a type byte, a little-endian u32
 * payload length and a fixed little-endian payload; FRAME ends in the unit's data. */
#ifndef CABOOSE_VA_PROTO_H
#define CABOOSE_VA_PROTO_H

#define CB_CAP_OPEN 0x02         /* u32 stream, u8 codec, u8 profile, u8 bit_depth, u8 chroma, u16 w, u16 h */
#define CB_CAP_FRAME 0x03        /* u32 stream, u32 seq, u32 surface, u8 flags, u8[3] 0, u64 t_us, u16 w, u16 h, data */
#define CB_CAP_CLOSE 0x05        /* u32 stream, u8 0 */
#define CB_CAP_SURFACE_GONE 0x06 /* u32 surface */

#define CB_CODEC_H264 1
#define CB_CODEC_HEVC 2
#define CB_CODEC_VP9 3
#define CB_CODEC_AV1 4

#define CB_FRAME_KEY 0x01    /* random access point: decoding can start here */
#define CB_FRAME_HIDDEN 0x02 /* not shown when decoded; output only for the app to show later, if it does */
#define CB_FRAME_REPLAY 0x04 /* resent after a replay request; already presented or superseded */

#endif
