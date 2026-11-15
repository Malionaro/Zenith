#!/usr/bin/env python3
"""Measures each Nauvis tree's crown from Factorio's own sprite and writes tree_crowns.py, which
trees.py builds the leaf-card crowns from. Plain Python (numpy, pillow; the repo's .venv):

    python tools/models/nature/fit_crowns.py

For each tree (variation a, leaves frame 0, as tree_sprites.picture reads it), from its leaves
(alpha over half; pixel specks closed, the gaps between clumps kept):

  GRID    the leaves seen from Factorio's camera, per 1/8-tile cell: how far (in 1/32 tiles, at
          most 31) the cell's middle is from the nearest gap or edge, one string a row (a digit per
          cell, 0-9 then a-v), top row first, from (x0, up0) the top-left cell's middle. trees.py
          keeps a clump only where its middle lands well inside the leaves, so the crown's
          outline, its holes and the gaps between its clumps are the sprite's.
  OUTLINE the same distances with the crown's holes filled (from its outline only), on GRID's
          cells: trees.py shapes the crown in depth so its outline is the sprite's from every side.
  RINGS   the crown's body for the clumps' middles: per height z (tiles up), a ring (z, centre x,
          radius) as wide as a circle there can be while what Factorio's camera sees of it (an
          ellipse, 0.743 as tall as wide, 0.669 z up the screen) stays a clump's radius inside the
          leaves, holes filled. Factorio's camera is an orthographic view 48 degrees down: a point z
          up and y north shows 0.669 z + 0.743 y up the sprite (0.669^2 + 0.743^2 = 1), so a sphere
          of radius r draws as a disk of radius r.
  CLUMP   the clumps' radius: the median of the largest disks that fit the leaves one by one (each
          next in what the ones before left), past the few that cover the crown's body.
  TIERS   the spruce's (tree-01) whorls: heights up the screen where a row's leaves are brightest
          against the rows round it (each whorl's lit, drooping tips over its dark underside).
  SHADES  each leaf layer's mean colour in thirds by brightness (dark, mid, light), after the
          prototype's mean tint, for the cores' and cards' shades.

Numbers only: nothing of the image is kept.
"""

import os
import sys

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import tree_sprites as ts  # noqa: E402

OUT = os.path.join(HERE, "tree_crowns.py")
# tree-06, the weeping swamp tree, hangs its leaves in strands (trees.tree_06), not clumps.
TREES = ["0%d" % i for i in (1, 2, 3, 4, 5, 7, 8, 9)]
CELL = 8  # cells a tile in GRID
DIGITS = "0123456789abcdefghijklmnopqrstuv"
RING_STEP = 0.1  # tiles between RINGS' heights


def edt(mask):
    """Each pixel's distance (pixels) to the nearest pixel outside `mask` (outside the picture
    counts as outside): exact, a column pass then a row pass."""
    m = np.pad(mask, 1, constant_values=False)
    h, w = m.shape
    big = h + w
    idx = np.arange(h)[:, None].repeat(w, 1)
    last = np.maximum.accumulate(np.where(~m, idx, -big), axis=0)
    nxt = np.minimum.accumulate(np.where(~m, idx, 2 * big)[::-1], axis=0)[::-1]
    g = np.minimum(idx - last, nxt - idx).astype(np.float64)
    xs = np.arange(w, dtype=np.float64)
    out = np.empty((h, w))
    dx2 = (xs[:, None] - xs[None, :]) ** 2
    for y0 in range(0, h, 16):
        G = g[y0:y0 + 16]
        out[y0:y0 + 16] = np.sqrt((dx2[None] + G[:, None, :] ** 2).min(axis=2))
    return out[1:-1, 1:-1]


def _shift(m, dy, dx):
    out = np.zeros_like(m)
    h, w = m.shape
    out[max(0, dy):h + min(0, dy), max(0, dx):w + min(0, dx)] = m[max(0, -dy):h + min(0, -dy), max(0, -dx):w + min(0, -dx)]
    return out


def close(mask, iterations):
    """Binary closing with the 4-neighbour cross (scipy's default), `iterations` steps each way."""
    m = np.pad(mask, iterations, constant_values=False)
    for _ in range(iterations):
        m = m | _shift(m, 1, 0) | _shift(m, -1, 0) | _shift(m, 0, 1) | _shift(m, 0, -1)
    for _ in range(iterations):
        m = m & _shift(m, 1, 0) & _shift(m, -1, 0) & _shift(m, 0, 1) & _shift(m, 0, -1)
    return m[iterations:-iterations, iterations:-iterations]


def fill_holes(mask):
    """The mask with every hole (background not reached from the picture's edge) filled."""
    outside = ~np.pad(mask, 1, constant_values=False)
    reach = np.zeros_like(outside)
    reach[0, :] = reach[-1, :] = True
    reach[:, 0] = reach[:, -1] = True
    reach &= outside
    while True:
        grown = reach | _shift(reach, 1, 0) | _shift(reach, -1, 0) | _shift(reach, 0, 1) | _shift(reach, 0, -1)
        grown &= outside
        if (grown == reach).all():
            break
        reach = grown
    return ~reach[1:-1, 1:-1]


def disks(mask, min_r, most):
    """Largest disks, one by one, each in what the ones before left uncovered (shrunk to 0.75 of
    their radius, so neighbours overlap): [(px, py, r)] in pixels. One distance transform: a
    covered disk's distance is the distance to its edge."""
    d0 = edt(mask)
    h, w = mask.shape
    yy, xx = np.mgrid[0:h, 0:w]
    left = d0.copy()
    out = []
    while len(out) < most:
        i = int(np.argmax(left))
        r = left.flat[i]
        if r < min_r:
            break
        py, px = divmod(i, w)
        out.append((px, py, r))
        left = np.minimum(left, np.sqrt((xx - px) ** 2 + (yy - py) ** 2) - 0.75 * r)
    return out


def fit(tree):
    img, (w, h, sx, sy) = ts.picture(tree, "a", "leaves")
    w, h = int(w), int(h)
    ppt = ts.PX
    mask = close(img[..., 3] > 0.5, 1)
    dist = edt(mask) / ppt  # tiles

    def to_tiles(px, py):
        return (px + 0.5 - w / 2) / ppt + sx / 32.0, -((py + 0.5 - h / 2) / ppt + sy / 32.0)

    # GRID: the distance at each 1/8-tile cell's middle; OUTLINE: the same with the holes filled.
    outline = edt(fill_holes(close(img[..., 3] > 0.5, 4))) / ppt
    left, top = to_tiles(-0.5, -0.5)
    cols = int(np.ceil(w / ppt * CELL))
    rows_n = int(np.ceil(h / ppt * CELL))
    x0, up0 = left + 0.5 / CELL, top - 0.5 / CELL
    grids = []
    for field in (dist, outline):
        grid = []
        for r in range(rows_n):
            row = ""
            for c in range(cols):
                x, up = x0 + c / CELL, up0 - r / CELL
                px = int(round((x - sx / 32.0) * ppt + w / 2 - 0.5))
                py = int(round(-(up + sy / 32.0) * ppt + h / 2 - 0.5))
                d = field[py, px] if 0 <= px < w and 0 <= py < h else 0.0
                row += DIGITS[min(31, int(d * 32.0))]
            grid.append(row)
        grids.append(grid)
    # Trim empty rows and columns round the crown (the outline's).
    keep_r = [i for i, row in enumerate(grids[1]) if row.strip("0")]
    r0, r1 = keep_r[0], keep_r[-1] + 1
    c0 = min(len(row) - len(row.lstrip("0")) for row in grids[1][r0:r1])
    c1 = max(len(row.rstrip("0")) for row in grids[1][r0:r1])
    grid, outline_grid = ([row[c0:c1] for row in g[r0:r1]] for g in grids)
    x0, up0 = x0 + c0 / CELL, up0 - r0 / CELL

    # CLUMP: the disks past the body's.
    found = disks(mask, 0.18 * ppt, 40)
    radii = sorted((r / ppt for _, _, r in found), reverse=True)
    clump = float(np.median(radii[3:])) if len(radii) > 6 else float(np.median(radii))

    # RINGS: per height, the widest circle whose ellipse on the screen stays CLUMP * 0.6 inside the
    # crown (holes filled).
    inner = outline > clump * 0.6
    ys, xs = np.nonzero(inner)
    rings = []
    if len(ys):
        ups = [to_tiles(0, py)[1] for py in (ys.min(), ys.max())]
        xs_t = [to_tiles(px, 0)[0] for px in (xs.min(), xs.max())]
        t = np.linspace(0.0, 2.0 * np.pi, 48, endpoint=False)

        def fits(cx, zc, rad):
            ex = cx + rad * np.cos(t)
            eu = 0.669 * zc + 0.743 * rad * np.sin(t)
            px = np.round((ex - sx / 32.0) * ppt + w / 2 - 0.5).astype(int)
            py = np.round(-(eu + sy / 32.0) * ppt + h / 2 - 0.5).astype(int)
            ok = (px >= 0) & (px < w) & (py >= 0) & (py < h)
            return ok.all() and inner[py, px].mean() >= 0.97
        z = min(ups) / 0.669
        while z <= max(ups) / 0.669:
            best = (0.0, 0.0)
            for cx in np.arange(xs_t[0], xs_t[1], 1.0 / 16):
                lo, hi = 0.0, 3.5
                if not fits(cx, z, 0.02):
                    continue
                for _ in range(14):
                    mid = (lo + hi) / 2
                    if fits(cx, z, mid):
                        lo = mid
                    else:
                        hi = mid
                if lo > best[0]:
                    best = (lo, cx)
            if best[0] >= 0.05:
                rings.append((round(z, 2), round(best[1], 3), round(best[0], 3)))
            z += RING_STEP

    # TIERS (the spruce): rows whose leaves stand out brightest against the rows either side.
    tiers = []
    if tree == "01":
        lum = (ts._lin(img[..., :3]) @ ts.LUMA)
        leaf = img[..., 3] > 0.85
        prof = np.array([lum[r][leaf[r]].mean() if leaf[r].sum() > 8 else np.nan for r in range(h)])
        good = ~np.isnan(prof)
        sm = np.interp(np.arange(h), np.nonzero(good)[0], prof[good])
        k = np.exp(-0.5 * (np.arange(-6, 7) / 3.0) ** 2)
        sm = np.convolve(sm, k / k.sum(), mode="same")
        wide = np.convolve(sm, np.ones(41) / 41, mode="same")
        peak = sm - wide
        for r in range(4, h - 4):
            if good[r] and peak[r] == peak[r - 4:r + 5].max() and peak[r] > 0.0:
                tiers.append(round(to_tiles(0, r)[1], 3))
        tiers.sort()

    # SHADES: as before, the opaque leaf pixels tinted with the prototype's mean colour, in thirds.
    tint = np.array(ts.tints("tree-" + tree)).mean(0)
    px = img[img[..., 3] > 0.9][:, :3] * tint
    lum = px @ np.array([0.2126, 0.7152, 0.0722])
    thirds = np.array_split(px[np.argsort(lum)], 3)
    shades = ["#%02x%02x%02x" % tuple(int(round(min(1.0, c) * 255)) for c in th.mean(axis=0)) for th in thirds]
    return {"grid": (round(x0, 4), round(up0, 4), grid), "outline": outline_grid, "rings": rings, "clump": round(clump, 3), "tiers": tiers,
            "shades": shades, "disks": len(found)}


def main():
    out = {}
    for t in TREES:
        out[t] = fit(t)
        f = out[t]
        print("tree-%s  %2d disks, clump %.2f, %2d rings (z %.2f..%.2f, widest %.2f), grid %dx%d%s" % (
            t, f["disks"], f["clump"], len(f["rings"]), f["rings"][0][0], f["rings"][-1][0], max(r[2] for r in f["rings"]),
            len(f["grid"][2][0]), len(f["grid"][2]), ", tiers %s" % f["tiers"] if f["tiers"] else ""))
    lines = ['"""Each Nauvis tree\'s crown as Factorio\'s sprite draws it (variation a), measured by fit_crowns.py',
             "(see there): GRID, the leaves' distance from the nearest gap per 1/8-tile cell (OUTLINE: from the",
             "outline, holes filled); RINGS, the crown's body as rings (z, centre x, radius) in tiles; CLUMP, the",
             "clumps' radius; TIERS, the spruce's whorls up the screen; SHADES, the leaves' dark, mid and light",
             "colour (sRGB, after the prototype's mean tint). Numbers only; nothing of the image is kept.\"\"\"", ""]
    lines.append("GRID = {")
    for t in TREES:
        x0, up0, grid = out[t]["grid"]
        lines.append("    'tree-%s': (%r, %r, [" % (t, x0, up0))
        lines += ["        %r," % row for row in grid]
        lines.append("    ]),")
    lines += ["}", "", "OUTLINE = {"]
    for t in TREES:
        lines.append("    'tree-%s': [" % t)
        lines += ["        %r," % row for row in out[t]["outline"]]
        lines.append("    ],")
    lines += ["}", "", "RINGS = {"]
    for t in TREES:
        lines.append("    'tree-%s': [%s]," % (t, ", ".join("(%g, %g, %g)" % r for r in out[t]["rings"])))
    lines += ["}", "", "CLUMP = {%s}" % ", ".join("'tree-%s': %g" % (t, out[t]["clump"]) for t in TREES), ""]
    lines.append("TIERS = {%s}" % ", ".join("'tree-%s': [%s]" % (t, ", ".join("%g" % v for v in out[t]["tiers"]))
                                           for t in TREES if out[t]["tiers"]))
    lines += ["", "SHADES = {"]
    for t in TREES:
        lines.append("    'tree-%s': (%s)," % (t, ", ".join(repr(s) for s in out[t]["shades"])))
    lines.append("}")
    with open(OUT, "w", encoding="utf-8", newline="\n") as f:
        f.write("\n".join(lines) + "\n")
    print("wrote", OUT)
    return 0


if __name__ == "__main__":
    sys.exit(main())
