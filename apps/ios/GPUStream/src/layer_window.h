// GFXReconstruct's window abstraction over a CAMetalLayer the app owns.
//
// GFXReconstruct's application layer creates one window per surface the capture made and
// asks it for a VkSurfaceKHR. Here the windows do not open anything: the first live window
// presents into the layer the player was given, and any further surface the capture makes
// at the same time renders into a layer of its own that is not shown.
#ifndef CABOOSE_GPU_STREAM_LAYER_WINDOW_H
#define CABOOSE_GPU_STREAM_LAYER_WINDOW_H

#include "application/metal_context.h"
#include "decode/window.h"

#import <QuartzCore/CAMetalLayer.h>

namespace caboose::gpu_stream {

class LayerWindowFactory;

class LayerWindow : public gfxrecon::decode::Window
{
  public:
    explicit LayerWindow(LayerWindowFactory* factory) : factory_(factory) {}

    bool Create(const std::string& title,
                const int32_t      xpos,
                const int32_t      ypos,
                const uint32_t     width,
                const uint32_t     height,
                bool               force_windowed) override;

    bool Destroy() override;

    void SetTitle(const std::string&) override {}
    void SetPosition(const int32_t, const int32_t) override {}
    void SetSize(const uint32_t width, const uint32_t height) override;
    void SetSizePreTransform(const uint32_t width, const uint32_t height, const uint32_t) override;
    void SetVisibility(bool) override {}
    void SetForeground() override {}

    bool GetNativeHandle(HandleType type, void** handle) override;

    std::string GetWsiExtension() const override { return VK_EXT_METAL_SURFACE_EXTENSION_NAME; }

    VkExtent2D GetSize() const override { return { width_, height_ }; }

    VkResult CreateSurface(const gfxrecon::graphics::VulkanInstanceTable* table,
                           VkInstance                                     instance,
                           VkFlags                                        flags,
                           VkSurfaceKHR*                                  surface) override;

    void DestroySurface(const gfxrecon::graphics::VulkanInstanceTable* table,
                        VkInstance                                     instance,
                        VkSurfaceKHR                                   surface) override;

  private:
    LayerWindowFactory* factory_;
    CAMetalLayer*       layer_{ nil };
    bool                presents_to_host_{ false };
    uint32_t            width_{ 0 };
    uint32_t            height_{ 0 };
};

class LayerWindowFactory : public gfxrecon::decode::WindowFactory
{
  public:
    explicit LayerWindowFactory(gfxrecon::application::MetalContext* context) : context_(context) {}

    // The layer the first live window presents into. Set before the replay starts.
    void SetHostLayer(CAMetalLayer* layer) { host_layer_ = layer; }

    const char* GetSurfaceExtensionName() const override { return VK_EXT_METAL_SURFACE_EXTENSION_NAME; }

    gfxrecon::decode::Window*
    Create(const int32_t x, const int32_t y, const uint32_t width, const uint32_t height, bool force_windowed) override;

    void Destroy(gfxrecon::decode::Window* window) override;

    VkBool32 GetPhysicalDevicePresentationSupport(const gfxrecon::graphics::VulkanInstanceTable*,
                                                  VkPhysicalDevice,
                                                  uint32_t) override
    {
        return VK_TRUE;
    }

  private:
    friend class LayerWindow;

    // Hands out the host layer if no live window holds it, or a fresh layer of its own.
    CAMetalLayer* TakeLayer(bool* is_host);
    void          ReturnLayer(bool is_host);

    gfxrecon::application::MetalContext* context_;
    CAMetalLayer*                        host_layer_{ nil };
    bool                                 host_layer_taken_{ false };
};

} // namespace caboose::gpu_stream

#endif // CABOOSE_GPU_STREAM_LAYER_WINDOW_H
