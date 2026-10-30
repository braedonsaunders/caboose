#version 450
// Reference rasterization: identical triangles, no cull-distance output.
layout(location = 0) flat out vec4 color;
const vec2 positions[6] = vec2[6](
    vec2(-0.9, -0.8), vec2(-0.1, -0.8), vec2(-0.5, 0.8),
    vec2( 0.1, -0.8), vec2( 0.9, -0.8), vec2( 0.5, 0.8));
void main() {
    gl_Position = vec4(positions[gl_VertexIndex], 0.5, 1.0);
    color = vec4(0.0, 1.0, 0.0, 1.0);
}
