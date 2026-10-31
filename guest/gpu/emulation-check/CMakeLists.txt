cmake_minimum_required(VERSION 3.24)
project(CabooseVulkanAcceptance LANGUAGES CXX)

# This target uses a real Vulkan loader. Driver selection belongs to the bounded
# invocation, not a fabricated feature profile or a linked mock ICD.
find_package(Vulkan REQUIRED)
find_program(GLSLANG_VALIDATOR glslangValidator REQUIRED)
find_program(SPIRV_VAL spirv-val REQUIRED)
set(shader_names control.vert cull.vert geometry.vert geometry.geom color.frag feedback.comp)
set(shader_outputs)
foreach(shader IN LISTS shader_names)
    set(output "${CMAKE_CURRENT_BINARY_DIR}/shaders/${shader}.spv")
    add_custom_command(OUTPUT "${output}"
        COMMAND "${CMAKE_COMMAND}" -E make_directory "${CMAKE_CURRENT_BINARY_DIR}/shaders"
        COMMAND "${GLSLANG_VALIDATOR}" -V --target-env vulkan1.0 -o "${output}"
                "${CMAKE_CURRENT_SOURCE_DIR}/${shader}"
        COMMAND "${SPIRV_VAL}" --target-env vulkan1.0 "${output}"
        DEPENDS "${CMAKE_CURRENT_SOURCE_DIR}/${shader}"
        VERBATIM)
    list(APPEND shader_outputs "${output}")
endforeach()
add_custom_target(caboose_acceptance_shaders DEPENDS ${shader_outputs})
add_executable(caboose_vulkan_acceptance render.cpp)
target_compile_features(caboose_vulkan_acceptance PRIVATE cxx_std_20)
target_link_libraries(caboose_vulkan_acceptance PRIVATE Vulkan::Vulkan)
add_dependencies(caboose_vulkan_acceptance caboose_acceptance_shaders)
