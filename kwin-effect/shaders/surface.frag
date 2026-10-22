#version 140

// plasma-glass: the liquid's surface over the background behind a Liquid Glass window, for the bevel pass
// (and Liquid Glass Light's underlay) to bend what's behind by: its slope (x, y), the ripples' height and
// the swell's, at half size. The liquid runs in two layers of its own (fluid.frag), which add up:
// ripples, the short waves (on cells of ripplesCell px), and swell, the long ones that slosh (swellCell
// px). Past the liquid's wavy edge, a little in from the rim, there are none.

uniform sampler2D ripples;
uniform sampler2D swell;
uniform float ripplesCell;
uniform float swellCell;
uniform vec2 origin;  // the background's top left in the glass
uniform vec2 area;    // its size, logical px
uniform vec4 gain;    // what the ripples' and the swell's slopes are multiplied by; what their heights
                      // are divided by (a fresh wave's crest, and a slosh's that leans the glass fully,
                      // come out as 1)

in vec2 uv;

out vec4 fragColor;

// the height at p from the wet cells around it only (dry ones hold 0 and say so in w, so the filtered
// height over the filtered wetness leaves them out), and how much of p is wet (0 past the liquid's edge)
vec2 height(sampler2D layer, float cell, vec2 p)
{
    vec4 s = texture(layer, (p / cell + 1.0) / vec2(textureSize(layer, 0)));
    return vec2(s.x / max(s.w, 1e-3), s.w);
}

// the slope at p, fading out across the last cell before the liquid's edge (no liquid, no waves); and the
// height
vec3 surface(sampler2D layer, float cell, vec2 p)
{
    vec2 r = height(layer, cell, p + vec2(cell, 0.0));
    vec2 l = height(layer, cell, p - vec2(cell, 0.0));
    vec2 d = height(layer, cell, p + vec2(0.0, cell));
    vec2 u = height(layer, cell, p - vec2(0.0, cell));
    vec2 c = height(layer, cell, p);
    float wet = smoothstep(0.05, 0.9, min(min(min(r.y, l.y), min(d.y, u.y)), c.y));
    return vec3(vec2(r.x - l.x, d.x - u.x) / (2.0 * cell), c.x) * wet;
}

void main(void)
{
    // the background is drawn with v from 1 at its top, as the blur's passes are
    vec2 p = origin + vec2(uv.x, 1.0 - uv.y) * area;
    vec3 ripple = surface(ripples, ripplesCell, p);
    vec2 s = gain.x * ripple.xy;
    float swellHeight = 0.0;
    if (gain.y != 0.0) {
        vec3 sloshed = surface(swell, swellCell, p);
        s += gain.y * sloshed.xy;
        swellHeight = sloshed.z / gain.w;
    }
    fragColor = vec4(s, ripple.z / gain.z, swellHeight);
}
