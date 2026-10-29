// The GPU stream player: GFXReconstruct's FileProcessor and VulkanReplayConsumer on a
// thread of their own, reading the fed bytes through a FIFO and presenting into the
// host's CAMetalLayer through MoltenVK. Players replay at once, each on its own thread: the
// decoder's state is per thread (patches/0003-per-thread-decode-state.patch), and MoltenVK's
// unlocked process-wide initialization is serialized (moltenvk.h).
#include "caboose_gpu_stream.h"
#include "layer_window.h"
#include "moltenvk.h"

#include "application/application.h"
#include "decode/file_processor.h"
#include "decode/vulkan_rebind_allocator.h"
#include "generated/generated_vulkan_consumer.h"
#include "generated/generated_vulkan_decoder.h"
#include "generated/generated_vulkan_replay_consumer.h"
#include "graphics/fps_info.h"
#include "util/logging.h"

#import <Foundation/Foundation.h>

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cerrno>
#include <condition_variable>
#include <cstdlib>
#include <cstring>
#include <fcntl.h>
#include <limits>
#include <memory>
#include <mutex>
#include <poll.h>
#include <pthread.h>
#include <stdexcept>
#include <string>
#include <sys/stat.h>
#include <unistd.h>

#if !__has_feature(objc_arc)
#error "Compile this with -fobjc-arc"
#endif

using namespace gfxrecon;

namespace {

// Some capture streams make deep pNext chains that recurse while decoding; give the replay
// the stack a main thread would have.
constexpr size_t kReplayStackSize = 8 * 1024 * 1024;

void InitializeLoggingOnce()
{
    static std::once_flag once;
    std::call_once(once, [] {
        util::Log::Init(decode::kDefaultLogLevel);
        // gfxrecon-replay turns fatal replay errors into exceptions the same way.
        util::Log::SetFatalCallback([](const char* message) { throw std::runtime_error(message); });
    });
}

const char* DescribeStreamError(decode::BlockIOError error)
{
    switch (error)
    {
        case decode::kErrorReadingFileHeader:
            return "The stream does not start with a GFXReconstruct file header";
        case decode::kErrorUnsupportedCompressionType:
            return "The stream uses a compression this player does not decode (it decodes uncompressed and zlib "
                   "blocks)";
        case decode::kErrorInvalidFourCC:
            return "The stream is not a GFXReconstruct capture";
        case decode::kErrorReadingBlockHeader:
        case decode::kErrorReadingBlockData:
        case decode::kErrorReadingCompressedBlockHeader:
        case decode::kErrorReadingCompressedBlockData:
            return "The stream ended in the middle of a block";
        default:
            return "The stream could not be read";
    }
}

decode::VulkanReplayOptions MakeReplayOptions(const std::string& stream_path)
{
    // The choices of `gfxrecon-replay --remove-unsupported -m rebind`, with the virtual
    // swapchain that is its default.
    decode::VulkanReplayOptions options;
    options.capture_filename                     = stream_path;
    options.remove_unsupported_features          = true;
    options.create_resource_allocator            = [] { return new decode::VulkanRebindAllocator(); };
    options.swapchain_option                     = util::SwapchainOption::kVirtual;
    options.add_new_pipeline_caches              = false;
    options.dump_resources_modifiable_state_only = false;
    util::UintRange every_frame;
    every_frame.first = 1;
    every_frame.last  = std::numeric_limits<uint32_t>::max();
    options.skip_get_fence_ranges.push_back(every_frame);
    return options;
}

} // namespace

struct cgpu_player
{
    CAMetalLayer*       layer{ nil };
    cgpu_event_callback callback{ nullptr };
    void*               context{ nullptr };

    std::string directory;
    std::string stream_path;

    pthread_t thread{};
    bool      thread_started{ false };

    // Guards the writing end: one feed or finish at a time.
    std::mutex feed_mutex;
    int        write_fd{ -1 };
    bool       write_closed{ false };

    mutable std::mutex      state_mutex;
    std::condition_variable state_changed;
    cgpu_state              state{ CGPU_STATE_RUNNING };
    bool                    replay_ended{ false };
    // The replay has begun opening the stream, so a writer will find a reader.
    bool                    opening_stream{ false };
    std::string             error;

    std::atomic<uint64_t> frames{ 0 };
    std::atomic<bool>     stop_requested{ false };

    bool HasReplayEnded()
    {
        std::lock_guard<std::mutex> lock(state_mutex);
        return replay_ended;
    }

    void End(cgpu_state final_state, std::string message)
    {
        {
            std::lock_guard<std::mutex> lock(state_mutex);
            state        = final_state;
            error        = std::move(message);
            replay_ended = true;
        }
        state_changed.notify_all();
    }

    // A replay that was cancelled stops on whatever it was reading; that is not a failure.
    void Fail(std::string message)
    {
        if (stop_requested.load())
        {
            End(CGPU_STATE_FINISHED, std::string());
        }
        else
        {
            End(CGPU_STATE_FAILED, std::move(message));
        }
    }

    void Notify(cgpu_event event)
    {
        if (callback == nullptr)
        {
            return;
        }
        cgpu_status status = { event, CGPU_STATE_RUNNING, frames.load(), nullptr };
        std::string message;
        {
            std::lock_guard<std::mutex> lock(state_mutex);
            status.state = state;
            message      = error;
        }
        if (status.state == CGPU_STATE_FAILED)
        {
            status.error = message.c_str();
        }
        callback(context, &status);
    }

    // Opens the FIFO's writing end once the replay has opened its reading end. Returns false
    // if the replay ended first. Called with feed_mutex held.
    bool OpenWriter()
    {
        while (write_fd < 0)
        {
            int fd = open(stream_path.c_str(), O_WRONLY | O_NONBLOCK | O_CLOEXEC);
            if (fd >= 0)
            {
                fcntl(fd, F_SETNOSIGPIPE, 1);
                write_fd = fd;
                return true;
            }
            if (errno != ENXIO && errno != EINTR)
            {
                return false;
            }
            std::unique_lock<std::mutex> lock(state_mutex);
            // A replay that is cancelled before it opens the stream never opens it.
            if (replay_ended || (!opening_stream && stop_requested.load()))
            {
                return false;
            }
            state_changed.wait_for(lock, std::chrono::milliseconds(5));
        }
        return true;
    }

    // Closes the writing end, so the replay reads the end of the stream. If the replay has not
    // opened the stream yet, opens it first, so that the replay does not wait for it forever.
    // Called with feed_mutex held.
    void CloseWriter()
    {
        if (write_closed)
        {
            return;
        }
        write_closed = true;
        if (write_fd < 0)
        {
            OpenWriter();
        }
        if (write_fd >= 0)
        {
            close(write_fd);
            write_fd = -1;
        }
    }

    void Replay();
};

void cgpu_player::Replay()
{
    InitializeLoggingOnce();

    bool cancelled = false;
    {
        std::lock_guard<std::mutex> lock(state_mutex);
        cancelled      = stop_requested.load();
        opening_stream = !cancelled;
    }
    if (cancelled)
    {
        End(CGPU_STATE_FINISHED, std::string());
        return;
    }

    try
    {
        decode::FileProcessor file_processor;
        if (!file_processor.Initialize(stream_path))
        {
            Fail(DescribeStreamError(file_processor.GetErrorState()));
            return;
        }

        auto application = std::make_shared<application::Application>(
            "Caboose", &file_processor, VK_EXT_METAL_SURFACE_EXTENSION_NAME, nullptr);
        auto* wsi_context = application->GetWsiContext(VK_EXT_METAL_SURFACE_EXTENSION_NAME);
        if (wsi_context == nullptr)
        {
            Fail("The Metal surface context could not be created");
            return;
        }
        static_cast<caboose::gpu_stream::LayerWindowFactory*>(wsi_context->GetWindowFactory())->SetHostLayer(layer);

        graphics::FpsInfo                fps_info;
        decode::VulkanDecoder            decoder;
        decode::VulkanReplayOptions      options = MakeReplayOptions(stream_path);
        decode::VulkanReplayConsumer     consumer(application, options);
        consumer.SetInstanceProcAddr(caboose::gpu_stream::GetInstanceProcAddr);
        consumer.SetFpsInfo(&fps_info);
        decoder.AddConsumer(&consumer);
        file_processor.AddDecoder(&decoder);
        application->SetFpsInfo(&fps_info);

        if (!file_processor.InitializeFrameProcessing())
        {
            Fail("The replay could not start");
            return;
        }

        fps_info.BeginFile();
        while (!stop_requested.load())
        {
            bool played = false;
            @autoreleasepool
            {
                played = application->PlaySingleFrame();
            }
            if (!played)
            {
                break;
            }
            frames.store(file_processor.GetCurrentFrameNumber());
            Notify(CGPU_EVENT_FRAME);
        }

        consumer.WaitDevicesIdle();
        file_processor.RemoveDecoder(&decoder);
        decoder.RemoveConsumer(&consumer);

        const decode::BlockIOError stream_error = file_processor.GetErrorState();
        if (stream_error == decode::kErrorNone || stream_error == decode::kEndOfFile)
        {
            End(CGPU_STATE_FINISHED, std::string());
        }
        else
        {
            Fail(DescribeStreamError(stream_error));
        }
    }
    catch (const std::exception& failure)
    {
        Fail(failure.what());
    }
    catch (...)
    {
        Fail("The replay stopped on an unknown error");
    }
}

static void* RunReplay(void* argument)
{
    auto* player = static_cast<cgpu_player*>(argument);
    pthread_setname_np("Caboose GPU stream");
    player->Replay();
    player->Notify(CGPU_EVENT_ENDED);
    return nullptr;
}

static bool MakeStreamFifo(cgpu_player* player)
{
    const char* temporary = getenv("TMPDIR");
    std::string pattern   = std::string(temporary != nullptr && temporary[0] != '\0' ? temporary : "/tmp");
    if (pattern.back() != '/')
    {
        pattern += '/';
    }
    pattern += "caboose-gpu-stream.XXXXXX";

    std::string directory(pattern);
    if (mkdtemp(directory.data()) == nullptr)
    {
        GFXRECON_LOG_ERROR("GPU stream: could not create %s: %s", pattern.c_str(), strerror(errno));
        return false;
    }
    player->directory   = directory;
    player->stream_path = directory + "/stream.gfxr";
    if (mkfifo(player->stream_path.c_str(), S_IRUSR | S_IWUSR) != 0)
    {
        GFXRECON_LOG_ERROR("GPU stream: could not create %s: %s", player->stream_path.c_str(), strerror(errno));
        rmdir(player->directory.c_str());
        player->directory.clear();
        return false;
    }
    return true;
}

static void RemoveStreamFifo(cgpu_player* player)
{
    if (!player->stream_path.empty())
    {
        unlink(player->stream_path.c_str());
    }
    if (!player->directory.empty())
    {
        rmdir(player->directory.c_str());
    }
}

extern "C" cgpu_player* cgpu_player_create(void* metal_layer, cgpu_event_callback callback, void* context)
{
    InitializeLoggingOnce();

    if (metal_layer == nullptr)
    {
        GFXRECON_LOG_ERROR("GPU stream: a player needs a CAMetalLayer");
        return nullptr;
    }

    auto* player     = new cgpu_player();
    player->layer    = (__bridge CAMetalLayer*)metal_layer;
    player->callback = callback;
    player->context  = context;

    if (!MakeStreamFifo(player))
    {
        player->write_closed = true;
        player->End(CGPU_STATE_FAILED, "The stream's pipe could not be created");
        return player;
    }

    pthread_attr_t attributes;
    pthread_attr_init(&attributes);
    pthread_attr_setstacksize(&attributes, kReplayStackSize);
    const int started = pthread_create(&player->thread, &attributes, RunReplay, player);
    pthread_attr_destroy(&attributes);
    if (started != 0)
    {
        player->write_closed = true;
        player->End(CGPU_STATE_FAILED, std::string("The replay thread could not start: ") + strerror(started));
        return player;
    }
    player->thread_started = true;
    return player;
}

extern "C" int cgpu_player_feed(cgpu_player* player, const void* bytes, size_t length)
{
    std::lock_guard<std::mutex> lock(player->feed_mutex);
    if (player->write_closed || (player->write_fd < 0 && !player->OpenWriter()))
    {
        return -1;
    }

    const auto* next      = static_cast<const uint8_t*>(bytes);
    size_t      remaining = length;
    while (remaining > 0)
    {
        const ssize_t written = write(player->write_fd, next, remaining);
        if (written > 0)
        {
            next += written;
            remaining -= static_cast<size_t>(written);
            continue;
        }
        if (written < 0 && errno == EINTR)
        {
            continue;
        }
        if (written < 0 && errno == EAGAIN)
        {
            // The pipe is full until the replay reads more. Wake now and then to notice a
            // replay that stopped with a full pipe, which never reads again.
            if (player->stop_requested.load() || player->HasReplayEnded())
            {
                return -1;
            }
            pollfd room = { player->write_fd, POLLOUT, 0 };
            poll(&room, 1, 50);
            continue;
        }
        return -1;
    }
    return 0;
}

extern "C" void cgpu_player_finish(cgpu_player* player)
{
    std::lock_guard<std::mutex> lock(player->feed_mutex);
    player->CloseWriter();
}

extern "C" void cgpu_player_cancel(cgpu_player* player)
{
    player->stop_requested.store(true);
    std::lock_guard<std::mutex> lock(player->feed_mutex);
    player->CloseWriter();
}

extern "C" cgpu_state cgpu_player_wait(cgpu_player* player)
{
    std::unique_lock<std::mutex> lock(player->state_mutex);
    player->state_changed.wait(lock, [player] { return player->replay_ended; });
    return player->state;
}

extern "C" cgpu_state cgpu_player_state(const cgpu_player* player)
{
    std::lock_guard<std::mutex> lock(player->state_mutex);
    return player->state;
}

extern "C" uint64_t cgpu_player_frames(const cgpu_player* player)
{
    return player->frames.load();
}

extern "C" size_t cgpu_player_copy_error(const cgpu_player* player, char* buffer, size_t capacity)
{
    std::lock_guard<std::mutex> lock(player->state_mutex);
    if (buffer != nullptr && capacity > 0)
    {
        const size_t copied = std::min(capacity - 1, player->error.size());
        memcpy(buffer, player->error.data(), copied);
        buffer[copied] = '\0';
    }
    return player->error.size();
}

extern "C" void cgpu_player_destroy(cgpu_player* player)
{
    if (player == nullptr)
    {
        return;
    }
    cgpu_player_cancel(player);
    if (player->thread_started)
    {
        pthread_join(player->thread, nullptr);
    }
    RemoveStreamFifo(player);
    player->layer = nil;
    delete player;
}
