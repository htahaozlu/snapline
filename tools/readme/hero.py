#!/usr/bin/env python3
"""Animated README hero for Snapline (stdlib only):  python3 -I tools/readme/hero.py

Writes docs/images/hero-light.svg and docs/images/hero-dark.svg: one SMIL timeline (no script, so it
plays inside GitHub's <img>) showing what the app does, in its own visual language (DESIGN.md:
monochrome, one red, "the line shows, the period finishes"):

  1. a window is dragged by its title bar to the left edge of the screen;
  2. the preview line draws itself from the touched edge's midpoint in both directions and closes
     on the far side;
  3. on release the window lands in the left half, the line thickens and fades, a red period marks
     the target's inner corner;
  4. three keyboard snaps follow, each with its keycaps: ⌃⌥→ right half, ⌃⌥↩ maximize, ⌃⌥⌫ restore.

Geometry follows the app: 12 pt outer and inner gaps, the period 8 pt in from the target's
bottom-right inner corner. Everything is a hand-written rectangle — no screenshot, nothing traced.
"""
import os

W, H = 960, 540
T = 11.0          # loop length, s
MENU = 24         # menu bar height
GAP = 12

USABLE = (GAP, MENU + GAP, W - 2 * GAP, H - MENU - 2 * GAP)
LEFT = (GAP, MENU + GAP, (W - 3 * GAP) / 2, H - MENU - 2 * GAP)
RIGHT = (GAP * 2 + (W - 3 * GAP) / 2, MENU + GAP, (W - 3 * GAP) / 2, H - MENU - 2 * GAP)
MAX = USABLE
HOME = (250, 128, 420, 296)
GRAB = 130                                   # cursor x inside the title bar while dragging
DRAGGED = (GAP - GRAB + 2, 156, HOME[2], HOME[3])
TITLE = 28

THEMES = {
    "light": dict(bg0="#ECEBE7", bg1="#D7D6D1", menu="#F8F8F6", menu_op=".86", glyph="#2B2B2E",
                  win="#FFFFFF", win_edge="#0000001F", title="#F3F3F1", line="#E6E6E2", dots="#C9C9C5",
                  back="#F7F7F5", ink="#111113", red="#FF4438", key="#FFFFFF", key_edge="#00000026",
                  key_ink="#111113", cursor="#111113", cursor_edge="#FFFFFF", shadow=".16"),
    "dark": dict(bg0="#1F1F22", bg1="#101012", menu="#2A2A2D", menu_op=".86", glyph="#E8E8E6",
                 win="#2C2C2F", win_edge="#FFFFFF1F", title="#343437", line="#3B3B3F", dots="#55555A",
                 back="#262629", ink="#F5F5F3", red="#FF5A4F", key="#3A3A3E", key_edge="#FFFFFF2E",
                 key_ink="#F5F5F3", cursor="#F5F5F3", cursor_edge="#111113", shadow=".45"),
}

EASE = "0.2 0 0 1"      # ease-out (decelerate)
LINEAR = "0 0 1 1"


def track(points, attr, fmt=lambda v: f"{v:g}"):
    """<animate> over the whole loop from [(t, value), ...] (t in s, ascending, first at 0, last at T).
    A segment whose ends are equal holds; a changing one eases out."""
    times = ";".join(f"{t / T:.4f}" for t, _ in points)
    values = ";".join(fmt(v) for _, v in points)
    splines = ";".join(LINEAR if a[1] == b[1] else EASE for a, b in zip(points, points[1:]))
    return (f'<animate attributeName="{attr}" dur="{T:g}s" repeatCount="indefinite" calcMode="spline" '
            f'keyTimes="{times}" values="{values}" keySplines="{splines}"/>')


def held(points, end=T):
    """Pads a track so it starts at 0 and ends at T, holding its first and last values."""
    pts = list(points)
    if pts[0][0] > 0:
        pts.insert(0, (0.0, pts[0][1]))
    if pts[-1][0] < end:
        pts.append((end, pts[-1][1]))
    return pts


# The window's frame over time: (t, (x, y, w, h)).
FRAMES = [
    (0.0, HOME), (1.0, HOME), (2.5, DRAGGED), (3.45, DRAGGED), (3.7, LEFT),
    (5.1, LEFT), (5.3, RIGHT), (6.7, RIGHT), (6.9, MAX), (8.3, MAX), (8.5, HOME), (T, HOME),
]


def frame_track(i, offset=0.0, scale=1.0, attr=None, fmt=lambda v: f"{v:.1f}"):
    return track([(t, f[i] * scale + offset) for t, f in FRAMES], attr, fmt)


def window(c):
    """The moving window: body, title bar, three grey dots, three text lines; each part follows
    the frame with its own offsets (no transform scaling, so nothing distorts)."""
    x0, y0, w0, h0 = HOME
    parts = []
    body = (f'<rect x="{x0}" y="{y0}" width="{w0}" height="{h0}" rx="10" fill="{c["win"]}" '
            f'stroke="{c["win_edge"]}" filter="url(#shadow)">'
            + frame_track(0, attr="x") + frame_track(1, attr="y")
            + frame_track(2, attr="width") + frame_track(3, attr="height") + "</rect>")
    parts.append(body)
    title = (f'<rect x="{x0 + 1}" y="{y0 + 1}" width="{w0 - 2}" height="{TITLE}" rx="9" fill="{c["title"]}">'
             + frame_track(0, 1, attr="x") + frame_track(1, 1, attr="y") + frame_track(2, -2, attr="width") + "</rect>")
    parts.append(title)
    parts.append(f'<rect x="{x0 + 1}" y="{y0 + TITLE - 8}" width="{w0 - 2}" height="9" fill="{c["title"]}">'
                 + frame_track(0, 1, attr="x") + frame_track(1, TITLE - 8, attr="y") + frame_track(2, -2, attr="width") + "</rect>")
    for k in range(3):
        parts.append(f'<circle cx="{x0 + 16 + 14 * k}" cy="{y0 + 14}" r="4.5" fill="{c["dots"]}">'
                     + frame_track(0, 16 + 14 * k, attr="cx") + frame_track(1, 14, attr="cy") + "</circle>")
    for k, frac in enumerate((0.62, 0.78, 0.45)):
        parts.append(f'<rect x="{x0 + 20}" y="{y0 + TITLE + 22 + 18 * k}" width="{(w0 - 40) * frac:.1f}" height="7" rx="3.5" fill="{c["line"]}">'
                     + frame_track(0, 20, attr="x") + frame_track(1, TITLE + 22 + 18 * k, attr="y")
                     + track([(t, (f[2] - 40) * frac) for t, f in FRAMES], "width", lambda v: f"{v:.1f}") + "</rect>")
    return "\n  ".join(parts)


def outline_halves(rect, radius=10):
    """Two paths around `rect` that start together at the middle of its left edge and meet at the
    middle of its right edge (clockwise over the top, counter-clockwise under the bottom)."""
    x, y, w, h = rect
    r = radius
    mid = y + h / 2
    top = (f"M{x},{mid} V{y + r} Q{x},{y} {x + r},{y} H{x + w - r} Q{x + w},{y} {x + w},{y + r} V{mid}")
    bottom = (f"M{x},{mid} V{y + h - r} Q{x},{y + h} {x + r},{y + h} H{x + w - r} Q{x + w},{y + h} {x + w},{y + h - r} V{mid}")
    length = (h / 2 - r) * 2 + (w - 2 * r) + 3.1416 * r  # straight runs + two quarter arcs (≈)
    return top, bottom, length


def preview(c):
    """Drag preview on the left half: draws itself 2.55–3.05 s, holds, thickens on the drop at 3.45 s
    and fades by 3.9 s."""
    top, bottom, n = outline_halves(LEFT)
    out = []
    for d in (top, bottom):
        out.append(
            f'<path d="{d}" fill="none" stroke="{c["ink"]}" stroke-linecap="round" stroke-width="2" '
            f'stroke-dasharray="{n:.1f}" stroke-dashoffset="{n:.1f}" opacity="0">'
            + track(held([(2.55, n), (3.05, 0.0)]), "stroke-dashoffset", lambda v: f"{v:.1f}")
            + track(held([(3.45, 2.0), (3.55, 4.0)]), "stroke-width")
            + track([(0, 0), (2.5, 0), (2.56, 1), (3.55, 1), (3.95, 0), (T, 0)], "opacity")
            + "</path>")
    return "\n  ".join(out)


def period(c, rect, t0, t1):
    """The red period at `rect`'s inner bottom-right corner, shown t0 → t1."""
    x, y, w, h = rect
    cx, cy = x + w - 16, y + h - 16
    return (f'<circle cx="{cx:.1f}" cy="{cy:.1f}" r="0" fill="{c["red"]}">'
            + track([(0, 0), (t0, 0), (t0 + 0.12, 6.0), (t0 + 0.2, 5.0), (t1 - 0.35, 5.0), (t1, 0), (T, 0)], "r")
            + "</circle>")


def flash(c, rect, t0):
    """Keyboard snap: the target's outline at once (no drawing), thick, fading over 0.5 s."""
    x, y, w, h = rect
    return (f'<rect x="{x}" y="{y}" width="{w}" height="{h}" rx="10" fill="none" stroke="{c["ink"]}" '
            f'stroke-width="3" opacity="0">'
            + track([(0, 0), (t0, 0), (t0 + 0.06, 1), (t0 + 0.2, 1), (t0 + 0.6, 0), (T, 0)], "opacity")
            + "</rect>")


def keycaps(c, keys, t_in, t_press, t_out):
    """Keycap chips centred near the bottom, pressed (shifted down 2 pt) at t_press."""
    size, gap = 44, 10
    total = len(keys) * size + (len(keys) - 1) * gap
    x0, y0 = (W - total) / 2, H - 94
    chips = []
    for i, k in enumerate(keys):
        x = x0 + i * (size + gap)
        chips.append(
            f'<rect x="{x:.1f}" y="{y0}" width="{size}" height="{size}" rx="10" fill="{c["key"]}" stroke="{c["key_edge"]}" '
            f'filter="url(#keyshadow)"/>'
            f'<text x="{x + size / 2:.1f}" y="{y0 + 30}" text-anchor="middle" font-size="22" fill="{c["key_ink"]}" '
            f'font-family="-apple-system, \'SF Pro Text\', \'Helvetica Neue\', \'Segoe UI Symbol\', sans-serif">{k}</text>')
    return (f'<g opacity="0">'
            + track([(0, 0), (t_in, 0), (t_in + 0.2, 1), (t_out - 0.25, 1), (t_out, 0), (T, 0)], "opacity")
            + f'<animateTransform attributeName="transform" type="translate" dur="{T:g}s" repeatCount="indefinite" '
              f'calcMode="spline" keyTimes="0;{(t_press - 0.08) / T:.4f};{t_press / T:.4f};{(t_press + 0.18) / T:.4f};1" '
              f'values="0 0;0 0;0 3;0 0;0 0" keySplines="{LINEAR};{EASE};{EASE};{LINEAR}"/>'
            + "".join(chips) + "</g>")


def cursor(c):
    """macOS-style arrow: to the title bar, drags to the left edge, fades after the drop."""
    pts = [(0.0, (520, 380)), (1.0, (HOME[0] + GRAB, HOME[1] + 14)), (2.5, (DRAGGED[0] + GRAB, DRAGGED[1] + 14)),
           (T, (DRAGGED[0] + GRAB, DRAGGED[1] + 14))]
    arrow = "M0,0 L0,17 L4.3,13 L7.2,19.6 L10,18.4 L7.2,12 L12.8,12 Z"
    times = ";".join(f"{t / T:.4f}" for t, _ in pts)
    values = ";".join(f"{x:.1f} {y:.1f}" for _, (x, y) in pts)
    splines = ";".join(EASE if a[1] != b[1] else LINEAR for a, b in zip(pts, pts[1:]))
    return (f'<g opacity="1">'
            + f'<animateTransform attributeName="transform" type="translate" dur="{T:g}s" repeatCount="indefinite" '
              f'calcMode="spline" keyTimes="{times}" values="{values}" keySplines="{splines}"/>'
            + track([(0, 0), (0.3, 1), (3.5, 1), (3.9, 0), (T - 0.4, 0), (T, 0)], "opacity")
            + f'<path d="{arrow}" fill="{c["cursor"]}" stroke="{c["cursor_edge"]}" stroke-width="1.2" stroke-linejoin="round"/>'
            + "</g>")


def menubar(c):
    """Menu bar with Snapline's active icon (half-filled window + period) near the right."""
    x = W - 92
    return (f'<rect x="0" y="0" width="{W}" height="{MENU}" fill="{c["menu"]}" opacity="{c["menu_op"]}"/>'
            f'<rect x="{x}" y="7" width="15" height="10" rx="2.5" fill="none" stroke="{c["glyph"]}" stroke-width="1.4"/>'
            f'<rect x="{x}" y="7" width="7.5" height="10" rx="2" fill="{c["glyph"]}"/>'
            f'<circle cx="{x + 19}" cy="15.5" r="1.7" fill="{c["glyph"]}"/>'
            f'<rect x="{W - 58}" y="9" width="44" height="6" rx="3" fill="{c["glyph"]}" opacity=".35"/>'
            f'<rect x="16" y="9" width="14" height="6" rx="3" fill="{c["glyph"]}" opacity=".55"/>'
            f'<rect x="40" y="9" width="36" height="6" rx="3" fill="{c["glyph"]}" opacity=".35"/>'
            f'<rect x="86" y="9" width="28" height="6" rx="3" fill="{c["glyph"]}" opacity=".35"/>')


def scene(theme):
    c = THEMES[theme]
    bx, by, bw, bh = 600, 70, 312, 210
    background = (f'<rect x="{bx}" y="{by}" width="{bw}" height="{bh}" rx="10" fill="{c["back"]}" stroke="{c["win_edge"]}" filter="url(#shadow)"/>'
                  f'<rect x="{bx + 1}" y="{by + 1}" width="{bw - 2}" height="{TITLE}" rx="9" fill="{c["title"]}"/>'
                  + "".join(f'<circle cx="{bx + 16 + 14 * k}" cy="{by + 14}" r="4.5" fill="{c["dots"]}"/>' for k in range(3)))
    body = [
        menubar(c),
        background,
        window(c),
        preview(c),
        period(c, LEFT, 3.5, 4.5),
        flash(c, RIGHT, 5.3), period(c, RIGHT, 5.35, 6.2),
        flash(c, MAX, 6.9), period(c, MAX, 6.95, 7.8),
        flash(c, HOME, 8.5), period(c, HOME, 8.55, 9.4),
        keycaps(c, ["⌃", "⌥", "→"], 4.55, 5.2, 6.05),
        keycaps(c, ["⌃", "⌥", "↩"], 6.15, 6.8, 7.65),
        keycaps(c, ["⌃", "⌥", "⌫"], 7.75, 8.4, 9.25),
        cursor(c),
    ]
    return f"""<svg xmlns="http://www.w3.org/2000/svg" width="{W}" height="{H}" viewBox="0 0 {W} {H}" role="img" aria-labelledby="t d">
<title id="t">Snapline: drag a window to an edge, or press a shortcut</title>
<desc id="d">A window is dragged to the left edge; a line draws the left half and the window lands there with a red period. Then Control Option Right Arrow, Return and Delete move it to the right half, maximize it and restore it.</desc>
<!-- Generated by tools/readme/hero.py — edit the script, not this file. -->
<defs>
  <linearGradient id="bg" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="{c["bg0"]}"/><stop offset="1" stop-color="{c["bg1"]}"/></linearGradient>
  <filter id="shadow" x="-10%" y="-10%" width="120%" height="130%"><feDropShadow dx="0" dy="6" stdDeviation="9" flood-color="#000" flood-opacity="{c["shadow"]}"/></filter>
  <filter id="keyshadow" x="-60%" y="-60%" width="220%" height="240%"><feDropShadow dx="0" dy="3" stdDeviation="4" flood-color="#000" flood-opacity="{c["shadow"]}"/></filter>
  <clipPath id="screen"><rect width="{W}" height="{H}" rx="18"/></clipPath>
</defs>
<g clip-path="url(#screen)">
  <rect width="{W}" height="{H}" fill="url(#bg)"/>
  {chr(10).join("  " + b for b in body)}
</g>
</svg>
"""


def main():
    root = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
    out = os.path.join(root, "docs", "images")
    os.makedirs(out, exist_ok=True)
    for theme in THEMES:
        path = os.path.join(out, f"hero-{theme}.svg")
        with open(path, "w") as f:
            f.write(scene(theme))
        print(f"wrote {os.path.relpath(path, root)} ({os.path.getsize(path)} bytes)")


if __name__ == "__main__":
    main()
