#!/usr/bin/env python3
"""Generates the Liquid Glass Plasma Styles: Breeze everywhere, with glassy popups.

Two styles come out of one run: "Liquid Glass" (follows your colour scheme) next to this file, and
"Liquid Glass Light" (bright frosted glass with its own light colours) in ../liquid-glass-light.

Drawn here: dialogs/background (KRunner, Kickoff, the calendar and other popups) and the popups'
scrollbars, search fields, list highlights and header bands; every other element falls back to the
default Breeze style. Base colours follow the active colour scheme.

Plasma measures each element by its bounding box, so every piece is built from fills that stay
inside an exact tile rectangle (no strokes, which would grow the box by half a pixel and misalign
the frame). Re-run after changing the parameters, then reselect the style or restart krunner.
"""

import gzip
import json
from pathlib import Path

HERE = Path(__file__).resolve().parent

R = 26                  # corner radius (logical px); also the corner tile size
MARGIN = 12             # padding between the frame edge and the content
SHADOW = 40             # how far the shadow reaches beyond the frame
SHADOW_ALPHA = 0.24
FILL_TRANSLUCENT = 0.40  # glass tint over KWin's blur
FILL_OPAQUE = 0.94       # compositing without blur
RIM = {"top": 0.34, "side": 0.18, "bottom": 0.12}    # 1px specular edge (white), visible all round
GLOW = {"top": 0.12, "side": 0.05, "bottom": 0.06}   # inner light band, fading inwards
GLOW_DEPTH = 14          # px the inner band reaches into the glass

C = R
K = 32                   # edge/centre tile length (stretched)
T = SHADOW + C           # shadow tile thickness: SHADOW outside, C under the corner

_defs = []


def gradient(kind, gid, stops, **attrs):
    a = " ".join(f'{k.replace("_", "-")}="{v}"' for k, v in attrs.items())
    s = "".join(f'<stop offset="{o:.4f}" stop-color="{c}" stop-opacity="{op:.4f}"/>' for o, c, op in stops)
    _defs.append(f'<{kind}Gradient id="{gid}" gradientUnits="userSpaceOnUse" {a}>{s}</{kind}Gradient>')
    return f"url(#{gid})"


def ease(alpha, start=0.0, end=1.0, color="#fff", steps=8, power=2.0, reverse=False):
    """Stops fading `alpha` -> 0 between offsets start..end (or 0 -> alpha if reverse)."""
    out = []
    for i in range(steps + 1):
        t = i / steps
        a = alpha * (1 - t) ** power
        out.append((start + (end - start) * t, color, a))
    if reverse:
        out = [(start + end - o, c, a) for o, c, a in reversed(out)]
    return out


def tile(name, x, y, w, h, body):
    # The transparent rect pins the element's bounding box to exactly w x h.
    return f'<g id="{name}" transform="translate({x},{y})"><rect width="{w}" height="{h}" fill="none"/>{body}</g>'


def frame(x0, prefix, fill_opacity, glass=True, mask=False):
    """The nine frame pieces at (x0, 0). Mask pieces are plain solid shapes (the blur region)."""
    bg = 'fill="#000"' if mask else f'class="ColorScheme-Background" style="fill:currentColor;fill-opacity:{fill_opacity}"'
    pieces = []

    def corner(name, ox, oy, cx, cy, sweep_start, sweep_end, rim, edge):
        # quarter disc centred on (cx, cy) inside a C x C tile; edge: "top" or "bottom"
        disc = f'M{cx},{cy} L{sweep_start[0]},{sweep_start[1]} A{C},{C} 0 0 1 {sweep_end[0]},{sweep_end[1]} Z'
        body = f'<path d="{disc}" {bg}/>'
        if glass and not mask:
            # Inner glow: a radial band at the weaker neighbouring edge's strength, plus the stronger
            # edge's extra as that edge's own straight band, so the corner meets both edge tiles
            # without a step (one radial band at the top's strength left one where it met the side).
            side, other = GLOW["side"], GLOW[edge]
            base = min(side, other)
            gid = f"{prefix}g-{name}"
            start = (C - 1 - GLOW_DEPTH) / C  # same falloff as the edges: from 1 px in, GLOW_DEPTH deep
            stops = [(0, "#fff", 0), (start, "#fff", 0)] + ease(base, start, (C - 1) / C, reverse=True)
            body += f'<path d="{disc}" fill="{gradient("radial", gid, stops, cx=cx, cy=cy, r=C)}"/>'
            gy = 1 if edge == "top" else C - 1  # where the edge bands start, 1 px inside the frame
            gx = 1 if "left" in name else C - 1
            dy = GLOW_DEPTH if edge == "top" else -GLOW_DEPTH
            dx = GLOW_DEPTH if "left" in name else -GLOW_DEPTH
            for strength, axis, suffix in ((other, (0, gy, 0, gy + dy), "h"), (side, (gx, 0, gx + dx, 0), "v")):
                if strength > base:
                    extra = ease((strength - base) / (1 - base), 0, 1)  # composites to `strength` at the edge
                    x1, y1, x2, y2 = axis
                    body += f'<path d="{disc}" fill="{gradient("linear", gid + suffix, extra, x1=x1, y1=y1, x2=x2, y2=y2)}"/>'
            # 1px rim: ring between radius C-1 and C, as a filled shape
            (sx, sy), (ex, ey) = sweep_start, sweep_end
            ix, iy = cx + (sx - cx) * (C - 1) / C, cy + (sy - cy) * (C - 1) / C
            jx, jy = cx + (ex - cx) * (C - 1) / C, cy + (ey - cy) * (C - 1) / C
            ring = f'M{sx},{sy} A{C},{C} 0 0 1 {ex},{ey} L{jx},{jy} A{C - 1},{C - 1} 0 0 0 {ix},{iy} Z'
            rid = f"{prefix}r-{name}"
            # rim brightness blends from one neighbouring edge to the other along the arc
            rim_grad = gradient("linear", rid, [(0, "#fff", rim[0]), (1, "#fff", rim[1])], x1=sx, y1=sy, x2=ex, y2=ey)
            body += f'<path d="{ring}" fill="{rim_grad}"/>'
        pieces.append(tile(prefix + name, x0 + ox, oy, C, C, body))

    # corner centres sit at the tile's inner corner
    corner("topleft", 0, 0, C, C, (0, C), (C, 0), (RIM["side"], RIM["top"]), "top")
    corner("topright", C + K, 0, 0, C, (0, 0), (C, C), (RIM["top"], RIM["side"]), "top")
    corner("bottomright", C + K, C + K, 0, 0, (C, 0), (0, C), (RIM["side"], RIM["bottom"]), "bottom")
    corner("bottomleft", 0, C + K, C, 0, (C, C), (0, 0), (RIM["bottom"], RIM["side"]), "bottom")

    def edge(name, ox, oy, w, h, side, rim_rect, glow_axis):
        body = f'<rect width="{w}" height="{h}" {bg}/>'
        if glass and not mask:
            key = "top" if name == "top" else "bottom" if name == "bottom" else "side"
            gid = f"{prefix}g-{name}"
            x1, y1, x2, y2 = glow_axis
            body += f'<rect width="{w}" height="{h}" fill="{gradient("linear", gid, ease(GLOW[key], 0, 1), x1=x1, y1=y1, x2=x2, y2=y2)}"/>'
            rx, ry, rw, rh = rim_rect
            body += f'<rect x="{rx}" y="{ry}" width="{rw}" height="{rh}" fill="#fff" fill-opacity="{RIM[key]}"/>'
        pieces.append(tile(prefix + name, x0 + ox, oy, w, h, body))

    edge("top", C, 0, K, C, "top", (0, 0, K, 1), (0, 1, 0, 1 + GLOW_DEPTH))
    edge("bottom", C, C + K, K, C, "bottom", (0, C - 1, K, 1), (0, C - 1, 0, C - 1 - GLOW_DEPTH))
    edge("left", 0, C, C, K, "side", (0, 0, 1, K), (1, 0, 1 + GLOW_DEPTH, 0))
    edge("right", C + K, C, C, K, "side", (C - 1, 0, 1, K), (C - 1, 0, C - 1 - GLOW_DEPTH, 0))
    pieces.append(tile(prefix + "center", x0 + C, C, K, K, f'<rect width="{K}" height="{K}" {bg}/>'))
    return "".join(pieces)


def shadow(x0):
    """Soft shadow outside the frame only, so the glass itself is never darkened from below."""
    pieces = []

    ring0 = R / (R + SHADOW)
    ring = [(0, "#000", 0), (ring0 - 1e-4, "#000", 0)] + ease(SHADOW_ALPHA, ring0, 1, color="#000", power=2.4)
    edge = ease(SHADOW_ALPHA, 0, 1, color="#000", power=2.4)

    def corner(name, ox, oy, cx, cy):
        fill = gradient("radial", f"s-{name}", ring, cx=cx, cy=cy, r=R + SHADOW)
        pieces.append(tile(f"shadow-{name}", x0 + ox, oy, T, T, f'<rect width="{T}" height="{T}" fill="{fill}"/>'))

    def side(name, ox, oy, w, h, shade_rect, axis):
        x1, y1, x2, y2 = axis
        fill = gradient("linear", f"s-{name}", edge, x1=x1, y1=y1, x2=x2, y2=y2)
        sx, sy, sw, sh = shade_rect
        pieces.append(tile(f"shadow-{name}", x0 + ox, oy, w, h, f'<rect x="{sx}" y="{sy}" width="{sw}" height="{sh}" fill="{fill}"/>'))

    corner("topleft", 0, 0, T, T)
    corner("topright", T + K, 0, 0, T)
    corner("bottomleft", 0, T + K, T, 0)
    corner("bottomright", T + K, T + K, 0, 0)
    side("top", T, 0, K, T, (0, 0, K, SHADOW), (0, SHADOW, 0, 0))
    side("bottom", T, T + K, K, T, (0, C, K, SHADOW), (0, C, 0, T))
    side("left", 0, T, T, K, (0, 0, SHADOW, K), (SHADOW, 0, 0, 0))
    side("right", T + K, T, T, K, (C, 0, SHADOW, K), (C, 0, T, 0))
    pieces.append(tile("shadow-center", x0 + T, T, K, K, ""))
    return "".join(pieces)


def hints(y0):
    h, x = [], 0

    def rect(id_, w, hh):
        nonlocal x
        h.append(f'<rect id="{id_}" x="{x}" y="{y0}" width="{w}" height="{hh}" fill="#f0f"/>')
        x += max(w, 4) + 4

    rect("hint-stretch-borders", 4, 4)  # stretch edges instead of tiling them
    for s in ("top", "bottom"):
        rect(f"hint-{s}-margin", 4, MARGIN)
        # the glass starts at the frame edge (the shadow is outside, drawn by KWin). Breeze declares its
        # zero insets too; without them PlasmoidHeading falls back to sizing itself from its own
        # position, which loops (plasmashell warns as popups are torn down)
        rect(f"hint-{s}-inset", 4, 0.001)
    for s in ("left", "right"):
        rect(f"hint-{s}-margin", MARGIN, 4)
        rect(f"hint-{s}-inset", 0.001, 4)
    for s in ("top", "bottom"):
        rect(f"shadow-hint-{s}-margin", 4, SHADOW)
        rect(f"shadow-hint-{s}-inset", 4, SHADOW)
    for s in ("left", "right"):
        rect(f"shadow-hint-{s}-margin", SHADOW, 4)
        rect(f"shadow-hint-{s}-inset", SHADOW, 4)
    return "".join(h), x


def svg(fill_opacity, glass=True, with_shadow=True):
    _defs.clear()
    span = 2 * C + K
    body = frame(0, "", fill_opacity, glass=glass)
    body += frame(span + 10, "mask-", 1, mask=True)
    if with_shadow:
        body += shadow(2 * (span + 10))
    hint_xml, hint_w = hints(2 * T + K + 10)
    body += hint_xml
    width = max(2 * (span + 10) + 2 * T + K, hint_w) + 10
    height = 2 * T + K + 10 + SHADOW + 10
    style = ('<style type="text/css" id="current-color-scheme">'
             '.ColorScheme-Background{color:#202326;}.ColorScheme-Text{color:#fcfcfc;}</style>')
    return (f'<svg xmlns="http://www.w3.org/2000/svg" width="{width}" height="{height}" viewBox="0 0 {width} {height}">'
            f'<defs>{style}{"".join(_defs)}</defs>{body}</svg>')


# Scrollbar: Breeze's geometry (6px thick, 3px pill caps, same inset hints) with glassy paint.
SB = 3                   # cap radius / tile size
SB_SLIDER = 0.32         # handle opacity (text colour, so it adapts to light and dark schemes)
SB_HOVER = 0.55
SB_TRACK = 0.07


def scrollbar_svg():
    _defs.clear()
    parts, y = [], 0

    def pill_frame(prefix, x0, y0, opacity):
        fill = f'class="ColorScheme-Text" style="fill:currentColor;fill-opacity:{opacity}"'
        r, k = SB, SB
        caps = {
            "topleft": f'M{r},{r} L0,{r} A{r},{r} 0 0 1 {r},0 Z',
            "topright": f'M0,{r} L0,0 A{r},{r} 0 0 1 {r},{r} Z',
            "bottomright": f'M0,0 L{r},0 A{r},{r} 0 0 1 0,{r} Z',
            "bottomleft": f'M{r},0 L{r},{r} A{r},{r} 0 0 1 0,0 Z',
        }
        pos = {"topleft": (0, 0), "top": (r, 0), "topright": (r + k, 0), "left": (0, r), "center": (r, r),
               "right": (r + k, r), "bottomleft": (0, r + k), "bottom": (r, r + k), "bottomright": (r + k, r + k)}
        for name, (x, yy) in pos.items():
            w = k if name in ("top", "center", "bottom") else r
            h = k if name in ("left", "center", "right") else r
            body = f'<path d="{caps[name]}" {fill}/>' if name in caps else f'<rect width="{w}" height="{h}" {fill}/>'
            parts.append(tile(f"{prefix}-{name}", x0 + x, y0 + yy, w, h, body))
        parts.append(f'<rect id="{prefix}-hint-top-inset" x="{x0 + 20}" y="{y0}" width="3" height="6" fill="#0f0"/>')
        parts.append(f'<rect id="{prefix}-hint-left-inset" x="{x0 + 26}" y="{y0}" width="6" height="3" fill="#0f0"/>')

    for i, (prefix, op) in enumerate((("slider", SB_SLIDER), ("mouseover-slider", SB_HOVER),
                                      ("background-vertical", SB_TRACK), ("background-horizontal", SB_TRACK))):
        pill_frame(prefix, 0, i * 14, op)
    parts.append('<rect id="hint-scrollbar-size" x="40" y="0" width="6" height="6" fill="#f0f"/>')
    parts.append('<rect id="hint-stretch-borders" x="40" y="10" width="2" height="2" fill="#f60"/>')
    style = ('<style type="text/css" id="current-color-scheme">'
             '.ColorScheme-Background{color:#202326;}.ColorScheme-Text{color:#fcfcfc;}</style>')
    return (f'<svg xmlns="http://www.w3.org/2000/svg" width="50" height="60" viewBox="0 0 50 60">'
            f'<defs>{style}</defs>{"".join(parts)}</svg>')


# ---------------------------------------------------------------------------- simple glass frames

def glass_frame(prefix, x0, y0, r, fill=None, rim=None, rim_w=1, k=16):
    """Nine stroke-free tiles of a rounded rectangle in the text colour: optional fill and rim opacity."""
    paint = lambda op: f'class="ColorScheme-Text" style="fill:currentColor;fill-opacity:{op}"'
    centres = {"topleft": (r, r, (0, r), (r, 0)), "topright": (0, r, (0, 0), (r, r)),
               "bottomright": (0, 0, (r, 0), (0, r)), "bottomleft": (r, 0, (r, r), (0, 0))}
    pos = {"topleft": (0, 0), "top": (r, 0), "topright": (r + k, 0), "left": (0, r), "center": (r, r),
           "right": (r + k, r), "bottomleft": (0, r + k), "bottom": (r, r + k), "bottomright": (r + k, r + k)}
    rims = {"top": (0, 0, k, rim_w), "bottom": (0, r - rim_w, k, rim_w), "left": (0, 0, rim_w, k), "right": (r - rim_w, 0, rim_w, k)}
    out = []
    for name, (x, y) in pos.items():
        w = k if name in ("top", "center", "bottom") else r
        h = k if name in ("left", "center", "right") else r
        body = ""
        if name in centres:
            cx, cy, (sx, sy), (ex, ey) = centres[name]
            if fill:
                body += f'<path d="M{cx},{cy} L{sx},{sy} A{r},{r} 0 0 1 {ex},{ey} Z" {paint(fill)}/>'
            if rim:
                ri = r - rim_w
                ix, iy = cx + (sx - cx) * ri / r, cy + (sy - cy) * ri / r
                jx, jy = cx + (ex - cx) * ri / r, cy + (ey - cy) * ri / r
                body += (f'<path d="M{sx},{sy} A{r},{r} 0 0 1 {ex},{ey} L{jx},{jy} A{ri},{ri} 0 0 0 {ix},{iy} Z" '
                         f'{paint(rim)}/>')
        else:
            if fill:
                body += f'<rect width="{w}" height="{h}" {paint(fill)}/>'
            if rim and name in rims:
                rx, ry, rw, rh = rims[name]
                body += f'<rect x="{rx}" y="{ry}" width="{rw}" height="{rh}" {paint(rim)}/>'
        out.append(tile(f"{prefix}-{name}", x0 + x, y0 + y, w, h, body))
    return "".join(out)


HEADING = {"band": 0.04, "line": 0.10}  # PlasmoidHeading: a quiet tint and a hairline (text colour)
def heading_svg():
    """widgets/plasmoidheading: the header (and footer) band of applet popups. It spans the popup to its
    frame edge, so it takes the glass's corner radius on the outer side, a hairline on the inner side
    and margins equal to the popup's."""
    paint = lambda op: f'class="ColorScheme-Text" style="fill:currentColor;fill-opacity:{op}"'
    r, k, band, line = R, K, HEADING["band"], HEADING["line"]
    parts = ['<rect id="hint-stretch-borders" x="0" y="0" width="2" height="2" fill="#f60"/>']

    def quarter(cx, cy, sx, sy, ex, ey):
        return f'<path d="M{cx},{cy} L{sx},{sy} A{r},{r} 0 0 1 {ex},{ey} Z" {paint(band)}/>'

    def piece(prefix, name, x, y, w, h, body):
        parts.append(tile(f"{prefix}-{name}", x, y, w, h, body))

    for prefix, y0, flip in (("header", 10, False), ("footer", 10 + r + k + 10, True)):
        x0 = 0
        # rows from the outer edge inwards: rounded corners + band, stretchable band, hairline
        outer_y, mid_y, line_y = (y0 + 1 + k, y0 + 1, y0) if flip else (y0, y0 + r, y0 + r + k)
        o, i = ("bottom", "top") if flip else ("top", "bottom")
        if flip:
            piece(prefix, "bottomleft", x0, outer_y, r, r, quarter(r, 0, r, r, 0, 0))
            piece(prefix, "bottomright", x0 + r + k, outer_y, r, r, quarter(0, 0, r, 0, 0, r))
        else:
            piece(prefix, "topleft", x0, outer_y, r, r, quarter(r, r, 0, r, r, 0))
            piece(prefix, "topright", x0 + r + k, outer_y, r, r, quarter(0, r, 0, 0, r, r))
        piece(prefix, o, x0 + r, outer_y, k, r, f'<rect width="{k}" height="{r}" {paint(band)}/>')
        for name, x, w in (("left", x0, r), ("center", x0 + r, k), ("right", x0 + r + k, r)):
            piece(prefix, name, x, mid_y, w, k, f'<rect width="{w}" height="{k}" {paint(band)}/>')
        for name, x, w in ((f"{i}left", x0, r), (i, x0 + r, k), (f"{i}right", x0 + r + k, r)):
            piece(prefix, name, x, line_y, w, 1, f'<rect width="{w}" height="1" {paint(line)}/>')
        parts.append(margins(prefix, x0 + 2 * r + k + 10, y0, MARGIN, MARGIN, MARGIN, MARGIN))
    return standalone(parts, 2 * r + k + 30, 2 * (r + k + 1) + 40)


def margins(prefix, x0, y0, top, bottom, left, right):
    # a zero-sized rect is not an element at all, so "no margin" is a sliver (as in Breeze)
    top, bottom, left, right = (v if v else 0.001 for v in (top, bottom, left, right))
    return (f'<rect id="{prefix}-hint-top-margin" x="{x0}" y="{y0}" width="2" height="{top}" fill="#f0f"/>'
            f'<rect id="{prefix}-hint-bottom-margin" x="{x0 + 4}" y="{y0}" width="2" height="{bottom}" fill="#f0f"/>'
            f'<rect id="{prefix}-hint-left-margin" x="{x0 + 8}" y="{y0}" width="{left}" height="2" fill="#f0f"/>'
            f'<rect id="{prefix}-hint-right-margin" x="{x0 + 8}" y="{y0 + 4}" width="{right}" height="2" fill="#f0f"/>')


def standalone(parts, width, height):
    style = ('<style type="text/css" id="current-color-scheme">'
             '.ColorScheme-Background{color:#202326;}.ColorScheme-Text{color:#fcfcfc;}</style>')
    return (f'<svg xmlns="http://www.w3.org/2000/svg" width="{width}" height="{height}" viewBox="0 0 {width} {height}">'
            f'<defs>{style}</defs>{"".join(parts)}</svg>')


# Search/text fields: translucent well with a hairline rim; brighter rim and a soft halo on focus.
LE_R = 10
FIELD = {"base_fill": 0.06, "base_rim": 0.08, "hover": 0.16, "focus": 0.28, "halo": 0.06}
def lineedit_svg():
    ff = LE_R + 2  # the focus halo sits 2px outside the field
    parts = [
        glass_frame("base", 0, 0, LE_R, fill=FIELD["base_fill"], rim=FIELD["base_rim"]),
        margins("base", 200, 0, 6, 6, 9, 9),
        glass_frame("hover", 0, 60, LE_R, rim=FIELD["hover"]),
        margins("hover", 200, 60, 0, 0, 0, 0),
        glass_frame("focus", 0, 120, LE_R, rim=FIELD["focus"]),
        margins("focus", 200, 120, 0, 0, 0, 0),
        glass_frame("focusframe", 0, 180, ff, rim=FIELD["halo"], rim_w=2),
        margins("focusframe", 200, 180, 2, 2, 2, 2),
        '<rect id="hint-focus-over-base" x="220" y="0" width="2" height="2" fill="#f60"/>',
        '<rect id="hint-stretch-borders" x="220" y="6" width="2" height="2" fill="#f60"/>',
    ]
    return standalone(parts, 240, 250)


# List highlights (KRunner results, Kickoff, menus in popups): frosted pills instead of blue.
VI_R = 12
HIGHLIGHT = {"hover": 0.06, "selected": 0.12, "selected+hover": 0.15}
def viewitem_svg():
    parts = [
        glass_frame("normal", 0, 0, VI_R),
        glass_frame("hover", 0, 50, VI_R, fill=HIGHLIGHT["hover"]),
        glass_frame("selected", 0, 100, VI_R, fill=HIGHLIGHT["selected"]),
        glass_frame("selected+hover", 0, 150, VI_R, fill=HIGHLIGHT["selected+hover"]),
        '<rect id="hint-stretch-borders" x="60" y="0" width="2" height="2" fill="#f60"/>',
    ]
    return standalone(parts, 80, 200)


# ---------------------------------------------------------------------------- variants

# Plasma colours for the light style, on top of Breeze Light: macOS-like near-white glass and
# near-black text. Only Plasma (panel, popups, KRunner) uses these; apps keep your colour scheme.
LIGHT_COLORS = {
    "Colors:Window": {"BackgroundNormal": "245,245,247", "BackgroundAlternate": "236,236,240", "ForegroundNormal": "29,29,31"},
    "Colors:View": {"BackgroundNormal": "255,255,255", "BackgroundAlternate": "245,245,247", "ForegroundNormal": "29,29,31"},
    "Colors:Button": {"BackgroundNormal": "250,250,252", "ForegroundNormal": "29,29,31"},
    "Colors:Tooltip": {"BackgroundNormal": "245,245,247", "ForegroundNormal": "29,29,31"},
    "Colors:Header": {"BackgroundNormal": "236,236,240", "BackgroundAlternate": "245,245,247", "ForegroundNormal": "29,29,31"},
}

VARIANTS = {
    "liquid-glass": {
        "name": "Liquid Glass",
        "description": "Breeze with translucent, light-catching glass popups (follows your colour scheme)",
        "settings": {},
    },
    "liquid-glass-light": {
        "name": "Liquid Glass Light",
        "description": "Bright frosted glass with dark text, like macOS in light mode",
        "colors": LIGHT_COLORS,
        "settings": {  # brighter, more opaque glass; white rims so edges read on light wallpapers, kept
                       # even all round with little inner glow, so the glass looks flat, not bevelled
            "FILL_TRANSLUCENT": 0.62, "FILL_OPAQUE": 0.97, "SHADOW_ALPHA": 0.18,
            "RIM": {"top": 0.60, "side": 0.48, "bottom": 0.40},
            "GLOW": {"top": 0.12, "side": 0.06, "bottom": 0.05},
            "FIELD": {"base_fill": 0.05, "base_rim": 0.10, "hover": 0.18, "focus": 0.30, "halo": 0.06},
            "HIGHLIGHT": {"hover": 0.05, "selected": 0.09, "selected+hover": 0.12},
            "SB_SLIDER": 0.30, "SB_HOVER": 0.50, "SB_TRACK": 0.06,
            "HEADING": {"band": 0.035, "line": 0.12},
        },
    },
}


def write(out, rel, content):
    p = out / rel
    p.parent.mkdir(parents=True, exist_ok=True)
    with gzip.open(p, "wt", encoding="utf-8") as f:
        f.write(content)


def light_colors(overrides):
    """Breeze Light's Plasma colours with the overrides applied, as KDE colour-scheme text."""
    import configparser
    cp = configparser.ConfigParser(interpolation=None)
    cp.optionxform = str  # keys are case-sensitive
    cp.read("/usr/share/plasma/desktoptheme/breeze-light/colors")
    if not cp.sections():
        raise SystemExit("Breeze Light's colours (/usr/share/plasma/desktoptheme/breeze-light/colors) not found")
    for section, keys in overrides.items():
        for k, v in keys.items():
            cp[section][k] = v
    from io import StringIO
    buf = StringIO()
    cp.write(buf, space_around_delimiters=False)
    return buf.getvalue()


def generate(style_id, variant):
    out = HERE.parent / style_id
    defaults = {k: globals()[k] for k in variant["settings"]}
    globals().update(variant["settings"])
    try:
        write(out, "translucent/dialogs/background.svgz", svg(FILL_TRANSLUCENT))
        write(out, "dialogs/background.svgz", svg(FILL_OPAQUE))
        write(out, "opaque/dialogs/background.svgz", svg(1.0, glass=False))  # no compositing: no blur or shadow
        write(out, "solid/dialogs/background.svgz", svg(1.0, glass=False))
        write(out, "widgets/scrollbar.svgz", scrollbar_svg())
        write(out, "widgets/lineedit.svgz", lineedit_svg())
        write(out, "widgets/viewitem.svgz", viewitem_svg())
        write(out, "widgets/plasmoidheading.svgz", heading_svg())
    finally:
        globals().update(defaults)
    meta = {
        "KPlugin": {
            "Id": style_id,
            "Name": variant["name"],
            "Description": variant["description"],
            "Authors": [{"Name": "Generated with Claude Code"}],
            "License": "LGPL-2.0-or-later",
            "Version": "1.1",
        },
        "X-Plasma-API": "5.0",
    }
    (out / "metadata.json").write_text(json.dumps(meta, indent=4) + "\n")
    (out / "plasmarc").write_text(
        "[Wallpaper]\ndefaultWallpaperTheme=Next\ndefaultFileSuffix=.png\ndefaultWidth=1920\ndefaultHeight=1080\n\n"
        "[AdaptiveTransparency]\nenabled=true\n")
    colors = out / "colors"
    if "colors" in variant:
        colors.write_text(light_colors(variant["colors"]))
    elif colors.exists():
        colors.unlink()  # no colours file: follow the system colour scheme
    print("wrote", out)


def main():
    for style_id, variant in VARIANTS.items():
        generate(style_id, variant)


if __name__ == "__main__":
    main()
