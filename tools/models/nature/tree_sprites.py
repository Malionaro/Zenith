"""Factorio's tree and rock sprites, read from the player's install, for the nature tools.

Trees (data/base/prototypes/entity/trees.lua): each of the nine types has 8 to 12 variations, the
first (a) its tallest, the last ones younger and smaller and, for six types, k and l fallen over;
each tree prototype (tree-01, tree-08-brown...) weights them (`variation_weights`, else evenly) and
tints its leaves with one of its `colors` at random. `variations()` measures each variation from its
leaves and trunk pictures (how tall and wide it stands against "a", or how a fallen one lies),
`tints()` reads the colours, `leaf_atlas()` cuts the patches of leaves the client's leaf cards wear
(nature_looks.gd does the same at runtime; this is its reference and the previews' copy).

Only numbers measured here go into the repo (client/data/tree_looks.json, tree_looks.py); pictures
made from the sprites stay in the git-ignored art-src/.
"""

import functools
import math
import os
import re
import sys

import numpy as np
from PIL import Image

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))))
import factorio_install  # noqa: E402

PX = 64.0  # HR pixels a tile (scale 0.5)
# The leaf atlas (nature_looks.gd ATLAS_CELLS, the data's patch): cells per side and each patch's size in
# sprite pixels. A patch covers a card's square (0..1 UV): 36 px is 0.56 tiles, about the cards'
# middle size (trees.py clump_crown, 0.55), so leaves are drawn at the sprite's own size.
ATLAS_CELLS = 4
PATCH = 36


def data_dir():
    return os.path.join(factorio_install.install(), "data")


@functools.lru_cache(maxsize=None)
def _trees_lua():
    with open(os.path.join(data_dir(), "base", "prototypes", "entity", "trees.lua"), encoding="utf-8") as f:
        return f.read()


@functools.lru_cache(maxsize=None)
def tree_types():
    """{"01": [{"trunk": (w, h, sx, sy), "leaves": ..., ...} per variation]} from `tree_types`."""
    src = _trees_lua()
    body = src[src.index("local tree_types"):src.index("local tree_data")]
    out, cur = {}, None
    pat = (r"-- tree-(\d\d)|(trunk|stump|shadow|leaves|normal)\s*=\s*\{\s*width\s*=\s*(\d+),\s*height\s*=\s*(\d+),"
           r"\s*shift\s*=\s*util\.by_pixel\(([-\d.]+),\s*([-\d.]+)\)")
    for m in re.finditer(pat, body):
        if m.group(1):
            cur = out.setdefault(m.group(1), [])
            continue
        if m.group(2) == "trunk":
            cur.append({})
        cur[-1][m.group(2)] = tuple(float(x) for x in m.groups()[2:])
    return out


def _table(src, start):
    """The text of the Lua table opening at src[start] ('{'), braces matched."""
    depth = 0
    for i in range(start, len(src)):
        if src[i] == "{":
            depth += 1
        elif src[i] == "}":
            depth -= 1
            if depth == 0:
                return src[start:i + 1]
    raise ValueError("unbalanced table")


@functools.lru_cache(maxsize=None)
def prototypes():
    """{"tree-01": {"type": "01", "weights": [...] or None, "colors": [(r, g, b) 0-255, ...]}}."""
    src = _trees_lua()
    start = src.index("define_trees{")
    body = _table(src, src.index("{", start))
    out = {}
    i = 1
    while True:
        j = body.find("{", i)
        if j < 0:
            break
        entry = _table(body, j)
        i = j + len(entry)
        t = re.search(r"\btype\s*=\s*(\d+)", entry)
        if not t:
            continue
        ident = re.search(r"identifier\s*=\s*\"(\w+)\"", entry)
        weights = re.search(r"variation_weights\s*=\s*\{([^}]*)\}", entry)
        cols = entry[entry.index("colors"):]
        cols = _table(cols, cols.index("{"))
        name = "tree-%02d" % int(t.group(1)) + ("-" + ident.group(1) if ident else "")
        out[name] = {
            "type": "%02d" % int(t.group(1)),
            "weights": [float(w) for w in weights.group(1).split(",")] if weights else None,
            "colors": [tuple(int(v) for v in c) for c in re.findall(r"r\s*=\s*(\d+),\s*g\s*=\s*(\d+),\s*b\s*=\s*(\d+)", cols)],
            "enabled": "enabled = true" in entry,
        }
    return out


def tree_type(model_name):
    m = re.match(r"tree-(\d\d)", model_name or "")
    return m.group(1) if m else None


def tints(name):
    """The prototype's leaf colours, 0-1 sRGB, as Factorio multiplies its leaves by one of them."""
    return [tuple(c / 255.0 for c in col) for col in prototypes()[name]["colors"]]


def relative_tints(tree, name=None):
    """Each of the prototype's colours over their mean (linear light): the trees.py leaf materials
    are already the mean tint's colour, so a tree is drawn in colour i by multiplying by this."""
    name = name if name in prototypes() else "tree-" + tree
    cols = np.array(tints(name))
    lin = np.where(cols <= 0.04045, cols / 12.92, ((cols + 0.055) / 1.055) ** 2.4)
    rel = lin / lin.mean(0)
    return [tuple(float(v) for v in r) for r in rel]


def picture(tree, letter, part):
    """One frame (the first) of a variation's picture: float RGBA, and its (w, h, shift x, y)."""
    var = tree_types()[tree][ord(letter) - 97]
    w, h, sx, sy = var[part]
    path = os.path.join(data_dir(), "base", "graphics", "entity", "tree", tree, "tree-%s-%s-%s.png" % (tree, letter, part))
    im = np.asarray(Image.open(path).convert("RGBA"), dtype=np.float64) / 255.0
    return im[:int(h), :int(w)], (w, h, sx, sy)


def _extent(alpha, w, h, sx, sy, cut=0.15):
    """(left, right, bottom, top) in tiles from the entity's position (up the screen positive)."""
    ys, xs = np.nonzero(alpha > cut)
    to_x = lambda px: (px - w / 2) / PX + sx / 32.0  # noqa: E731
    to_up = lambda py: -((py - h / 2) / PX + sy / 32.0)  # noqa: E731
    return to_x(xs.min()), to_x(xs.max() + 1), to_up(ys.max() + 1), to_up(ys.min())


def _axis(alpha):
    """The angle of an alpha mask's long axis on the screen, degrees from horizontal (0-180),
    and how much longer than wide it is."""
    ys, xs = np.nonzero(alpha > 0.3)
    pts = np.c_[xs - xs.mean(), -(ys - ys.mean())]
    val, vec = np.linalg.eigh(np.cov(pts.T))
    major = vec[:, 1]
    return math.degrees(math.atan2(major[1], major[0])) % 180.0, math.sqrt(val[1] / max(val[0], 1e-9))


@functools.lru_cache(maxsize=None)
def variations(tree):
    """Per variation: {"letter", "leaves": extent, "trunk": extent, "fallen": bool, "lean": degrees
    of the trunk's long axis from the ground on the screen}. A variation is fallen when its trunk
    lies more across the screen than up it."""
    out = []
    for i, var in enumerate(tree_types()[tree]):
        letter = chr(97 + i)
        leaves, lg = picture(tree, letter, "leaves")
        trunk, tg = picture(tree, letter, "trunk")
        angle, long = _axis(trunk[..., 3])
        lean = angle if angle <= 90.0 else 180.0 - angle
        out.append({
            "letter": letter,
            "leaves": _extent(leaves[..., 3], *lg),
            "trunk": _extent(trunk[..., 3], *tg),
            "fallen": lean < 60.0 and long > 1.6,
            "lean": lean,
        })
    return out


def _lin(c):
    return np.where(c <= 0.04045, c / 12.92, ((c + 0.055) / 1.055) ** 2.4)


LUMA = np.array([0.2126, 0.7152, 0.0722])
# A leaves picture's pixel is a leaf when it is nearly opaque: the picture also holds the trunk's
# shadow on the crown, dark and half see-through, which is neither picked nor cut out.
LEAF_ALPHA = 0.85


def crown_mean(img):
    """The mean colour of a leaves picture's leaves, linear."""
    leaf = img[..., 3] > LEAF_ALPHA
    return _lin(img[..., :3])[leaf].mean(0)


@functools.lru_cache(maxsize=None)
def leaf_patches(tree, letter="a"):
    """Centres (x, y, in the picture's pixels) of the ATLAS_CELLS^2 patches of PATCH pixels the
    client's leaf cards wear: where the crown is full but not solid (its leaves and the dark gaps
    between them), away from the trunk's shadow and the washed-out rim, spread over the crown
    (each next one the candidate furthest from those taken, fuller ones first)."""
    img, _ = picture(tree, letter, "leaves")
    leaf = img[..., 3] > LEAF_ALPHA
    if leaf.sum() < PATCH * PATCH:
        return []  # tree-06's strands: no full crown to cut from
    lum = _lin(img[..., :3]) @ LUMA
    mean_lum = float(crown_mean(img) @ LUMA)
    h, w = leaf.shape
    r = PATCH // 2
    yy, xx = np.mgrid[-r:r, -r:r] + 0.5
    disk = (xx * xx + yy * yy) <= r * r
    cands = []
    for cy in range(r, h - r, 3):
        for cx in range(r, w - r, 3):
            win = leaf[cy - r:cy + r, cx - r:cx + r]
            cover = win[disk].mean()
            if not 0.6 <= cover <= 0.9:
                continue
            l = lum[cy - r:cy + r, cx - r:cx + r][disk & win].mean() / max(mean_lum, 1e-6)
            if not 0.6 <= l <= 2.0:
                continue
            cands.append((cx, cy, cover))
    n = ATLAS_CELLS * ATLAS_CELLS
    if not cands:
        return []
    c = np.array([(x, y) for x, y, _ in cands], dtype=np.float64)
    score = np.array([cv for _, _, cv in cands])
    picks = [int(np.argmax(score))]
    dist = np.linalg.norm(c - c[picks[0]], axis=1)
    while len(picks) < min(n, len(cands)):
        k = int(np.argmax(dist + 6.0 * score))
        picks.append(k)
        dist = np.minimum(dist, np.linalg.norm(c - c[k], axis=1))
    return [(cands[k][0], cands[k][1]) for k in picks]


# The high pass's box blur (texels either way, twice) and how far bright leaves reach past the
# spray's round edge (and dark gaps fall short of it), in its radius.
BLUR = 3
EDGE = 0.8
# The picture's light and shade at this power of its linear contrast (1/2.2: as in gamma space).
CONTRAST = float(os.environ.get("F3D_LEAF_CONTRAST", 0.8))


def _box(a, r):
    """A box blur of `r` texels either way, run twice (near a Gaussian), edges clamped."""
    for _ in range(2):
        for axis in (0, 1):
            pad = [(0, 0)] * a.ndim
            pad[axis] = (r, r)
            p = np.pad(a, pad, mode="edge")
            c = np.cumsum(p, axis=axis)
            c = np.concatenate([np.zeros_like(np.take(c, [0], axis=axis)), c], axis=axis)
            n = a.shape[axis]
            a = (np.take(c, np.arange(2 * r + 1, 2 * r + 1 + n), axis=axis) - np.take(c, np.arange(0, n), axis=axis)) / (2 * r + 1)
    return a


def leaf_atlas(tree, letter="a"):
    """The client's leaf atlas (nature_looks.gd `atlas`, the same steps, for the previews): each
    patch cut to a round spray whose edge follows the leaves (bright leaves reach further out than
    the dark gaps), its colour stored as its ratio to the crown's mean colour in gamma space (the
    linear ratio to the power 1/2.2: the picture's painted light at half its strength, as the model
    is lit again), scaled to a mean of 1 over the leaves kept, halved (the shader doubles it).
    (RGBA float, cells)."""
    img, _ = picture(tree, letter, "leaves")
    mean = crown_mean(img)
    r = PATCH // 2
    yy, xx = np.mgrid[-r:r, -r:r] + 0.5
    d = np.sqrt(xx * xx + yy * yy) / r
    atlas = np.zeros((ATLAS_CELLS * PATCH, ATLAS_CELLS * PATCH, 4))
    picks = leaf_patches(tree, letter)
    for i in range(ATLAS_CELLS * ATLAS_CELLS):
        if not picks:
            break
        cx, cy = picks[i % len(picks)]
        patch = img[cy - r:cy + r, cx - r:cx + r]
        leaf = (patch[..., 3] > LEAF_ALPHA).astype(np.float64)
        ratio = (_lin(patch[..., :3]) / np.maximum(mean, 1e-4)) ** CONTRAST
        # Only the leaves' own light and shade: over the patch's light at a few leaves' scale
        # (the crown's broad light is the model's, and a lit patch beside a shaded one reads as a
        # disk). The mean of the leaves' hue stays.
        local = _box(ratio * leaf[..., None], BLUR) / np.maximum(_box(leaf, BLUR)[..., None], 1e-3)
        ratio = ratio / np.maximum(local @ LUMA, 0.05)[..., None]
        b = np.clip(ratio @ LUMA, 0.0, 2.0) * 0.5
        edge = np.clip((0.92 - d + EDGE * (b - 0.5)) * 10.0, 0.0, 1.0)
        gy, gx = divmod(i, ATLAS_CELLS)
        cell = atlas[gy * PATCH:(gy + 1) * PATCH, gx * PATCH:(gx + 1) * PATCH]
        cell[..., :3] = ratio
        cell[..., 3] = leaf * edge
    kept = atlas[..., 3] >= 0.5
    norm = max(float((atlas[..., :3][kept] @ LUMA).mean()) if kept.any() else 1.0, 1e-3)
    atlas[..., :3] = np.clip(atlas[..., :3] / norm * 0.5, 0.0, 1.0)
    return atlas, ATLAS_CELLS


def reference(model_name, ref, ppt):
    """Factorio's picture of a model as drawn in the game at `ppt` pixels a tile: (float RGBA,
    (entity x, entity y) in its pixels), or None. Trees: trunk and leaves (tinted with the mean of
    the prototype's colours) of variation `ref` (default a); rocks: picture `ref` (default 1)."""
    t = tree_type(model_name)
    if t:
        letter = ref or "a"
        name = model_name if model_name in prototypes() else "tree-" + t
        tint = np.array(tints(name)).mean(0)
        layers = []
        for part in ("trunk", "leaves"):
            img, (w, h, sx, sy) = picture(t, letter, part)
            if part == "leaves":
                img = img.copy()
                img[..., :3] *= tint
            layers.append((img, w, h, sx, sy))
        return _compose(layers, ppt)
    rocks = {"big-rock": ("big-rock", "big-rock-%02d"), "huge-rock": ("huge-rock", "huge-rock-%02d"),
             "big-sand-rock": ("sand-rock", "big-sand-rock-%02d")}
    if model_name in rocks:
        folder, pat = rocks[model_name]
        k = int(ref or (5 if model_name == "huge-rock" else 1))
        path = os.path.join(data_dir(), "base", "graphics", "decorative", folder, pat % k + ".png")
        img = np.asarray(Image.open(path).convert("RGBA"), dtype=np.float64) / 255.0
        shift = rock_shift(model_name, k)
        return _compose([(img, img.shape[1], img.shape[0], shift[0] * 32.0, shift[1] * 32.0)], ppt)
    return None


def rock_shift(name, k):
    src = open(os.path.join(data_dir(), "base", "prototypes", "decorative", "decoratives.lua"), encoding="utf-8").read()
    pat = {"big-rock": "big-rock/big-rock-%02d.png", "huge-rock": "huge-rock/huge-rock-%02d.png",
           "big-sand-rock": "sand-rock/big-sand-rock-%02d.png"}[name] % k
    i = src.index(pat)
    block = src[i:src.index("}", i)]
    m = re.search(r"shift\s*=\s*\{\s*([-\d.]+),\s*([-\d.]+)\s*\}", block)
    return (float(m.group(1)), float(m.group(2))) if m else (0.0, 0.0)


def _compose(layers, ppt):
    k = ppt / PX
    boxes = [(sx * 2 - w / 2, sy * 2 - h / 2, sx * 2 + w / 2, sy * 2 + h / 2) for _, w, h, sx, sy in layers]
    x0 = min(b[0] for b in boxes)
    y0 = min(b[1] for b in boxes)
    x1 = max(b[2] for b in boxes)
    y1 = max(b[3] for b in boxes)
    W, H = int(math.ceil((x1 - x0) * k)), int(math.ceil((y1 - y0) * k))
    canvas = np.zeros((H, W, 4))
    for (img, w, h, sx, sy), b in zip(layers, boxes):
        im = Image.fromarray((np.clip(img, 0, 1) * 255).astype(np.uint8))
        if k != 1.0:
            im = im.resize((max(1, int(round(w * k))), max(1, int(round(h * k)))), Image.LANCZOS)
        a = np.asarray(im, dtype=np.float64) / 255.0
        ox, oy = int(round((b[0] - x0) * k)), int(round((b[1] - y0) * k))
        region = canvas[oy:oy + a.shape[0], ox:ox + a.shape[1]]
        a = a[:region.shape[0], :region.shape[1]]
        al = a[..., 3:4]
        out_a = al + region[..., 3:4] * (1 - al)
        region[..., :3] = (a[..., :3] * al + region[..., :3] * region[..., 3:4] * (1 - al)) / np.maximum(out_a, 1e-6)
        region[..., 3:4] = out_a
    return canvas, (-x0 * k, -y0 * k)


# --- grain for bark and rock (nature_looks.gd's detail layers) ---------------------------------

# A detail layer's size: 64 texels, a tile at the sprites' own scale.
DETAIL = 64
DETAIL_BLUR = 4


def load_file(path):
    """A Factorio file by its "__base__/..." path, float RGBA."""
    rel = path.replace("__base__/", "base/")
    return np.asarray(Image.open(os.path.join(data_dir(), rel)).convert("RGBA"), dtype=np.float64) / 255.0


def opaque_square(alpha, cut=0.95, cap=DETAIL):
    """The largest square (x, y, side) of a picture that is opaque throughout, at most `cap`."""
    a = alpha > cut
    h, w = a.shape
    dp = np.zeros((h + 1, w + 1), dtype=np.int32)
    best = (0, 0, 0)
    for y in range(h):
        row = dp[y + 1]
        up = dp[y]
        for x in range(w):
            if a[y, x]:
                row[x + 1] = min(up[x], up[x + 1], row[x]) + 1
                if row[x + 1] > best[2]:
                    best = (x - row[x + 1] + 1, y - row[x + 1] + 1, int(row[x + 1]))
    x, y, s = best
    s = min(s, cap)
    return (x, y, s)


def bark_strip(alpha, cut=0.95, height=DETAIL, widest=32):
    """A strip of a trunk picture (x, y, w, h) opaque throughout, `height` tall (or as tall as the
    trunk allows), as wide as it can be up to `widest`, from the trunk's middle height: the bark
    between the roots and the crown."""
    a = alpha > cut
    h, w = a.shape
    for width in range(widest, 5, -1):
        for hh in (height, height * 3 // 4, height // 2):
            # Columns x..x+width all opaque on a row: a run of such rows hh long.
            ok = np.zeros((h, w - width + 1), dtype=bool)
            c = np.cumsum(np.c_[np.zeros(h, dtype=np.int32), a.astype(np.int32)], axis=1)
            ok = (c[:, width:] - c[:, :-width]) == width
            runs = np.zeros_like(ok, dtype=np.int32)
            for y in range(h):
                runs[y] = np.where(ok[y], (runs[y - 1] + 1) if y else 1, 0)
            ys, xs = np.nonzero(runs >= hh)
            if len(ys):
                # The one whose middle is nearest the picture's 60% down (above the roots).
                mid = ys - hh / 2
                k = int(np.argmin(np.abs(mid - 0.6 * h)))
                return (int(xs[k]), int(ys[k] - hh + 1), width, hh)
    return None


def _mirror_fill(a, size):
    """A patch mirrored out to size x size (the shader mirrors the layer too: no seams)."""
    h, w = a.shape[:2]
    ys = np.arange(size) % (2 * h)
    ys = np.where(ys < h, ys, 2 * h - 1 - ys)
    xs = np.arange(size) % (2 * w)
    xs = np.where(xs < w, xs, 2 * w - 1 - xs)
    return a[ys][:, xs]


def detail_layer(path, rect):
    """A detail layer (nature_looks.gd `grain_layers`, the same steps): the picture's region, its colour over
    its own light a few texels round (only the grain: the model is shaded on its own), at CONTRAST,
    mirrored out to DETAIL x DETAIL, scaled to a mean of 1 and halved. (DETAIL, DETAIL, 3) floats."""
    img = load_file(path)
    x, y, w, h = rect
    lin = _lin(img[y:y + h, x:x + w, :3])
    mean = lin.reshape(-1, 3).mean(0)
    ratio = (lin / np.maximum(mean, 1e-4)) ** CONTRAST
    local = _box(ratio, DETAIL_BLUR) @ LUMA
    ratio = ratio / np.maximum(local, 0.05)[..., None]
    out = _mirror_fill(ratio, DETAIL)
    out = out / max(float((out @ LUMA).mean()), 1e-3) * 0.5
    return np.clip(out, 0.0, 1.0)
