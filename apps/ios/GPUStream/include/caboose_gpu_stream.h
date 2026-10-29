/*
 * Caboose GPU stream player: replays a live GFXReconstruct Vulkan capture stream on this
 * device's GPU, through MoltenVK, into a CAMetalLayer.
 *
 * The stream is the byte stream the GFXReconstruct capture layer writes (capture format
 * 1.0.5, uncompressed or zlib-compressed blocks). A player runs the replay on its own
 * thread with the same choices as `gfxrecon-replay --remove-unsupported -m rebind`:
 * unsupported extensions and features are removed, memory is rebound to this GPU's memory
 * types, and presents go through a virtual swapchain copied into the layer's swapchain.
 *
 * Every function is safe to call from any thread. One thread at a time may feed a player.
 * Players replay at once, each on its own thread with its own Vulkan instance and device.
 */
#ifndef CABOOSE_GPU_STREAM_H
#define CABOOSE_GPU_STREAM_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define CGPU_API __attribute__((visibility("default")))

typedef struct cgpu_player cgpu_player;

typedef enum cgpu_state {
    /** Replaying, or waiting for more of the stream. */
    CGPU_STATE_RUNNING = 0,
    /** Every frame of a finished stream was replayed, or the player was cancelled. */
    CGPU_STATE_FINISHED = 1,
    /** The replay stopped on an error; cgpu_player_copy_error describes it. */
    CGPU_STATE_FAILED = 2,
} cgpu_state;

typedef enum cgpu_event {
    /** A frame was replayed and presented. */
    CGPU_EVENT_FRAME = 0,
    /** The replay stopped; `state` says how. Sent once, last. */
    CGPU_EVENT_ENDED = 1,
} cgpu_event;

typedef struct cgpu_status {
    cgpu_event event;
    cgpu_state state;
    /** Frames replayed and presented so far. */
    uint64_t frames;
    /** Why the replay failed, while the callback runs; NULL unless `state` is FAILED. */
    const char *error;
} cgpu_status;

/** Called on the player's replay thread, never after cgpu_player_destroy returns. */
typedef void (*cgpu_event_callback)(void *context, const cgpu_status *status);

/**
 * Starts a player that presents into `metal_layer`, a `CAMetalLayer *`, which the player
 * retains until it is destroyed. The layer's drawable size follows the captured swapchain.
 * `callback` may be NULL. Returns NULL if the player cannot start (the reason is logged).
 */
CGPU_API cgpu_player *cgpu_player_create(void *metal_layer, cgpu_event_callback callback, void *context);

/**
 * Hands the next `length` bytes of the stream to the replay. Blocks until the replay has
 * taken them, so a stream that arrives faster than it replays is held back here. Returns 0,
 * or -1 if the replay has stopped and no longer takes bytes.
 */
CGPU_API int cgpu_player_feed(cgpu_player *player, const void *bytes, size_t length);

/** Ends the stream. The replay finishes the frames it has and stops. */
CGPU_API void cgpu_player_finish(cgpu_player *player);

/**
 * Stops the replay without waiting for it: a feed in progress returns -1, later feeds are
 * refused, and the replay stops after the frame it is on.
 */
CGPU_API void cgpu_player_cancel(cgpu_player *player);

/** Blocks until the replay stops, and returns how it stopped. */
CGPU_API cgpu_state cgpu_player_wait(cgpu_player *player);

CGPU_API cgpu_state cgpu_player_state(const cgpu_player *player);

/** The number of frames replayed and presented so far. */
CGPU_API uint64_t cgpu_player_frames(const cgpu_player *player);

/**
 * Copies the message for the error that stopped the replay, NUL-terminated and truncated to
 * `capacity`, and returns its full length in bytes (0 when there is none).
 */
CGPU_API size_t cgpu_player_copy_error(const cgpu_player *player, char *buffer, size_t capacity);

/** Cancels the replay if it is still running, waits for its thread and frees the player. */
CGPU_API void cgpu_player_destroy(cgpu_player *player);

#ifdef __cplusplus
}
#endif

#endif /* CABOOSE_GPU_STREAM_H */
