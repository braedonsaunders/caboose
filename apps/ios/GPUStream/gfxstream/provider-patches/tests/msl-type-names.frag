#version 450
// Zink names its variables after their NIR types; check-msl-type-names.sh renames these
// to MSL type names in the SPIR-V before converting it.
layout(set = 0, binding = 0) uniform sampler2D NAME_SAMPLER;
layout(set = 0, binding = 1) uniform sampler2D NAME_TEXTURE;
layout(set = 0, binding = 2) uniform Block { vec4 NAME_FLOAT4; } NAME_ARRAY;
layout(location = 0) in vec2 NAME_HALF;
layout(location = 0) out vec4 color;
void main() {
    color = texture(NAME_SAMPLER, NAME_HALF) + texture(NAME_TEXTURE, NAME_HALF) + NAME_ARRAY.NAME_FLOAT4;
}
