#version 300 es
precision mediump float;

in vec3 vertexPosition;
in vec4 vertexColor;

uniform mat4 mvp;

out vec4 fragColor;
out vec3 fragPos;

void main()
{
    fragColor = vertexColor;
    fragPos   = vertexPosition;
    gl_Position = mvp * vec4(vertexPosition, 1.0);
}
