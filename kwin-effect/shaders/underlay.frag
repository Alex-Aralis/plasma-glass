#version 140

// The liquid in KRunner's glass on Liquid Glass Light and Dark Frost (plasma-glass), beneath the frost:
// what's behind the glass, bent by the waves (seen from further in where a wave leans, as through a lens)
// and lit in shards of colour where they crest, as off an etched diffraction foil. The blur's passes then
// frost this, so the waves show through the frosting, softened. In: the background as it is, and the
// liquid's slope and heights (surface.frag: the ripples' and the swell's) at half size. Out: the background
// to frost.

uniform sampler2D texUnit;   // the background as it is
uniform sampler2D wavesUnit; // the waves: the glass's slope (x, y), the ripples' height and the swell's
uniform vec2 size;           // the background's size, device px
uniform vec2 origin;         // its top left in the window, logical px
uniform vec2 area;           // its size, logical px
uniform float lean;          // what a wave's slope is multiplied by to lean the glass
uniform vec4 light;          // device px what's behind is seen from further in where a wave leans fully;
                             // how bright the foil's colours are; its shards' size (logical px); how
                             // saturated they are (0: white)
uniform float time;          // s, for the colours' slow drift

in vec2 uv;

out vec4 fragColor;

// hashes without sine (Dave Hoskins), stable in float precision
float hash12(vec2 p)
{
    vec3 p3 = fract(vec3(p.xyx) * 0.1031);
    p3 += dot(p3, p3.yzx + 33.33);
    return fract((p3.x + p3.y) * p3.z);
}

vec2 hash22(vec2 p)
{
    vec3 p3 = fract(vec3(p.xyx) * vec3(0.1031, 0.1030, 0.0973));
    p3 += dot(p3, p3.yzx + 33.33);
    return fract((p3.xx + p3.yz) * p3.zy);
}

// a rainbow: w 0 (red) .. 1 (violet)
vec3 spectral(float w)
{
    vec3 x = 3.2 * (w - vec3(0.18, 0.48, 0.78));
    vec3 c = max(1.0 - x * x, 0.0);
    c.r += 0.35 * max(1.0 - 10.0 * (w - 1.0) * (w - 1.0), 0.0); // violet has some red
    return c;
}

void main(void)
{
    vec4 wave = texture(wavesUnit, uv);
    vec2 waveLean = -wave.xy * lean; // a wave faces downhill
    float tilt = min(length(waveLean), 1.0);
    vec2 facing = waveLean / max(length(waveLean), 1e-6);
    // seen from further in, most where it's steep (the background is drawn with v from 1 at its top)
    vec2 shift = facing * light.x * tilt * tilt / size;
    vec4 color = texture(texUnit, uv + vec2(-shift.x, shift.y));

    // the busy pushes' crests, and the sloshing's (where the window's moves heap the liquid up)
    float crest = max(wave.z, 0.0) + max(wave.w, 0.0);
    if (crest > 0.002 && light.y > 0.0) {
        // the foil's shard here: the Voronoi cells of a jittered grid, light.z logical px across, fixed to
        // the window, each with its own colour and sparkle
        vec2 q = (origin + vec2(uv.x, 1.0 - uv.y) * area) / light.z;
        vec2 cell = floor(q);
        vec2 f = q - cell;
        float best = 8.0;
        vec2 id = cell;
        for (int j = -1; j <= 1; ++j) {
            for (int i = -1; i <= 1; ++i) {
                vec2 o = vec2(float(i), float(j)) + hash22(cell + vec2(float(i), float(j))) - f;
                float d2 = dot(o, o);
                if (d2 < best) {
                    best = d2;
                    id = cell + vec2(float(i), float(j));
                }
            }
        }
        float hue = hash22(id + 17.17).y;
        float sparkle = 0.3 + 0.7 * hash12(id + 3.7);
        vec3 tint = mix(vec3(1.0), spectral(fract(hue + 0.03 * time)), light.w);
        // light the crests give off, beneath the frost
        color.rgb += tint * light.y * sparkle * min(crest, 1.0) * color.a;
    }
    fragColor = color;
}
