"""ctypes bindings of libcaboose_gpu_executor.so: native_runtime.h and the presentation drafts
(presentation_api_draft.h, presentation_swapchain_api_draft.h) with their headless entry points."""
import ctypes
from ctypes import POINTER, Structure, c_char_p, c_int, c_int32, c_size_t, c_uint8, c_uint32, c_uint64, c_void_p


class Identity(Structure):
    _fields_ = [('process_token', c_uint64), ('compositor_epoch', c_uint8 * 16), ('window_id', c_uint64),
                ('generation', c_uint64), ('grant', c_uint8 * 16)]


class BindInfo(Structure):
    _fields_ = [('identity', Identity), ('boxed_instance', c_uint64), ('width', c_uint32), ('height', c_uint32)]


class PresentInfo(Structure):
    _fields_ = [('identity', Identity), ('present_serial', c_uint64), ('boxed_device', c_uint64),
                ('boxed_queue', c_uint64), ('boxed_image', c_uint64), ('vk_format', c_uint32),
                ('width', c_uint32), ('height', c_uint32), ('vk_image_layout', c_uint32),
                ('queue_family', c_uint32), ('wait_semaphore_count', c_uint32),
                ('boxed_wait_semaphores', POINTER(c_uint64))]


class SubmitResult(Structure):
    _fields_ = [('disposition', c_int), ('native_error', c_int32), ('has_vulkan_result', c_uint32),
                ('vulkan_result', c_int32)]


class QueryStatus(Structure):
    _fields_ = [('native_error', c_int32), ('has_vulkan_result', c_uint32), ('vulkan_result', c_int32)]


class SurfaceFormat(Structure):
    _fields_ = [('format', c_uint32), ('color_space', c_uint32), ('linear_features', c_uint32),
                ('optimal_features', c_uint32), ('buffer_features', c_uint32), ('properties_queried', c_uint32)]


class QueueFamily(Structure):
    _fields_ = [('queue_flags', c_uint32), ('queue_count', c_uint32), ('present_supported', c_uint32)]


class CapabilitiesView(Structure):
    _fields_ = [(name, c_uint32) for name in (
        'min_image_count', 'max_image_count', 'current_width', 'current_height', 'min_width', 'min_height',
        'max_width', 'max_height', 'max_image_array_layers', 'supported_transforms', 'current_transform',
        'supported_composite_alpha', 'supported_usage_flags', 'format_count', 'candidate_format_count',
        'present_mode_count', 'queue_family_count')] + [
        ('formats', POINTER(SurfaceFormat)), ('candidate_formats', c_void_p),
        ('present_modes', POINTER(c_uint32)), ('queue_families', POINTER(QueueFamily))]


class SwapchainCreateInfo(Structure):
    _fields_ = [('identity', Identity), ('boxed_device', c_uint64)] + [(name, c_uint32) for name in (
        'create_flags', 'min_image_count', 'vk_format', 'color_space', 'width', 'height', 'image_array_layers',
        'image_usage', 'pre_transform', 'composite_alpha', 'present_mode', 'clipped', 'sharing_mode',
        'queue_family_count', 'has_unsupported_extensions')] + [
        ('queue_families', POINTER(c_uint32)), ('old_swapchain_id', c_uint64)]


class AcquireInfo(Structure):
    _fields_ = [('boxed_binary_semaphore', c_uint64), ('boxed_fence', c_uint64), ('device_mask', c_uint32)]


class AcquireResult(Structure):
    _fields_ = [('native_error', c_int32), ('has_vulkan_result', c_uint32), ('vulkan_result', c_int32),
                ('has_image_index', c_uint32), ('image_index', c_uint32), ('local_reason', c_uint32)]


class MappedPresentInfo(Structure):
    _fields_ = [('identity', Identity), ('present_serial', c_uint64), ('boxed_queue', c_uint64),
                ('queue_family', c_uint32), ('image_index', c_uint32), ('vk_image_layout', c_uint32),
                ('wait_semaphore_count', c_uint32), ('boxed_wait_semaphores', POINTER(c_uint64))]


# void (*)(void* context, uint64_t serial, caboose_gpu_present_event event, caboose_gpu_submit_result)
PRESENT_CALLBACK = ctypes.CFUNCTYPE(None, c_void_p, c_uint64, c_int, SubmitResult)

SOURCE_RELEASED, DEVICE_LOST, FAILED_UNRETIRED, PRESENT_RETIRED = 1, 2, 3, 4


class CapturePixels(Structure):
    _fields_ = [('data', c_void_p), ('row_pitch', c_uint64), ('width', c_uint32), ('height', c_uint32),
                ('vk_format', c_uint32)]


# void (*)(void* context, uint64_t present_serial, uint32_t token, void* pixels)
CAPTURE_CALLBACK = ctypes.CFUNCTYPE(None, c_void_p, c_uint64, c_uint32, POINTER(CapturePixels))

_SIGNATURES = {
    'caboose_gpu_executor_start': (c_int, [c_char_p]),
    'caboose_gpu_runtime_set_cache_root': (c_int, [c_char_p]),
    'caboose_gpu_runtime_open': (c_int, [POINTER(c_uint64)]),
    'caboose_gpu_runtime_run': (c_int, [c_uint64, c_int, c_size_t, c_size_t]),
    'caboose_gpu_runtime_wait_order': (c_int, [c_uint64, c_uint64]),
    'caboose_gpu_runtime_stop': (c_int, [c_uint64]),
    'caboose_gpu_runtime_finish': (c_int, [c_uint64]),
    'caboose_gpu_runtime_set_memory_limit': (c_int, [c_uint64]),
    'caboose_gpu_runtime_report_teardown': (None, []),
    'caboose_gpu_runtime_executor_stats': (c_int, [c_void_p]),
    'caboose_gpu_surface_prepare': (c_int, [POINTER(BindInfo), POINTER(c_void_p)]),
    'caboose_gpu_surface_attach_headless': (c_int, [c_void_p]),
    'caboose_gpu_surface_detach_headless': (c_int, [POINTER(c_void_p)]),
    'caboose_gpu_surface_query_variable_extent': (c_int, [c_void_p, c_uint64, POINTER(c_void_p), POINTER(QueryStatus)]),
    'caboose_gpu_surface_capabilities_get': (POINTER(CapabilitiesView), [c_void_p]),
    'caboose_gpu_surface_capabilities_release': (None, [c_void_p]),
    'caboose_gpu_surface_present': (SubmitResult, [c_void_p, POINTER(PresentInfo), PRESENT_CALLBACK, c_void_p]),
    'caboose_gpu_surface_retire': (c_int, [c_void_p]),
    'caboose_gpu_surface_set_capture': (c_int, [c_void_p, CAPTURE_CALLBACK, c_void_p]),
    'caboose_gpu_surface_release_capture': (c_int, [c_void_p, c_uint32]),
    'caboose_gpu_surface_configure_extent_headless': (c_int, [c_void_p, POINTER(Identity), c_uint32, c_uint32]),
    'caboose_gpu_virtual_swapchain_create': (c_int, [c_void_p, POINTER(SwapchainCreateInfo), POINTER(c_void_p),
                                                     POINTER(c_uint64), POINTER(c_uint32), POINTER(QueryStatus)]),
    'caboose_gpu_virtual_swapchain_map': (c_int, [c_void_p, POINTER(c_uint64), c_uint32]),
    'caboose_gpu_virtual_swapchain_map_guest_images': (c_int, [c_void_p, POINTER(c_uint64), c_uint32, c_uint32]),
    'caboose_gpu_acquire_begin': (c_int, [c_void_p, POINTER(AcquireInfo), POINTER(c_void_p), POINTER(QueryStatus)]),
    'caboose_gpu_acquire_poll': (AcquireResult, [c_void_p]),
    'caboose_gpu_acquire_cancel': (c_int, [c_void_p]),
    'caboose_gpu_acquire_observe': (QueryStatus, [c_void_p]),
    'caboose_gpu_acquire_request_release': (c_int, [POINTER(c_void_p)]),
    'caboose_gpu_virtual_swapchain_present': (SubmitResult, [c_void_p, POINTER(MappedPresentInfo),
                                                             PRESENT_CALLBACK, c_void_p]),
    'caboose_gpu_virtual_swapchain_retire': (c_int, [POINTER(c_void_p), POINTER(QueryStatus)]),
}


class Runtime:
    """The library's functions; ctypes releases the GIL around each call."""

    def __init__(self, path):
        library = ctypes.CDLL(path)
        for name, (restype, argtypes) in _SIGNATURES.items():
            function = getattr(library, name)
            function.restype, function.argtypes = restype, argtypes
            setattr(self, name[len('caboose_gpu_'):], function)


EXECUTOR_STATS_SIZE = 96


def executor_stats(runtime):
    """caboose_gpu_executor_stats as EXECUTOR_STATS carries it (twelve little-endian u64, the
    first its size), or None."""
    buffer = (ctypes.c_uint64 * (EXECUTOR_STATS_SIZE // 8))()
    buffer[0] = EXECUTOR_STATS_SIZE
    if runtime.runtime_executor_stats(ctypes.cast(buffer, c_void_p)) != 0:
        return None
    return b''.join(int(value).to_bytes(8, 'little') for value in buffer)


def u64_array(values):
    return (c_uint64 * max(1, len(values)))(*values)


def identity(process_token, epoch, window, generation, grant):
    value = Identity()
    value.process_token, value.window_id, value.generation = process_token, window, generation
    ctypes.memmove(value.compositor_epoch, epoch, 16)
    ctypes.memmove(value.grant, grant, 16)
    return value
