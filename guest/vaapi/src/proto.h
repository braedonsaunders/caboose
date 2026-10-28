/* The Caboose video socket: libva driver <-> caboose-display.
 *
 * A Unix stream socket at $CABOOSE_VIDEO_SOCKET (default
 * $XDG_RUNTIME_DIR/caboose-video.sock), opened by the driver at vaInitialize.
 * Every message is a type byte, a little-endian u32 payload length, and a
 * fixed little-endian payload; FRAME and HELLO end in variable data.
 * docs/display.md, "Codec passthrough", is the normative description. */
#ifndef CABOOSE_VA_PROTO_H
#define CABOOSE_VA_PROTO_H

#define CB_PROTO_VERSION 1

/* driver -> compositor */
#define CB_MSG_HELLO 0x01   /* u16 version, u16 0, u32 pid, program name (UTF-8) */
#define CB_MSG_OPEN 0x02    /* u32 stream, u8 codec, u8 profile, u8 bit_depth, u8 chroma, u16 w, u16 h */
#define CB_MSG_FRAME 0x03   /* u32 stream, u32 seq, u32 surface, u8 flags, u8[3] 0, u64 t_us, u16 w, u16 h, data */
#define CB_MSG_SURFACE 0x04 /* u32 surface, u32 0, u64 dmabuf st_dev, u64 dmabuf st_ino */
#define CB_MSG_CLOSE 0x05   /* u32 stream, u8 reason */
#define CB_MSG_SURFACE_GONE 0x06 /* u32 surface */

/* compositor -> driver */
#define CB_MSG_ACCEPT 0x81  /* u32 stream, u8 tag (0-63), u8 mode */
#define CB_MSG_DECODE 0x82  /* u32 stream, u8 reason */
#define CB_MSG_REPLAY 0x83  /* u32 stream */

#define CB_CODEC_H264 1
#define CB_CODEC_HEVC 2
#define CB_CODEC_VP9 3
#define CB_CODEC_AV1 4

#define CB_FRAME_KEY 0x01    /* random access point: decoding can start here */
#define CB_FRAME_HIDDEN 0x02 /* not shown when decoded; output only for the app to show later, if it does */
#define CB_FRAME_REPLAY 0x04 /* resent after REPLAY; already presented or superseded */

#define CB_MODE_PASSTHROUGH 0
#define CB_MODE_DECODE 1

#define CB_CLOSE_APP 0         /* the app destroyed the decoder */
#define CB_CLOSE_READBACK 1    /* the app read pixels back: decoding locally now */
#define CB_CLOSE_REQUESTED 2   /* the compositor sent DECODE: decoding locally now */
#define CB_CLOSE_UNSUPPORTED 3 /* the bitstream cannot be rebuilt: the app decodes it in software */
#define CB_CLOSE_ERROR 4       /* no ACCEPT in time, or the socket failed: decoding locally */

#endif
