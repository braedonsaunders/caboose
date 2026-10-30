#version 450
// Two separate triangles: mixed-sign cull values must preserve the whole left one.
// All-negative cull values must discard the right one. Magnitude is irrelevant.
out gl_PerVertex { vec4 gl_Position; float gl_CullDistance[1]; };
layout(location = 0) flat out vec4 color;
const vec2 positions[6] = vec2[6](
    vec2(-0.9, -0.8), vec2(-0.1, -0.8), vec2(-0.5, 0.8),
    vec2( 0.1, -0.8), vec2( 0.9, -0.8), vec2( 0.5, 0.8));
const float distances[6] = float[6](-1e30, 1.0, 1.0, -1.0, -1.0, -1.0);
void main() {
    gl_Position = vec4(positions[gl_VertexIndex], 0.5, 1.0);
    gl_CullDistance[0] = distances[gl_VertexIndex];
    color = vec4(0.0, 1.0, 0.0, 1.0);
}
