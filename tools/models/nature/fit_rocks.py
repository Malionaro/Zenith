#!/usr/bin/env python3
"""Measures the Nauvis rocks' silhouettes from Factorio's own pictures and writes rock_shapes.py,
which rocks.py builds them from. Plain Python (numpy, pillow; the repo's .venv):

    python tools/models/nature/fit_rocks.py

Per rock, the picture its model is fitted to (big-rock-01, huge-rock-05, big-sand-rock-01: the ones
tree_looks.py scales the others against), as Factorio's camera sees it (north and down 48 degrees,
orthographic: a point z up and y north shows 0.669 z + 0.743 y up the screen):

  PROFILES  per 1/16-tile column (x in tiles east of the entity's position), the rock's top and
            bottom up the screen (tiles); the drawn-in shadow (near black) left out. The bottom is
            where the rock meets the ground at its front.
  LIGHT     per 1/8-tile cell, how light the rock is there (0-31 over its 5th to 95th percentile of
            luminance), one string a row (a digit per cell, 0-9 then a-v), top row first, from (x0,
            up0) the top-left cell's middle: rocks.py tips each block's top towards Factorio's light
            as much as the picture shows it lit, so the facets light as the picture's do.

Numbers only: nothing of the image is kept.
"""

import os
import sys

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import tree_sprites as ts  # noqa: E402

OUT = os.path.join(HERE, "rock_shapes.py")
ROCKS = {"big-rock": "1", "huge-rock": "5", "big-sand-rock": "1"}
DIGITS = "0123456789abcdefghijklmnopqrstuv"


def fit(name, ref):
    ppt = 64.0
    img, (ox, oy) = ts.reference(name, ref, ppt)
    rock = (img[..., 3] > 0.6) & (img[..., :3].max(axis=2) > 0.06)
    h, w = rock.shape
    profiles = []
    step = 4  # pixels: 1/16 tile
    for c0 in range(0, w, step):
        cols = rock[:, c0:c0 + step]
        rows = np.nonzero(cols.any(axis=1))[0]
        if len(rows) < 3:
            continue
        x = (c0 + step / 2 - ox) / ppt
        top, bot = (oy - rows.min()) / ppt, (oy - rows.max() - 1) / ppt
        profiles.append((round(float(x), 4), round(float(top), 3), round(float(bot), 3)))
    lum = ts._lin(img[..., :3]) @ ts.LUMA
    lo, hi = np.percentile(lum[rock], [5, 95])
    cell = 8  # pixels: 1/8 tile
    ys, xs = np.nonzero(rock)
    r0, r1, c0, c1 = ys.min() // cell, ys.max() // cell + 1, xs.min() // cell, xs.max() // cell + 1
    light = []
    for r in range(r0, r1):
        row = ""
        for c in range(c0, c1):
            sel = rock[r * cell:(r + 1) * cell, c * cell:(c + 1) * cell]
            if sel.sum() < cell * cell // 3:
                row += "."
                continue
            v = (lum[r * cell:(r + 1) * cell, c * cell:(c + 1) * cell][sel].mean() - lo) / max(hi - lo, 1e-6)
            row += DIGITS[int(np.clip(v, 0.0, 1.0) * 31)]
        light.append(row)
    x0 = (c0 * cell + cell / 2 - ox) / ppt
    up0 = (oy - r0 * cell - cell / 2) / ppt
    return profiles, (round(float(x0), 4), round(float(up0), 4), light)


def main():
    lines = ['"""The Nauvis rocks as Factorio\'s camera sees their pictures, measured by fit_rocks.py (see there):',
             "PROFILES, per 1/16-tile column (x, top, bottom) in tiles up the screen; LIGHT, how light each 1/8-tile",
             'cell is (0-31, "." off the rock). Numbers only; nothing of the image is kept."""', "", "PROFILES = {"]
    lights = []
    for name, ref in ROCKS.items():
        prof, light = fit(name, ref)
        print("%-14s %3d columns, x %.2f..%.2f, top %.2f, light %dx%d" % (
            name, len(prof), prof[0][0], prof[-1][0], max(p[1] for p in prof), len(light[2][0]), len(light[2])))
        lines.append("    %r: [%s]," % (name, ", ".join("(%g, %g, %g)" % p for p in prof)))
        lights.append((name, light))
    lines += ["}", "", "LIGHT = {"]
    for name, (x0, up0, rows) in lights:
        lines.append("    %r: (%r, %r, [" % (name, x0, up0))
        lines += ["        %r," % row for row in rows]
        lines.append("    ]),")
    lines.append("}")
    with open(OUT, "w", encoding="utf-8", newline="\n") as f:
        f.write("\n".join(lines) + "\n")
    print("wrote", OUT)
    return 0


if __name__ == "__main__":
    sys.exit(main())
