#version 450
layout(points) in;
layout(triangle_strip, max_vertices = 3) out;
layout(location = 0) flat out vec4 color;
const vec2 positions[3] = vec2[3](
    vec2(-0.8, -0.8), vec2(0.8, -0.8), vec2(0.0, 0.8));
void main() {
    for (int i = 0; i < 3; ++i) {
        gl_Position = vec4(positions[i], 0.5, 1.0);
        color = vec4(0.0, 0.0, 1.0, 1.0);
        EmitVertex();
    }
    EndPrimitive();
}
