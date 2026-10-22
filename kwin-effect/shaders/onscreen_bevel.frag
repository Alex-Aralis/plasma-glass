#version 140

#include "sdf.glsl"

// The blur behind a Liquid Glass surface (plasma-glass), seen through the glass's bevel: within bevel.x of
// the edge the glass rounds off like a quarter circle, so it refracts the same frosted view as the rest of
// the glass, from further in the steeper it is (bevel.y at the very edge), and sharper towards the edge,
// where it's polished (bevel.w: how much of what's behind shows as it is, at the very edge). Blue bends
// more than red: the colours part along the edge by bevel.z each way. While the liquid in the glass moves
// (KRunner's: surface.frag), its waves lean the glass too, and bend what's behind it the same way: a
// fresh wave's steepest slope as far as the bevel at its edge, with its colours parting a little more
// (ripple.z where one leans fully). A ripple clears the glass where it runs, over its crests and troughs
// too, where it doesn't lean: by its height (up or down), where that's more.

uniform sampler2D texUnit;   // the blurred background at half size (its last upsample step is done here)
uniform sampler2D sharpUnit; // the background as it is
uniform mat4 colorMatrix;
uniform float offset;
uniform vec2 halfpixel;
uniform vec4 box;          // the glass: centre and half size
uniform vec4 cornerRadius; // top left, top right, bottom left, bottom right
uniform float opacity;
uniform vec2 size;         // the background's size
uniform vec4 bevel;        // width, refraction, dispersion (device px), sharpness at the edge (0..1)
uniform sampler2D wavesUnit; // the liquid's surface: its slope (x, y) and the ripples' height, at half size
uniform vec3 ripple;         // while they run: what a wave's slope is multiplied by to lean the glass, and
                             // its height to clear it (0: no waves); how far its colours part where one
                             // leans the glass fully (device px)

in vec2 uv;
in vec2 vertex; // device px from the background's top left

out vec4 fragColor;

vec4 blurred(vec2 at)
{
    vec4 sum = texture(texUnit, at + vec2(-halfpixel.x * 2.0, 0.0) * offset);
    sum += texture(texUnit, at + vec2(-halfpixel.x, halfpixel.y) * offset) * 2.0;
    sum += texture(texUnit, at + vec2(0.0, halfpixel.y * 2.0) * offset);
    sum += texture(texUnit, at + vec2(halfpixel.x, halfpixel.y) * offset) * 2.0;
    sum += texture(texUnit, at + vec2(halfpixel.x * 2.0, 0.0) * offset);
    sum += texture(texUnit, at + vec2(halfpixel.x, -halfpixel.y) * offset) * 2.0;
    sum += texture(texUnit, at + vec2(0.0, -halfpixel.y * 2.0) * offset);
    sum += texture(texUnit, at + vec2(-halfpixel.x, -halfpixel.y) * offset) * 2.0;
    return sum / 12.0;
}

// texture coordinates of device px p
vec2 at(vec2 p)
{
    return vec2(p.x / size.x, 1.0 - p.y / size.y);
}

float outline(vec2 p)
{
    return sdfRoundedBox(p, box.xy, box.zw, cornerRadius);
}

void main(void)
{
    float f = outline(vertex);
    float df = fwidth(f);
    float d = -f; // px inside the glass

    // which way the glass faces here, and how far it leans that way (the sine of its tilt); and how clear
    // it is, from frosted (0) to clear (1)
    vec2 lean = vec2(0.0);
    float clear = 0.0;
    vec2 waveLean = vec2(0.0); // the waves' part of it
    if (d < bevel.x) {
        // the bevel: out of the glass, across the outline; a quarter circle, so 1 at the edge and 0 where
        // the glass turns flat; clear as far as it leans
        vec2 g = vec2(outline(vertex + vec2(0.5, 0.0)) - outline(vertex - vec2(0.5, 0.0)),
                      outline(vertex + vec2(0.0, 0.5)) - outline(vertex - vec2(0.0, 0.5)));
        lean = g / max(length(g), 1e-4) * (1.0 - max(d, 0.0) / bevel.x);
        clear = length(lean);
    }
    if (ripple.x > 0.0) {
        vec3 wave = texture(wavesUnit, uv).xyz;
        waveLean = -wave.xy * ripple.x; // a wave faces downhill
        lean += waveLean;
        clear = max(clear, max(length(waveLean), abs(wave.z) * ripple.y));
    }
    float tilt = min(length(lean), 1.0);
    clear = min(clear, 1.0);

    vec4 color;
    if (tilt > 1e-3 || clear > 1e-3) {
        vec2 facing = lean / max(length(lean), 1e-6);
        vec2 p = vertex - facing * bevel.y * tilt * tilt; // refracted: seen from further in, most where it's steep
        // (a smooth start where the glass is flat; keep bevel.y under half bevel.x, or the bevel folds over)
        // red from a little further out, blue from further in: as far as the glass leans, and a little
        // further as far as a wave leans it
        vec2 split = facing * bevel.z * tilt + waveLean / max(length(waveLean), 1.0) * (ripple.z - bevel.z);
        // the colours part only in the sharp view: on the frost it wouldn't show, and it would take the
        // blur's 8 samples three times over
        vec4 sharp = texture(sharpUnit, at(p));
        sharp.r = texture(sharpUnit, at(p + split)).r;
        sharp.b = texture(sharpUnit, at(p - split)).b;
        color = mix(blurred(at(p)), sharp, bevel.w * clear);
    } else {
        color = blurred(uv);
    }

    fragColor = color * colorMatrix * opacity;
    fragColor *= 1.0 - clamp(0.5 + f / df, 0.0, 1.0);
}
