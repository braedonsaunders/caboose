add_library(caboose_gpu_device_fixture STATIC "${CMAKE_CURRENT_LIST_DIR}/../device_fixture.cpp")
target_compile_features(caboose_gpu_device_fixture PRIVATE cxx_std_17)
target_compile_definitions(caboose_gpu_device_fixture PRIVATE GFXSTREAM_ENABLE_HOST_GLES=0)
target_include_directories(caboose_gpu_device_fixture PRIVATE
    "${CABOOSE_ADAPTER_DIR}" "${CABOOSE_GFXSTREAM_SOURCE}/host"
    "${CABOOSE_GFXSTREAM_SOURCE}/host/vulkan" "${CABOOSE_GFXSTREAM_SOURCE}/host/vulkan/cereal/common")
target_link_libraries(caboose_gpu_device_fixture PRIVATE caboose_gfxstream_framebuffer
    caboose_gfxstream_connection gfxstream_backend_static)
add_executable(CabooseGPUDiagnostic MACOSX_BUNDLE "${CMAKE_CURRENT_LIST_DIR}/main.mm")
target_compile_features(CabooseGPUDiagnostic PRIVATE cxx_std_17)
target_compile_options(CabooseGPUDiagnostic PRIVATE -fobjc-arc -fblocks)
target_include_directories(CabooseGPUDiagnostic PRIVATE "${CMAKE_CURRENT_LIST_DIR}/..")
target_link_libraries(CabooseGPUDiagnostic PRIVATE caboose_gpu_device_fixture
    caboose_gfxstream_framebuffer caboose_gfxstream_connection gfxstream_backend_static
    "-framework Foundation" "-framework CoreGraphics" "-framework IOSurface"
    "-framework Metal" "-framework QuartzCore" "-framework UIKit"
    "-framework Network" "-framework Security" z)
# The resolver looks up loader trampolines from this one linked MoltenVK. Force
# its archive members into the executable and export its symbols for dlsym.
target_link_options(CabooseGPUDiagnostic PRIVATE "LINKER:-force_load,${CABOOSE_MOLTENVK_ARCHIVE}"
    "LINKER:-export_dynamic")
set_target_properties(CabooseGPUDiagnostic PROPERTIES
    MACOSX_BUNDLE_INFO_PLIST "${CMAKE_CURRENT_LIST_DIR}/Info.plist"
    XCODE_ATTRIBUTE_PRODUCT_BUNDLE_IDENTIFIER "org.caboose.gpu-diagnostic"
    XCODE_ATTRIBUTE_TARGETED_DEVICE_FAMILY "1,2")
