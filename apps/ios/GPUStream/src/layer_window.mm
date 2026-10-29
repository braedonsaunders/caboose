// GFXReconstruct's MetalContext for an embedded player, and the windows it makes.
//
// GFXReconstruct's own MetalContext (framework/application/metal_context.mm) runs an
// NSApplication and opens an NSWindow per surface, which neither iOS nor an app that hosts
// the picture in its own view can use. This build compiles this file in its place: the
// same class, whose windows are layers.
#include "layer_window.h"

#include "application/application.h"

#if !__has_feature(objc_arc)
#error "Compile this with -fobjc-arc"
#endif

namespace caboose::gpu_stream {

bool LayerWindow::Create(const std::string&, const int32_t, const int32_t, const uint32_t width, const uint32_t height, bool)
{
    layer_ = factory_->TakeLayer(&presents_to_host_);
    SetSize(width, height);
    factory_->context_->RegisterWindow(this);
    return layer_ != nil;
}

bool LayerWindow::Destroy()
{
    if (layer_ != nil)
    {
        factory_->context_->UnregisterWindow(this);
        factory_->ReturnLayer(presents_to_host_);
        layer_            = nil;
        presents_to_host_ = false;
    }
    return true;
}

void LayerWindow::SetSize(const uint32_t width, const uint32_t height)
{
    // MoltenVK sizes the layer's drawables to each swapchain it makes on the layer.
    width_  = width;
    height_ = height;
}

void LayerWindow::SetSizePreTransform(const uint32_t width, const uint32_t height, const uint32_t)
{
    SetSize(width, height);
}

bool LayerWindow::GetNativeHandle(HandleType type, void** handle)
{
    if (type != Window::kMetalLayer || layer_ == nil)
    {
        return false;
    }
    *handle = (__bridge void*)layer_;
    return true;
}

VkResult LayerWindow::CreateSurface(const gfxrecon::graphics::VulkanInstanceTable* table,
                                    VkInstance                                     instance,
                                    VkFlags                                        flags,
                                    VkSurfaceKHR*                                  surface)
{
    if (table == nullptr || layer_ == nil)
    {
        return VK_ERROR_INITIALIZATION_FAILED;
    }
    VkMetalSurfaceCreateInfoEXT create_info = { VK_STRUCTURE_TYPE_METAL_SURFACE_CREATE_INFO_EXT };
    create_info.flags                       = flags;
    create_info.pLayer                      = layer_;
    return table->CreateMetalSurfaceEXT(instance, &create_info, nullptr, surface);
}

void LayerWindow::DestroySurface(const gfxrecon::graphics::VulkanInstanceTable* table,
                                 VkInstance                                     instance,
                                 VkSurfaceKHR                                   surface)
{
    if (table != nullptr)
    {
        table->DestroySurfaceKHR(instance, surface, nullptr);
    }
}

gfxrecon::decode::Window*
LayerWindowFactory::Create(const int32_t x, const int32_t y, const uint32_t width, const uint32_t height, bool force_windowed)
{
    auto* window = new LayerWindow(this);
    window->Create(context_->GetApplication()->GetName(), x, y, width, height, force_windowed);
    return window;
}

void LayerWindowFactory::Destroy(gfxrecon::decode::Window* window)
{
    if (window != nullptr)
    {
        window->Destroy();
        delete window;
    }
}

CAMetalLayer* LayerWindowFactory::TakeLayer(bool* is_host)
{
    if (host_layer_ != nil && !host_layer_taken_)
    {
        host_layer_taken_ = true;
        *is_host          = true;
        return host_layer_;
    }
    *is_host = false;
    return [CAMetalLayer layer];
}

void LayerWindowFactory::ReturnLayer(bool is_host)
{
    if (is_host)
    {
        host_layer_taken_ = false;
    }
}

} // namespace caboose::gpu_stream

GFXRECON_BEGIN_NAMESPACE(gfxrecon)
GFXRECON_BEGIN_NAMESPACE(application)

MetalContext::MetalContext(Application* application) : WsiContext(application)
{
    window_factory_ = std::make_unique<caboose::gpu_stream::LayerWindowFactory>(this);
}

void MetalContext::ProcessEvents(bool)
{
    // The app that hosts the layer handles its own events.
}

GFXRECON_END_NAMESPACE(application)
GFXRECON_END_NAMESPACE(gfxrecon)
