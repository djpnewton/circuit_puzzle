#version 300 es
precision mediump float;

in vec4 fragColor;
in vec3 fragPos;

uniform vec3 lightPos;
uniform vec3 viewPos;

out vec4 finalColor;

// Atmospheric fog colour -- matches the horizon sky tone.
const vec3 fogColor = vec3(0.667, 0.804, 0.910);
const float fogStart = 30.0;
const float fogEnd   = 72.0;

void main()
{
    float dist   = length(lightPos - fragPos);
    float radius = 12.0;
    float atten  = max(0.0, 1.0 - dist / radius);
    atten = atten * atten;

    vec3 glow = vec3(1.0, 0.92, 0.75) * atten * 0.45;
    vec3 color = clamp(fragColor.rgb + glow, 0.0, 1.0);

    float viewDist = length(viewPos - fragPos);
    float fog = clamp((viewDist - fogStart) / (fogEnd - fogStart), 0.0, 1.0);
    fog = fog * fog * (3.0 - 2.0 * fog);
    color = mix(color, fogColor, fog * 0.85);

    finalColor = vec4(color, fragColor.a);
}
