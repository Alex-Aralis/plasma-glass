#version 140

#include "sdf.glsl"

// plasma-glass: one step of the liquid in a Liquid Glass window (KRunner's): linear shallow water on a
// staggered grid, worked forward then back (the faces' new velocities from the old heights, then the new
// heights from those velocities), which keeps waves stable while c dt / cell stays under 1/sqrt(2). Each
// texel is a cell: its height (px), the velocity on its right face and on its bottom face (px/s), and 1 if
// it holds liquid. Cell (i, j) sits at ((i - 0.5) cell, (j - 0.5) cell) in the glass (y down), so row and
// column 0 lie outside it. The liquid's edge, its shore, runs a little in from the glass's rim in gentle
// bends, so the waves it sends off and sends back aren't ruler-straight; every shore is a face between a
// dry cell and a wet one. Dry cells stay at rest; a cell the glass has just grown over starts at the level
// of the nearest liquid above it or to its left (the glass grows down and to the right), so no step is left
// to ring. Its floor isn't flat either: waves run faster where the liquid is deeper (c^2 goes with the
// depth), so their fronts bend as they cross, as on a real shore. The shore holds the liquid in, except
// where the busy push pushes it in; the glass's acceleration (its centre's, so growing counts too) pushes
// the liquid the other way (momentum); and while busy a breeze, gusts pressing here and there that come
// and go, raises small waves all over.

uniform sampler2D state;
uniform vec2 glass;        // the glass's size, logical px
uniform vec4 corners;      // and its corners' radii: top left, top right, bottom left, bottom right
uniform float cell;        // logical px a cell
uniform vec4 timing;       // dt (s), c^2 (px^2/s^2), diffusion (px^2/s), how fast the level settles (1/s)
uniform vec4 damping;      // the faces' velocities fade at these rates (1/s): the left and right faces', the
                           // top and bottom faces'; and in the rim's band up to this much more (the sponge,
                           // 1/s), over this many px in from the rim
uniform vec2 accel;        // px/s^2: what the glass's acceleration does to the liquid (minus it, scaled)
uniform vec4 push;         // the busy push: its side (0 left, 1 right, 2 top, 3 bottom; -1 none), the px
                           // along it it peaks at, half the stretch that moves as one (px), and how fast it
                           // moves in there now (px/s)
uniform vec4 press;        // or a press on the surface: its centre (px), radius (px), and pressure
                           // (px^2/s^2, as c^2 times the height it would push down by)
uniform vec4 click;        // a click's press, the same way
uniform float clickFinger; // and how much of the way down to its resting dent it pushes the surface this step
uniform vec3 breeze;       // how hard the breeze's gusts press (px^2/s^2; 0: none), how big they are (px),
                           // and the time in their turns (they come and go once a turn)
uniform vec4 shore;        // the shore: how far in from the rim it runs on average and how far it wanders
                           // either way (px), how long its bends are (px), and a seed for their shape
uniform vec3 bed;          // the floor: how much deeper or shallower it gets (0..1 of the average), how long
                           // its swells are (px), and a seed for their shape

out vec4 fragColor;

vec4 fetch(ivec2 c)
{
    ivec2 n = textureSize(state, 0);
    if (c.x < 0 || c.y < 0 || c.x >= n.x || c.y >= n.y) {
        return vec4(0.0); // past a texture that has just grown: dry
    }
    return texelFetch(state, c, 0);
}

float rim(vec2 p)
{
    return sdfRoundedBox(p, glass * 0.5, glass * 0.5, corners);
}

vec2 centre(ivec2 c)
{
    return (vec2(c) - 0.5) * cell;
}

// gradient noise in space and time, about -0.5..0.5: smooth gusts without the lattice's squares that value
// noise shows
vec3 hash33(vec3 p)
{
    p = fract(p * vec3(0.1031, 0.1030, 0.0973));
    p += dot(p, p.yxz + 33.33);
    return fract((p.xxy + p.yxx) * p.zyx) * 2.0 - 1.0;
}

float gnoise(vec3 x)
{
    vec3 i = floor(x);
    vec3 f = x - i;
    vec3 u = f * f * f * (f * (f * 6.0 - 15.0) + 10.0);
    float n000 = dot(hash33(i), f);
    float n100 = dot(hash33(i + vec3(1.0, 0.0, 0.0)), f - vec3(1.0, 0.0, 0.0));
    float n010 = dot(hash33(i + vec3(0.0, 1.0, 0.0)), f - vec3(0.0, 1.0, 0.0));
    float n110 = dot(hash33(i + vec3(1.0, 1.0, 0.0)), f - vec3(1.0, 1.0, 0.0));
    float n001 = dot(hash33(i + vec3(0.0, 0.0, 1.0)), f - vec3(0.0, 0.0, 1.0));
    float n101 = dot(hash33(i + vec3(1.0, 0.0, 1.0)), f - vec3(1.0, 0.0, 1.0));
    float n011 = dot(hash33(i + vec3(0.0, 1.0, 1.0)), f - vec3(0.0, 1.0, 1.0));
    float n111 = dot(hash33(i + vec3(1.0, 1.0, 1.0)), f - vec3(1.0, 1.0, 1.0));
    return mix(mix(mix(n000, n100, u.x), mix(n010, n110, u.x), u.y), mix(mix(n001, n101, u.x), mix(n011, n111, u.x), u.y), u.z);
}

// a smooth pattern over the glass, -1..1 or so, in bends about `size` px long: three plane waves at odd
// angles and lengths, shifted by `seed` (cheap, and with no lattice to show)
float pattern(vec2 p, float size, float seed)
{
    vec2 q = p / size * 6.2831853;
    return 0.55 * sin(dot(q, vec2(0.83, 0.56)) + seed)
         + 0.35 * sin(dot(q, vec2(-0.48, 1.31)) + 2.3 * seed + 1.1)
         + 0.25 * sin(dot(q, vec2(1.62, -0.37)) + 3.7 * seed + 2.9);
}

// how far p is past the liquid's edge (negative in the liquid): the rim moved in by shore.x, wandering by
// up to about shore.y either way
float shoreline(vec2 p)
{
    return rim(p) + shore.x + shore.y * pattern(p, shore.z, shore.w);
}

// which side of the glass p is nearest: 0 left, 1 right, 2 top, 3 bottom
float nearestSide(vec2 p)
{
    vec4 d = vec4(p.x, glass.x - p.x, p.y, glass.y - p.y);
    float side = 0.0;
    float best = d.x;
    if (d.y < best) {
        best = d.y;
        side = 1.0;
    }
    if (d.z < best) {
        best = d.z;
        side = 2.0;
    }
    if (d.w < best) {
        side = 3.0;
    }
    return side;
}

// how far side `side` moves in at the shore's face p: the busy push bows it in, most at push.y along it, not
// at all at its ends; the stretch push.z either side of its peak moves as one. Only the stretch of shore
// along that side moves (its bends may face another way here and there).
float pushed(float side, vec2 p)
{
    if (abs(side - push.x) > 0.5 || abs(nearestSide(p) - side) > 0.5) {
        return 0.0;
    }
    float s = side < 1.5 ? p.y : p.x;
    float len = side < 1.5 ? glass.y : glass.x;
    float sw = s - clamp(s - push.y, -push.z, push.z);
    float a = clamp(push.y / len, 0.02, 0.98);
    float f = sin(3.14159265 * pow(clamp(sw / len, 0.0, 1.0), log(0.5) / log(a)));
    return push.w * f * f;
}

// what presses on the surface at p (px^2/s^2): the press, a click, and the breeze
float pressure(vec2 p)
{
    float sum = 0.0;
    if (press.w != 0.0) {
        vec2 d = (p - press.xy) / press.z;
        sum += press.w * exp(-dot(d, d));
    }
    if (click.w != 0.0) {
        vec2 d = (p - click.xy) / click.z;
        sum += click.w * exp(-dot(d, d));
    }
    if (breeze.x != 0.0) {
        sum += breeze.x * gnoise(vec3(p / breeze.y, breeze.z));
    }
    return sum;
}

// how deep the floor is at p against the average: 1 +- bed.x
float depth(vec2 p)
{
    return 1.0 + bed.x * pattern(p, bed.y, bed.z) / 1.15;
}

// a face's new velocity: between cells a and b (b to the right of a or below it), along `axis` (0 x, 1 y),
// its old velocity `v`, the heights, pressures, shorelines (wet where under 0) and depths either side
float face(ivec2 a, ivec2 b, int axis, float v, float ha, float hb, float pa, float pb, float sa, float sb, float da, float db)
{
    bool wa = sa < 0.0;
    bool wb = sb < 0.0;
    vec2 p = 0.5 * (centre(a) + centre(b)); // the face's middle
    if (wa && wb) {
        float dt = timing.x;
        float force = -timing.y * 0.5 * (da + db) * (hb - ha) / cell - (pb - pa) / cell + (axis == 0 ? accel.x : accel.y);
        float sponge = damping.z * pow(clamp(1.0 + 0.5 * (sa + sb) / damping.w, 0.0, 1.0), 2.0);
        return (v + dt * force) * exp(-((axis == 0 ? damping.x : damping.y) + sponge) * dt);
    }
    if (wa == wb) {
        return 0.0; // dry on both sides
    }
    // the shore: the liquid follows its side where the push moves it (positive: towards +x or +y)
    if (axis == 0) {
        return wb ? pushed(0.0, p) // the left side, liquid to its right
                  : -pushed(1.0, p);
    }
    return wb ? pushed(2.0, p) // the top, liquid below
              : -pushed(3.0, p);
}

// how much a dragged click's finger pushes the surface down at cell q this step: towards the press's resting
// dent (as deep as at the press's centre, dPress), from q's height hq as the step began (so every cell can
// tell how much the finger pushes away), firmest at its middle (g^3: pushed as hard across its whole width, a
// fast drag left a ripple per step in the trench behind it)
float pushedAt(ivec2 q, float hq, float dPress)
{
    vec2 d = (centre(q) - click.xy) / click.z;
    float g = exp(-dot(d, d));
    float dent = -click.w * g / (timing.y * dPress);
    return max(hq - dent, 0.0) * clickFinger * g * g * g;
}

// a cell's state (wet: whether it holds liquid now); if the glass has just grown over it, at the level of
// the nearest liquid above it or to its left (up to 32 cells off: the glass grows less than that in a
// frame), at rest
vec4 cellAt(ivec2 c, bool wet)
{
    vec4 s = fetch(c);
    if (s.w > 0.0 || !wet) {
        return s;
    }
    for (int k = 1; k <= 32; ++k) {
        vec4 t = fetch(c - ivec2(0, k));
        if (t.w > 0.0) {
            return vec4(t.x, 0.0, 0.0, 0.0);
        }
        t = fetch(c - ivec2(k, 0));
        if (t.w > 0.0) {
            return vec4(t.x, 0.0, 0.0, 0.0);
        }
    }
    return vec4(0.0);
}

void main(void)
{
    ivec2 c = ivec2(gl_FragCoord.xy);
    // the shoreline here and at the four neighbours, once (it's two noises each)
    float sHere = shoreline(centre(c));
    if (sHere >= 0.0) {
        fragColor = vec4(0.0); // dry
        return;
    }
    float sLeft = shoreline(centre(c - ivec2(1, 0)));
    float sRight = shoreline(centre(c + ivec2(1, 0)));
    float sAbove = shoreline(centre(c - ivec2(0, 1)));
    float sBelow = shoreline(centre(c + ivec2(0, 1)));
    float dHere = depth(centre(c));
    vec4 here = cellAt(c, true);
    vec4 left = cellAt(c - ivec2(1, 0), sLeft < 0.0);
    vec4 right = cellAt(c + ivec2(1, 0), sRight < 0.0);
    vec4 above = cellAt(c - ivec2(0, 1), sAbove < 0.0);
    vec4 below = cellAt(c + ivec2(0, 1), sBelow < 0.0);

    float p = pressure(centre(c));
    float uR = face(c, c + ivec2(1, 0), 0, here.y, here.x, right.x, p, pressure(centre(c + ivec2(1, 0))), sHere, sRight,
                    dHere, depth(centre(c + ivec2(1, 0))));
    float uL = face(c - ivec2(1, 0), c, 0, left.y, left.x, here.x, pressure(centre(c - ivec2(1, 0))), p, sLeft, sHere,
                    depth(centre(c - ivec2(1, 0))), dHere);
    float vB = face(c, c + ivec2(0, 1), 1, here.z, here.x, below.x, p, pressure(centre(c + ivec2(0, 1))), sHere, sBelow,
                    dHere, depth(centre(c + ivec2(0, 1))));
    float vT = face(c - ivec2(0, 1), c, 1, above.z, above.x, here.x, pressure(centre(c - ivec2(0, 1))), p, sAbove, sHere,
                    depth(centre(c - ivec2(0, 1))), dHere);

    float dt = timing.x;
    float h = here.x - dt * ((uR - uL) + (vB - vT)) / cell;
    // a little diffusion among wet cells, which only the shortest waves (a few cells) feel
    float lap = 0.0;
    lap += sLeft < 0.0 ? left.x - here.x : 0.0;
    lap += sRight < 0.0 ? right.x - here.x : 0.0;
    lap += sAbove < 0.0 ? above.x - here.x : 0.0;
    lap += sBelow < 0.0 ? below.x - here.x : 0.0;
    h += dt * timing.z * lap / (cell * cell);
    // and the level settles back to rest (what the push leaves, or a cell the glass grew over)
    h *= exp(-timing.w * dt);
    // a dragged click presses like a finger as well (clickFinger: only as it outruns the waves): under it the
    // surface goes down to the dent its pressure holds at rest at once, not only as fast as the liquid can flow
    // away, so the dent keeps up with the pointer; it never lifts the surface. The liquid it pushes down goes
    // out to a ring two press widths round it, as a finger pushes liquid aside, and runs off from there as the
    // wake (taken away instead, the wake hardly showed through Liquid Glass Light's frost, and the rings a
    // fast press sends off as it stops stood out alone)
    if (click.w != 0.0 && clickFinger > 0.0) {
        float dPress = depth(click.xy);
        h -= pushedAt(c, here.x, dPress);
        float r = length(centre(c) - click.xy) / click.z;
        float ring = exp(-pow((r - 2.0) / 0.6, 2.0));
        if (ring > 1e-3) {
            // all it pushes away this step: the cells within 1.75 press widths (g^3 is under 1e-4 past that),
            // at most 24 a side, each sample standing for a stride x stride block
            float reach = 1.75 * click.z;
            int stride = max(1, int(ceil(2.0 * reach / cell / 24.0)));
            ivec2 lo = ivec2(floor((click.xy - reach) / cell + 0.5));
            ivec2 hi = ivec2(ceil((click.xy + reach) / cell + 0.5));
            float pushed = 0.0;
            for (int qy = lo.y; qy <= hi.y; qy += stride) {
                for (int qx = lo.x; qx <= hi.x; qx += stride) {
                    vec4 sq = fetch(ivec2(qx, qy));
                    if (sq.w > 0.0) {
                        pushed += pushedAt(ivec2(qx, qy), sq.x, dPress);
                    }
                }
            }
            // spread over the ring's cells (its area: 2 pi 2 0.6 sqrt(pi) radius^2)
            float ringCells = 2.0 * 3.14159265 * 2.0 * 0.6 * 1.7724539 * click.z * click.z / (cell * cell);
            h += pushed * float(stride * stride) * ring / ringCells;
        }
    }
    fragColor = vec4(h, uR, vB, 1.0);
}
