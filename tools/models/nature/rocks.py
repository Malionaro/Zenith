"""Nauvis rocks and ore tiles, modelled on Factorio's decorative rock and resource sprites.

Factorio's big and huge rocks are warm brown heaps of angular, column-like blocks with flat
broken tops, standing in a skirt of smaller fragments; the sand rock is a rounded, eroded ochre
lump on a dark reddish base. Each is fitted to its picture's silhouette from Factorio's camera
(north, 48 degrees down: a point `z` up shows `z * 0.67` up the sprite; rock_shapes.py, measured
by fit_rocks.py), its blocks' tops tipped towards the light where the picture is lit.

An ore tile is a scatter of glossy, half-buried chunks with a sprinkle of dust between them,
spread a little past the tile (the sprites cover 2x2 tiles) so a patch reads as one field. The
client turns and sizes every tile at random and raises richer tiles.
"""

import math

from mathutils import Vector, noise

import rock_shapes
from geo import material

ROCK = material("rock", "#a87445", 0.92)
SAND_ROCK = material("sand-rock", "#b89152", 0.95)

ORES = {
    # name: (chunk, chunk roughness, chunk metallic, chunk tints, dust)
    "iron-ore": ("#a9c2cc", 0.3, 0.25, ((1.0, 1.0, 1.0), (0.8, 0.86, 0.9), (0.66, 0.7, 0.75)), "#5a4535"),
    "copper-ore": ("#ff9a52", 0.32, 0.2, ((1.0, 1.0, 1.0), (0.92, 0.76, 0.62), (0.8, 0.6, 0.45)), "#7c4a32"),
    "coal": ("#35342f", 0.3, 0.0, ((1.0, 1.0, 1.0), (0.85, 0.84, 0.82), (0.72, 0.7, 0.68)), "#3a2a18"),
    "stone": ("#d6b97c", 0.8, 0.0, ((1.0, 1.0, 1.0), (0.9, 0.88, 0.8), (0.8, 0.76, 0.68)), "#5a5034"),
    # Uranium: glossy bright green lumps on a reddish-brown dust (uranium-ore.png; its glow layer is
    # left out). Space Age: tungsten's blue-violet slate shards, calcite's pale cream lumps.
    "uranium-ore": ("#5fd23a", 0.3, 0.0, ((1.0, 1.0, 1.0), (0.85, 0.95, 0.8), (0.7, 0.8, 0.62)), "#6a3c26"),
    "tungsten-ore": ("#6c6680", 0.4, 0.35, ((1.0, 1.0, 1.0), (0.85, 0.84, 0.92), (0.7, 0.7, 0.78)), "#3c3440"),
    "calcite": ("#e6dcc6", 0.6, 0.0, ((1.0, 1.0, 1.0), (0.92, 0.9, 0.84), (0.82, 0.8, 0.74)), "#7a6e5c"),
}


def column(m, base, radius, height, mat, sides=None, lean=(0.0, 0.0), taper=0.85, tint=None, sink=0.08, cap_tilt=None):
    """An angular rock column: an irregular prism with a tilted, bevelled flat top, like the
    blocks Factorio's big and huge rocks are piled from."""
    rng = m.rng
    bm = m.bm
    sides = sides or rng.randint(4, 6)
    a0 = rng.uniform(0.0, math.tau)
    b = Vector(base)
    top_c = b + Vector((lean[0], lean[1], height))
    tilt = Vector((rng.uniform(-0.45, 0.45), rng.uniform(-0.45, 0.45), 0.0))
    if cap_tilt is not None:
        # Tipped towards a direction (blocks(): towards the light where the picture is lit).
        tilt = tilt * 0.4 - Vector((cap_tilt[0], cap_tilt[1], 0.0))
    ring = []
    for k in range(sides):
        a = a0 + k / sides * math.tau + rng.uniform(-0.25, 0.25)
        r = radius * rng.uniform(0.6, 1.25)
        ring.append((math.cos(a) * r, math.sin(a) * r))
    low = [bm.verts.new(b + Vector((x, y, -sink))) for x, y in ring]
    mid = [bm.verts.new(b + Vector((x * (1 + taper) / 2, y * (1 + taper) / 2, height * 0.55))
                        + Vector((lean[0], lean[1], 0.0)) * 0.55) for x, y in ring]
    shoulder = []
    cap = []
    for x, y in ring:
        off = Vector((x, y, 0.0)) * taper
        h = tilt.dot(off) * 0.8
        shoulder.append(bm.verts.new(top_c + off + Vector((0, 0, h - height * 0.12))))
        cap.append(bm.verts.new(top_c + off * 0.72 + Vector((0, 0, h))))
    n = sides
    for rows in ((low, mid), (mid, shoulder), (shoulder, cap)):
        a, c = rows
        for k in range(n):
            bm.faces.new((a[k], a[(k + 1) % n], c[(k + 1) % n], c[k]))
    bm.faces.new(cap)
    m._tag(low + mid + shoulder + cap, mat, False, tint, 0.25)


def fragment(m, center, radius, mat, scale=(1.0, 1.0, 0.6), tint=None):
    """A broken stone lying in the skirt round a rock: a chopped, flat-bottomed lump."""
    verts = m.blob(center, radius, mat, scale=scale, jitter=0.3, subdiv=1, flat_bottom=-0.05, tint=tint, vary=0.25)
    c = Vector(center)
    m.chop(verts, c, [((m.rng.uniform(-0.3, 0.3), m.rng.uniform(-0.3, 0.3), 1.0), 0.6)])
    return verts


# --- the big, huge and sand rocks, fitted to their pictures --------------------------------------
#
# Each is built from its picture's silhouette as Factorio's camera sees it (rock_shapes.PROFILES,
# measured by fit_rocks.py): every 1/16-tile column of the picture is a cross-section of the rock
# from where it meets the ground at the front (the column's bottom edge) back over the rock's
# depth there, its height solved so the cross-section's top shows where the picture's does. The big
# and huge rocks are then cut into blocks (Voronoi cells over the ground) standing to that height,
# each with a flat top tipped towards Factorio's light as far as the picture shows that spot lit
# (rock_shapes.LIGHT), and its top edge chipped: the column-like blocks of the pictures, their lit
# tops and shaded sides, and low slabs round the foot where the height runs out (the rubble apron).
# The sand rock stays one rounded, wind-worn mass, banded with the strata of its picture.

SIN_P, COS_P = 0.743, 0.669  # Factorio's camera: y and z up the screen
LIGHT = Vector((-0.604, -0.22, 0.766)).normalized()  # Factorio's light, from the west and above
DIGITS = "0123456789abcdefghijklmnopqrstuv"


def _solve_height(y_f, depth, top, shape):
    """Height so that the cross-section's highest point on screen is `top`."""
    ts = [i / 24 for i in range(25)]

    def screen_top(h):
        return max(SIN_P * (y_f + t * depth) + COS_P * h * shape(t) for t in ts)
    if screen_top(0.0) >= top:
        return 0.0
    lo, hi = 0.0, 8.0
    for _ in range(36):
        mid = (lo + hi) / 2
        if screen_top(mid) < top:
            lo = mid
        else:
            hi = mid
    return (lo + hi) / 2


def walls(k, power=1.0, apron=0.0, shelf=0.12):
    """A cross-section rising steeply at front and back (`k`: how steeply) to a broad top. With an
    `apron`, the front `apron` of it is a low shelf (`shelf` of the height) the blocks stand back
    from, as the pictures' rubble round their foot."""
    def shape(t):
        if t < apron:
            return shelf * min(1.0, t / (apron * 0.4))
        u = (t - apron) / (1.0 - apron)
        rise = max(0.0, min(1.0, k * u, k * (1.0 - u))) ** power
        return max(shelf, rise) if u < 0.5 else rise
    return shape


class Silhouette:
    """A rock's cross-sections, one per measured column: (x, front y, depth, height)."""

    def __init__(self, name, depth, shape):
        self.shape = shape
        self.sections = []
        prof = rock_shapes.PROFILES[name]
        xs = [p[0] for p in prof]
        xc, half = (min(xs) + max(xs)) / 2, (max(xs) - min(xs)) / 2 + 0.06
        for x, top, bot in prof:
            y_f = bot / SIN_P
            d = depth * max(0.25, 1.0 - ((x - xc) / half) ** 2) ** 0.5
            d = max(0.15, min(d, (top - 0.02) / SIN_P - y_f))
            self.sections.append((x, y_f, d, _solve_height(y_f, d, top, shape)))

    def height(self, x, y):
        s = self.sections
        if x <= s[0][0] - 0.03 or x >= s[-1][0] + 0.03:
            return 0.0
        i = max(0, min(len(s) - 2, next((k for k in range(len(s) - 1) if s[k + 1][0] >= x), len(s) - 2)))
        a, b = s[i], s[i + 1]
        t = min(1.0, max(0.0, (x - a[0]) / max(b[0] - a[0], 1e-6)))

        def at(sec):
            u = (y - sec[1]) / sec[2]
            return sec[3] * self.shape(u) if 0.0 <= u <= 1.0 else 0.0
        return at(a) * (1.0 - t) + at(b) * t

    def ground(self):
        """(x0, x1, y0, y1): the ground it stands on."""
        s = self.sections
        return s[0][0], s[-1][0], min(q[1] for q in s), max(q[1] + q[2] for q in s)


def light_at(name, x, up):
    """How lit the picture is round screen point (x, up), 0-1, or None off the rock."""
    x0, up0, rows = rock_shapes.LIGHT[name]
    r, c = int(round((up0 - up) * 8.0)), int(round((x - x0) * 8.0))
    if r < 0 or r >= len(rows) or c < 0 or c >= len(rows[r]) or rows[r][c] == ".":
        return None
    return DIGITS.index(rows[r][c]) / 31.0


def blocks(m, name, sil, spacing, mat, tilt=0.5, sink=0.08, low=0.05, vary=0.15, lean=0.1):
    """The rock as a heap of angular columns (column(): tapered prisms with bevelled, tipped tops),
    each standing on the ground where the silhouette has rock, as high as the silhouette there
    (`vary`: give or take), leaning a little outwards, its top tipped towards Factorio's light as
    far as the picture shows that spot lit (`tilt`): the pictures' blocks, their lit tops and
    shaded sides, low ones round the foot where the height runs out. Returns how many."""
    rng = m.rng
    x0, x1, y0, y1 = sil.ground()
    xc, yc = (x0 + x1) / 2, (y0 + y1) / 2
    seeds = []
    for _ in range(4000):
        p = (rng.uniform(x0, x1), rng.uniform(y0, y1))
        gap = spacing * rng.uniform(0.8, 1.2)
        inside = all(sil.height(p[0] + dx, p[1] + dy) > 0.0 for dx, dy in
                     ((gap * 0.5, 0.0), (-gap * 0.5, 0.0), (0.0, gap * 0.5), (0.0, -gap * 0.5)))
        if inside and sil.height(*p) > low and all(math.hypot(p[0] - q[0], p[1] - q[1]) > gap for q in seeds):
            seeds.append(p)
    seeds.sort(key=lambda p: -sil.height(*p))
    for x, y in seeds:
        # (A column's top shows a little under its height: its cap is bevelled and tipped.)
        h = sil.height(x, y) * 1.12 * rng.uniform(1.0 - vary, 1.0 + vary * 0.4)
        out = Vector((x - xc, y - yc, 0.0))
        out = out.normalized() if out.length > 1e-3 else Vector((1.0, 0.0, 0.0))
        lit = light_at(name, x, SIN_P * y + COS_P * h)
        tip = (lit - 0.5) * 2.0 * tilt if lit is not None else 0.0
        column(m, (x, y, 0.0), spacing * rng.uniform(0.72, 0.88), max(h, low), mat,
               lean=(out.x * h * lean, out.y * h * lean), tint=(rng.uniform(0.82, 1.0),) * 3, sink=sink,
               cap_tilt=(LIGHT.x * tip, LIGHT.y * tip))
    # A low, broken foot under it all, over the ground the silhouette covers: the pictures' heaps
    # stand on a solid apron of rubble.
    foot = m.blob((xc, yc, 0.0), 1.0, mat, scale=((x1 - x0) * 0.4, (y1 - y0) * 0.4, max(0.12, sil.height(xc, yc) * 0.22)),
                  jitter=0.15, subdiv=2, flat_bottom=-0.05, tint=(0.78, 0.78, 0.78), vary=0.25, tilt=0.0)
    m.chop(foot, Vector((xc, yc, 0.0)), [((0.0, 0.0, 1.0), 0.7)])
    return len(seeds)


def mound(m, sil, mat, step=0.1, jitter=0.16, smooth=2, sink=0.06):
    """The rock as one rounded mass over its silhouette's heights: a height field, smoothed and
    roughened with noise, its rim pulled down into the ground."""
    x0, x1, y0, y1 = sil.ground()
    nx, ny = int((x1 - x0) / step) + 3, int((y1 - y0) / step) + 3
    grid = [[sil.height(x0 + (i - 1) * step, y0 + (j - 1) * step) for j in range(ny)] for i in range(nx)]
    for _ in range(smooth):
        g2 = [row[:] for row in grid]
        for i in range(1, nx - 1):
            for j in range(1, ny - 1):
                if grid[i][j] > 0.0:
                    g2[i][j] = (4 * grid[i][j] + grid[i - 1][j] + grid[i + 1][j] + grid[i][j - 1] + grid[i][j + 1]) / 8.0
        grid = g2
    seed = Vector((m.rng.uniform(-50, 50), m.rng.uniform(-50, 50), 0.0))
    verts = {}

    def vert(i, j):
        v = verts.get((i, j))
        if v is None:
            x, y, z = x0 + (i - 1) * step, y0 + (j - 1) * step, grid[i][j]
            if z > 0.0:
                z += jitter * (noise.noise(Vector((x * 1.4, y * 1.4, z * 1.4)) + seed)
                               + 0.5 * noise.noise(Vector((x * 3.7, y * 3.7, z * 3.7)) + seed)) * min(1.0, z * 3.0)
            else:
                z = -sink
                # On the ground beside the rock: half a step in, so the foot isn't a staircase.
                near = [(di, dj) for di in (-1, 0, 1) for dj in (-1, 0, 1)
                        if (di or dj) and 0 <= i + di < nx and 0 <= j + dj < ny and grid[i + di][j + dj] > 0.0]
                if near:
                    # To where the rock meets the ground, towards the rock beside it.
                    dx = sum(d[0] for d in near) / len(near) * step
                    dy = sum(d[1] for d in near) / len(near) * step
                    lo, hi = 0.0, 1.0
                    for _ in range(8):
                        mid = (lo + hi) / 2
                        lo, hi = (lo, mid) if sil.height(x + dx * mid, y + dy * mid) > 0.0 else (mid, hi)
                    x, y = x + dx * lo, y + dy * lo
            v = m.bm.verts.new((x, y, z))
            verts[(i, j)] = v
        return v
    for i in range(nx - 1):
        for j in range(ny - 1):
            if max(grid[i][j], grid[i + 1][j], grid[i + 1][j + 1], grid[i][j + 1]) <= 0.0:
                continue
            m.bm.faces.new((vert(i, j), vert(i + 1, j), vert(i + 1, j + 1), vert(i, j + 1)))
    m._tag(list(verts.values()), mat, True, None, 0.0)


def shade_rock(m, top, dark=0.3):
    """Dark at the foot and in the cracks, light on top faces, like the pictures."""
    def fn(f, p, n):
        h = min(1.0, max(0.0, p.z / top))
        up = max(0.0, n.z)
        return dark + (1.0 - dark) * min(1.0, 0.15 + 0.45 * h + 0.5 * up)
    m.shade(fn)


def _top(sil):
    return max(s[3] for s in sil.sections)


def big_rock(m):
    """A 2x2 heap of blocky brown stone about a tile high: column-like blocks with flat lit tops,
    standing on low broken slabs round the foot, as in its picture (big-rock-01)."""
    sil = Silhouette("big-rock", 1.9, walls(2.6, apron=0.22))
    blocks(m, "big-rock", sil, 0.42, ROCK)
    shade_rock(m, _top(sil))


def huge_rock(m):
    """A 3x2 outcrop of tall, column-like blocks over one and a half tiles high, their tops chipped,
    in an apron of low slabs, as in its picture (huge-rock-05)."""
    sil = Silhouette("huge-rock", 2.0, walls(3.0, 0.8, apron=0.2))
    blocks(m, "huge-rock", sil, 0.5, ROCK)
    shade_rock(m, _top(sil))


def big_sand_rock(m):
    """A rounded, wind-worn sandstone mass, as in its picture (big-sand-rock-01): its high, bulging
    part at the back right sloping down to a long low lobe at the front left; ochre on top, dark
    red-brown at the foot, banded with the stone's strata."""
    sil = Silhouette("big-sand-rock", 2.0, lambda t: math.sin(math.pi * min(1.0, max(0.0, t))) ** 0.35)
    mound(m, sil, SAND_ROCK, smooth=3)
    top = _top(sil)

    def fn(f, p, n):
        # Dark reddish foot, ochre top, strata a few hand-widths apart, darker in the crevices.
        h = min(1.0, max(0.0, (p.z + 0.05) / (0.9 * top)))
        foot = (0.48, 0.34, 0.28)
        band = 0.9 + 0.1 * math.sin(p.z * 26.0 + 0.6 * math.sin(p.x * 3.0))
        k = (0.7 + 0.3 * max(0.0, n.z)) * band
        return tuple((foot[i] + (1.0 - foot[i]) * h ** 0.8) * k for i in range(3))
    m.shade(fn)


# Nauvis ores, matched to their sprites. Factorio draws an ore tile from one of eight richness
# stages (rows of the sheet, chosen by the tile's amount), each a 2x2-tile picture centred on the
# tile: the richest a dense cluster of about sixteen small, angular, glossy nuggets about a tile
# and a half across, the poorest four or five scattered crumbs, over a sprinkle of reddish dust.
# Three of those stages are modelled (STAGES; the client picks one by the tile's amount,
# model_library.gd ORE_STAGES): "-rich", the plain name (middle) and "-sparse". Nuggets are kept
# small and low-poly: an ore field draws one per tile. The Space Age ores keep their first look.
PATCH = {"iron-ore", "copper-ore", "coal", "stone", "uranium-ore"}
# suffix: (nuggets, radius range, reach, dust flecks)
STAGES = {"-rich": (17, (0.085, 0.15), 0.7, 70), "": (11, (0.08, 0.14), 0.66, 55), "-sparse": (5, (0.065, 0.11), 0.6, 35)}


def ore(name, stage=""):
    chunk_hex, rough, metal, tints, dust_hex = ORES[name]
    chunk = material(name + "-chunk", chunk_hex, rough, metal)
    dust = material(name + "-dust", dust_hex, 1.0)
    patch = name in PATCH

    def build(m):
        rng = m.rng
        if patch:
            count, radii, reach, flecks = STAGES[stage]
        else:
            count, radii, reach, flecks = 12, None, 0.72, 40
        # Dust first: small flat flecks on the ground, denser in the middle.
        for _ in range(flecks):
            r = (reach + 0.05) * math.sqrt(rng.random())
            a = rng.uniform(0.0, math.tau)
            m.disc((math.cos(a) * r, math.sin(a) * r, 0.006), rng.uniform(0.025, 0.06), dust, sides=3, jitter=0.3,
                   tint=(rng.uniform(0.7, 1.0),) * 3)
        # Nuggets: in the sprites they lie in loose bunches of two to four, touching; the bunches
        # spread over the picture.
        placed = []
        tries = 0
        while len(placed) < count and tries < 1500:
            tries += 1
            n = len(placed)
            if patch:
                r = rng.uniform(*radii)
                if placed and rng.random() < 0.55:
                    q, s = rng.choice(placed)  # next to one already there
                    a = rng.uniform(0.0, math.tau)
                    p = q + Vector((math.cos(a), math.sin(a), 0.0)) * (s + r) * rng.uniform(0.9, 1.15)
                    if p.length > reach:
                        continue
                else:
                    d = reach * math.sqrt(rng.random())
                    a = rng.uniform(0.0, math.tau)
                    p = Vector((math.cos(a) * d, math.sin(a) * d, 0.0))
                gap = 0.85
            else:
                r = (0.24, 0.22, 0.2)[n] if n < 3 else rng.uniform(0.1, 0.16)
                lim = 0.4 if n < 3 else reach
                d = lim * math.sqrt(rng.random())
                a = rng.uniform(0.0, math.tau)
                p = Vector((math.cos(a) * d, math.sin(a) * d, 0.0))
                gap = 0.75
            if all((p - q).length > (r + s) * gap for q, s in placed):
                placed.append((p, r))
        for p, r in placed:
            if patch:  # the darker, dusty ground each nugget lies in
                m.disc((p.x + r * 0.2, p.y - r * 0.3, 0.008), r * 1.5, dust, sides=6, jitter=0.25,
                       tint=(rng.uniform(0.75, 0.9),) * 3)
            c = p + Vector((0, 0, r * (0.4 if patch else 0.25)))
            # Uranium grows as jagged, pointed crystals rather than rounded nuggets.
            shape = (1.0, 0.9, 1.3) if name == "uranium-ore" else (1.2, 0.95, 0.9 if patch else 0.7)
            verts = m.blob(c, r, chunk, scale=shape, jitter=0.45 if name == "uranium-ore" else 0.3,
                           subdiv=1 if patch else 2, flat_bottom=-0.03, tint=rng.choice(tints), vary=0.3)
            # Broken faces make the lumps angular, like the sprites' nuggets.
            m.chop(verts, c, [((rng.uniform(-1, 1), rng.uniform(-1, 1), rng.uniform(0.2, 1.0)), rng.uniform(0.55, 0.8))
                              for _ in range(3)])

        def fn(f, p, n):
            if f.material_index == m.materials.index(dust):
                return 1.0
            return 0.4 + 0.6 * min(1.0, max(0.0, p.z / 0.16)) * (0.55 + 0.45 * max(0.0, n.z))
        m.shade(fn)

    return build


MODELS = {
    "big-rock": big_rock, "huge-rock": huge_rock, "big-sand-rock": big_sand_rock,
    **{name: ore(name) for name in ORES},
    **{name + stage: ore(name, stage) for name in sorted(PATCH) for stage in STAGES if stage},
}
