#version 450
// The input point is outside the viewport; only the geometry output can be visible.
void main() { gl_Position = vec4(-2.0, -2.0, 0.5, 1.0); }
