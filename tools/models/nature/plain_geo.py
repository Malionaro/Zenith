"""geo.py without Blender: the same Model, its primitives and the .glb export in plain Python.

trees.py, rocks.py and cliffs.py build into a `geo.Model`; build_plain.py puts this module in
geo's place (with noblender.py's stand-ins for `mathutils`), so the nature models build on a PC
without Blender and export what build_nature.py and Blender's glTF exporter write together: one
mesh, a primitive per material, per-corner normals (smooth faces share their vertices' normal, a
leaf card carries its crown's), corner colours (COLOR_0 rgb, sRGB factors stored linear as
Blender's byte colours export) and the bake (bake.py: COLOR_0 alpha, TEXCOORD_1-3). Run
part_colors.py after it, as after build_nature.py.

The one difference from geo.py: `noise` is a value noise of its own (not Blender's), so a blob's
lumps differ from a Blender build's. And a crown's dark cores (materials "leaf-shadow-...") carry
UV (-1, -1), solid leaves ("leaf-0...": tree-06's strands) UV (-2, -2): that tells the client's
leaf shader a core or solid leaves from a card when they share one merged surface, and its shadow
stand-in which to drop as pollution takes the leaves (factorio_material.gdshaderinc `leaf_kind`,
model_lods.gd crown_arrays).
"""

import json
import math
import os
import struct
import sys

import numpy as np
from mathutils import Matrix, Vector

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(HERE))  # tools/models: bake.py, noblender.py

GENERATOR = "Zenith tools/models/nature/build_plain.py"
CORE_UV = (-1.0, -1.0)
SOLID_LEAF_UV = (-2.0, -2.0)


# --- materials ---------------------------------------------------------------------------------

def _srgb_to_linear(c):
    return c / 12.92 if c <= 0.04045 else ((c + 0.055) / 1.055) ** 2.4


class Material:
    def __init__(self, name, hex_color, roughness, metallic):
        self.name = name
        self.hex = hex_color
        self.roughness = roughness
        self.metallic = metallic
        h = hex_color.lstrip("#")
        self.linear = tuple(_srgb_to_linear(int(h[i:i + 2], 16) / 255.0) for i in (0, 2, 4))

    def __repr__(self):
        return "Material(%s)" % self.name


_MATERIALS = {}


def material(name, hex_color, roughness=0.9, metallic=0.0):
    """A shared material, created once (as geo.material)."""
    if name not in _MATERIALS:
        _MATERIALS[name] = Material(name, hex_color, roughness, metallic)
    return _MATERIALS[name]


# --- noise -------------------------------------------------------------------------------------

def _hash3(x, y, z):
    h = (x * 374761393 + y * 668265263 + z * 2147483647) & 0xffffffff
    h = ((h ^ (h >> 13)) * 1274126177) & 0xffffffff
    return ((h ^ (h >> 16)) & 0xffffff) / float(0x800000) - 1.0


def noise(q):
    """Smooth value noise, about -1..1 (in place of mathutils.noise.noise)."""
    x, y, z = q
    xi, yi, zi = math.floor(x), math.floor(y), math.floor(z)
    fx, fy, fz = x - xi, y - yi, z - zi
    u, v, w = (f * f * (3.0 - 2.0 * f) for f in (fx, fy, fz))

    def lerp(a, b, t):
        return a + (b - a) * t
    c = [[[_hash3(xi + i, yi + j, zi + k) for k in (0, 1)] for j in (0, 1)] for i in (0, 1)]
    return lerp(lerp(lerp(c[0][0][0], c[1][0][0], u), lerp(c[0][1][0], c[1][1][0], u), v),
                lerp(lerp(c[0][0][1], c[1][0][1], u), lerp(c[0][1][1], c[1][1][1], u), v), w)


# --- mesh --------------------------------------------------------------------------------------

class Vert:
    __slots__ = ("co", "link_faces", "index")

    def __init__(self, co, index):
        self.co = Vector(co)
        self.link_faces = []
        self.index = index


class Face:
    __slots__ = ("verts", "material_index", "smooth", "colors", "uvs", "card", "index")

    def __init__(self, verts, index):
        self.verts = list(verts)
        self.material_index = 0
        self.smooth = False
        self.colors = [(1.0, 1.0, 1.0)] * len(self.verts)
        self.uvs = None
        self.card = None  # a leaf card's crown normal
        self.index = index

    @property
    def normal(self):
        n = [0.0, 0.0, 0.0]
        for a, b in zip(self.verts, self.verts[1:] + self.verts[:1]):
            p, q = a.co, b.co
            n[0] += (p.y - q.y) * (p.z + q.z)
            n[1] += (p.z - q.z) * (p.x + q.x)
            n[2] += (p.x - q.x) * (p.y + q.y)
        return Vector(n).normalized()

    def flip(self):
        self.verts.reverse()
        self.colors.reverse()
        if self.uvs is not None:
            self.uvs.reverse()


class _Verts(list):
    def new(self, co=(0.0, 0.0, 0.0)):
        v = Vert(co, len(self))
        self.append(v)
        return v


class _Faces(list):
    def new(self, verts):
        f = Face(verts, len(self))
        for v in f.verts:
            v.link_faces.append(f)
        self.append(f)
        return f


class BMesh:
    def __init__(self):
        self.verts = _Verts()
        self.faces = _Faces()

    def normal_update(self):
        pass


def _vertex_normals(bm, smooth_only=False):
    """Each vertex's normal: its faces' normals weighted by the angle they make there."""
    out = {}
    for f in bm.faces:
        if smooth_only and not f.smooth:
            continue
        n = f.normal
        k = len(f.verts)
        for i, v in enumerate(f.verts):
            a = (f.verts[i - 1].co - v.co).normalized()
            b = (f.verts[(i + 1) % k].co - v.co).normalized()
            ang = math.acos(max(-1.0, min(1.0, a.dot(b))))
            acc = out.get(v.index)
            out[v.index] = n * ang if acc is None else acc + n * ang
    return {i: n.normalized() for i, n in out.items()}


def _aim(direction):
    """Rotation turning +Z towards `direction`."""
    return Vector((0.0, 0.0, 1.0)).rotation_difference(direction.normalized()).to_matrix().to_4x4()


def _icosphere(subdivisions):
    """Blender's create_icosphere: subdivisions 1 is the icosahedron (20 faces), each more splits
    every face in four. Unit radius. Returns (points, faces)."""
    t = (1.0 + math.sqrt(5.0)) / 2.0
    pts = [(-1, t, 0), (1, t, 0), (-1, -t, 0), (1, -t, 0), (0, -1, t), (0, 1, t), (0, -1, -t), (0, 1, -t),
           (t, 0, -1), (t, 0, 1), (-t, 0, -1), (-t, 0, 1)]
    pts = [Vector(p).normalized() for p in pts]
    faces = [(0, 11, 5), (0, 5, 1), (0, 1, 7), (0, 7, 10), (0, 10, 11), (1, 5, 9), (5, 11, 4), (11, 10, 2), (10, 7, 6),
             (7, 1, 8), (3, 9, 4), (3, 4, 2), (3, 2, 6), (3, 6, 8), (3, 8, 9), (4, 9, 5), (2, 4, 11), (6, 2, 10),
             (8, 6, 7), (9, 8, 1)]
    for _ in range(max(0, subdivisions - 1)):
        mid = {}

        def middle(a, b):
            key = (min(a, b), max(a, b))
            if key not in mid:
                mid[key] = len(pts)
                pts.append((pts[a] + pts[b]).normalized())
            return mid[key]
        out = []
        for a, b, c in faces:
            ab, bc, ca = middle(a, b), middle(b, c), middle(c, a)
            out += [(a, ab, ca), (b, bc, ab), (c, ca, bc), (ab, bc, ca)]
        faces = out
    return pts, faces


class Model:
    """One model being built: its mesh and material list (geo.Model's interface)."""

    def __init__(self, name, rng):
        self.name = name
        self.rng = rng
        self.bm = BMesh()
        self.materials = []
        self._up_faces = []
        self._card_faces = []

    def mat(self, material_):
        if material_ not in self.materials:
            self.materials.append(material_)
        return self.materials.index(material_)

    def _tag(self, verts, material_, smooth, tint=None, vary=0.0):
        index = self.mat(material_)
        seen = {}
        for v in verts:
            for f in v.link_faces:
                seen[f.index] = f
        faces = [seen[k] for k in sorted(seen)]
        t = tint or (1.0, 1.0, 1.0)
        for f in faces:
            f.material_index = index
            f.smooth = smooth
            k = 1.0 - self.rng.uniform(0.0, vary) if vary else 1.0
            f.colors = [(t[0] * k, t[1] * k, t[2] * k)] * len(f.verts)
        return faces

    def shade(self, fn):
        """Multiplies every face corner's colour by fn(face, position, normal) (geo.Model.shade)."""
        vn = _vertex_normals(self.bm)
        for f in self.bm.faces:
            fnrm = None if f.smooth else f.normal
            out = []
            for v, c in zip(f.verts, f.colors):
                k = fn(f, v.co, vn.get(v.index, fnrm) if f.smooth else fnrm)
                if not isinstance(k, tuple):
                    k = (k, k, k)
                out.append((c[0] * k[0], c[1] * k[1], c[2] * k[2]))
            f.colors = out

    # --- primitives (as geo.py) ---------------------------------------------------------------

    def blob(self, center, radius, material_, scale=(1.0, 1.0, 1.0), jitter=0.18, subdiv=2,
             flat_bottom=None, spin=None, tint=None, vary=0.0, smooth=False, tilt=0.4):
        rng = self.rng
        spin = rng.uniform(0.0, math.tau) if spin is None else spin
        rot = Matrix.Rotation(spin, 4, "Z") @ Matrix.Rotation(rng.uniform(-tilt, tilt), 4, "X")
        seed = Vector((rng.uniform(-100, 100), rng.uniform(-100, 100), rng.uniform(-100, 100)))
        pts, tris = _icosphere(subdiv)
        verts = [self.bm.verts.new((0.0, 0.0, 0.0)) for _ in pts]
        sx, sy, sz = scale
        for v, d in zip(verts, pts):
            n = noise(d * 1.7 + seed)
            r = radius * (1.0 + jitter * n + jitter * 0.5 * rng.uniform(-1.0, 1.0))
            p = rot @ Vector((d.x * sx, d.y * sy, d.z * sz))
            v.co = Vector(center) + p * r
            if flat_bottom is not None and v.co.z < flat_bottom:
                v.co.z = flat_bottom
        for a, b, c in tris:
            self.bm.faces.new((verts[a], verts[b], verts[c]))
        self._tag(verts, material_, smooth, tint, vary)
        return verts

    def chop(self, verts, center, planes):
        c = Vector(center)
        for normal, fraction in planes:
            n = Vector(normal).normalized()
            extent = max((v.co - c).dot(n) for v in verts)
            limit = extent * fraction
            for v in verts:
                d = (v.co - c).dot(n)
                if d > limit:
                    v.co = v.co - n * (d - limit)

    def disc(self, center, radius, material_, sides=10, jitter=0.12, tint=None):
        c = Vector(center)
        a0 = self.rng.uniform(0.0, math.tau)
        verts = []
        for k in range(sides):
            a = a0 + k / sides * math.tau
            r = radius * (1.0 + self.rng.uniform(-jitter, jitter))
            verts.append(self.bm.verts.new(c + Vector((math.cos(a) * r, math.sin(a) * r, 0.0))))
        self._up_faces.append(self.bm.faces.new(verts))
        self._tag(verts, material_, False, tint)
        return verts

    def cone(self, base, height, radius, material_, segments=7, top_radius=0.0, jitter=0.0,
             tilt=(0.0, 0.0), tint=None, vary=0.0):
        rng = self.rng
        m = (Matrix.Translation(Vector(base))
             @ Matrix.Rotation(tilt[0], 4, "X") @ Matrix.Rotation(tilt[1], 4, "Y")
             @ Matrix.Rotation(rng.uniform(0.0, math.tau), 4, "Z")
             @ Matrix.Translation((0.0, 0.0, height / 2.0)))
        bm = self.bm

        def ring(r, z):
            return [bm.verts.new(m @ Vector((r * math.cos(math.tau * i / segments), r * math.sin(math.tau * i / segments), z)))
                    for i in range(segments)]
        lo = ring(radius, -height / 2.0)
        verts = list(lo)
        bottom = bm.verts.new(m @ Vector((0.0, 0.0, -height / 2.0)))
        verts.append(bottom)
        if top_radius > 0.0:
            hi = ring(top_radius, height / 2.0)
            top = bm.verts.new(m @ Vector((0.0, 0.0, height / 2.0)))
            verts += hi + [top]
            for i in range(segments):
                j = (i + 1) % segments
                bm.faces.new((lo[i], lo[j], hi[j], hi[i]))
                bm.faces.new((hi[i], hi[j], top))
        else:
            tip = bm.verts.new(m @ Vector((0.0, 0.0, height / 2.0)))
            verts.append(tip)
            for i in range(segments):
                bm.faces.new((lo[i], lo[(i + 1) % segments], tip))
        for i in range(segments):
            bm.faces.new((lo[(i + 1) % segments], lo[i], bottom))
        if jitter:
            for v in verts:
                v.co = v.co + Vector((rng.uniform(-1, 1), rng.uniform(-1, 1), rng.uniform(-0.5, 0.5))) * jitter
        self._tag(verts, material_, False, tint, vary)
        return verts

    def tube(self, points, radii, material_, segments=6, smooth=True, cap_start=False, tint=None, profile=None):
        bm = self.bm
        rings = []
        ref = Vector((1.0, 0.0, 0.0))
        twist = self.rng.uniform(0.0, math.tau)
        pts = [Vector(p) for p in points]
        shades = {}
        for i, p in enumerate(pts):
            if i == 0:
                t = pts[1] - pts[0]
            elif i == len(pts) - 1:
                t = pts[-1] - pts[-2]
            else:
                t = (pts[i + 1] - pts[i]).normalized() + (pts[i] - pts[i - 1]).normalized()
            t.normalize()
            side = ref - t * ref.dot(t)
            if side.length < 1e-4:
                side = Vector((0.0, 1.0, 0.0)) - t * t.y
            side.normalize()
            ref = side
            up = t.cross(side)
            r = radii[i]
            if r <= 0.0:
                rings.append([bm.verts.new(p)])
                continue
            ring = []
            for k in range(segments):
                a = twist + k / segments * math.tau
                f = 1.0
                if profile is not None:
                    f, c = profile(i, k, a)
                ring.append(bm.verts.new(p + (side * math.cos(a) + up * math.sin(a)) * r * f))
                if profile is not None:
                    shades[ring[-1].index] = c
            rings.append(ring)
        all_verts = []
        for a, b in zip(rings, rings[1:]):
            all_verts += a
            if len(b) == 1:
                for k in range(segments):
                    bm.faces.new((a[k], a[(k + 1) % segments], b[0]))
            else:
                for k in range(segments):
                    bm.faces.new((a[k], a[(k + 1) % segments], b[(k + 1) % segments], b[k]))
        all_verts += rings[-1]
        if len(rings[-1]) > 1:
            bm.faces.new(rings[-1])
        if cap_start:
            bm.faces.new(list(reversed(rings[0])))
        faces = self._tag(all_verts, material_, smooth, tint)
        if shades:
            for f in faces:
                f.colors = [(c[0] * shades.get(v.index, 1.0), c[1] * shades.get(v.index, 1.0), c[2] * shades.get(v.index, 1.0))
                            for v, c in zip(f.verts, f.colors)]
        return all_verts

    def card(self, center, size, facing, material_, tint=None, spin=None, normal=None, stretch=1.0):
        bm = self.bm
        f = Vector(facing).normalized()
        spin = self.rng.uniform(0.0, math.tau) if spin is None else spin
        rot = _aim(f) @ Matrix.Rotation(spin, 4, "Z")
        h = size / 2.0
        corners = [Vector((-h, -h * stretch, 0.0)), Vector((h, -h * stretch, 0.0)), Vector((h, h * stretch, 0.0)),
                   Vector((-h, h * stretch, 0.0))]
        verts = [bm.verts.new(Vector(center) + (rot @ c)) for c in corners]
        face = bm.faces.new(verts)
        face.uvs = [(0.0, 0.0), (1.0, 0.0), (1.0, 1.0), (0.0, 1.0)]
        face.card = Vector(normal or f).normalized()
        self._card_faces.append((face, f))
        self._tag(verts, material_, False, tint)
        return face

    def triangles(self):
        return sum(len(f.verts) - 2 for f in self.bm.faces)

    # --- output -------------------------------------------------------------------------------

    def _orient(self):
        """Winding made consistent within each piece and outward by its signed volume (as
        bmesh.ops.recalc_face_normals), then discs up and cards towards their facing."""
        faces = list(self.bm.faces)
        by_edge = {}
        for f in faces:
            for a, b in zip(f.verts, f.verts[1:] + f.verts[:1]):
                by_edge.setdefault(frozenset((a.index, b.index)), []).append(f)
        seen = set()
        for start in faces:
            if start.index in seen:
                continue
            seen.add(start.index)
            piece, stack = [start], [start]
            while stack:
                f = stack.pop()
                for a, b in zip(f.verts, f.verts[1:] + f.verts[:1]):
                    for g in by_edge[frozenset((a.index, b.index))]:
                        if g.index in seen:
                            continue
                        if any(c is a and d is b for c, d in zip(g.verts, g.verts[1:] + g.verts[:1])):
                            g.flip()
                        seen.add(g.index)
                        piece.append(g)
                        stack.append(g)
            volume = 0.0
            for f in piece:
                o = f.verts[0].co
                for b, c in zip(f.verts[1:], f.verts[2:]):
                    volume += o.dot(b.co.cross(c.co))
            if volume < 0:
                for f in piece:
                    f.flip()
        for f in self._up_faces:
            if f.normal.z < 0.0:
                f.flip()
        for f, facing in self._card_faces:
            if f.normal.dot(facing) < 0.0:
                f.flip()

    def export(self, path):
        import bake
        import noblender
        self._orient()
        vn = _vertex_normals(self.bm, smooth_only=True)
        cores = {i for i, m in enumerate(self.materials) if m.name.startswith("leaf-shadow")}
        solid = {i for i, m in enumerate(self.materials) if m.name.startswith("leaf-0")}
        tris, nrms, cols, uvs, mats, widths = [], [], [], [], [], []
        for f in self.bm.faces:
            fn = f.normal
            pts = [v.co.v for v in f.verts]
            width = bake.polygon_width(pts)
            for i, j, k in noblender._triangles(pts, np.array(fn.v)):
                corner = (i, j, k)
                tris.append([pts[c] for c in corner])
                if f.card is not None:
                    nrms.append([f.card.v] * 3)
                elif f.smooth:
                    nrms.append([vn.get(f.verts[c].index, fn).v for c in corner])
                else:
                    nrms.append([fn.v] * 3)
                cols.append([f.colors[c] for c in corner])
                if f.material_index in cores:
                    uvs.append([CORE_UV] * 3)
                elif f.material_index in solid:
                    uvs.append([SOLID_LEAF_UV] * 3)
                elif f.uvs is not None:
                    uvs.append([(f.uvs[c][0], 1.0 - f.uvs[c][1]) for c in corner])
                else:
                    uvs.append([(0.0, 1.0)] * 3)
                mats.append(f.material_index)
                widths.append(width)
        tris = np.array(tris, dtype=np.float64)
        nrms = np.array(nrms, dtype=np.float64)
        cols = np.array(cols, dtype=np.float64)
        uvs = np.array(uvs, dtype=np.float64)
        mats = np.array(mats, dtype=np.int64)
        ao, edge, part, vis = bake.bake(tris, nrms, up=2, width=np.array(widths), views=bake.factorio_views(up=2))
        lin = np.where(cols <= 0.04045, cols / 12.92, ((np.clip(cols, 0.0, None) + 0.055) / 1.055) ** 2.4)
        _write_glb(path, self.name, self.materials, tris, nrms, lin, ao, uvs, edge, part, vis, mats)


def _order(materials):
    """Materials in the file: wood and stone first, then leaf cards, then the crowns' cores, so a
    merged leaf surface takes its card material's name (model_library.gd)."""
    def rank(i):
        n = materials[i].name
        return 2 if n.startswith("leaf-shadow") else (1 if n.startswith("leafcard") else 0)
    return sorted(range(len(materials)), key=lambda i: (rank(i), i))


def _write_glb(path, name, materials, tris, nrms, lin, ao, uvs, edge, part, vis, mats):
    blob, views, accessors = bytearray(), [], []

    def add(array, kind, component, target):
        data = np.ascontiguousarray(array)
        while len(blob) % 4:
            blob.append(0)
        views.append({"buffer": 0, "byteOffset": len(blob), "byteLength": data.nbytes, "target": target})
        blob.extend(data.tobytes())
        acc = {"bufferView": len(views) - 1, "componentType": component, "count": len(data), "type": kind}
        if kind == "VEC3" and component == 5126:
            acc["min"] = [float(c) for c in data.min(axis=0)]
            acc["max"] = [float(c) for c in data.max(axis=0)]
        accessors.append(acc)
        return len(accessors) - 1

    prims, out_mats = [], []
    for mi in _order(materials):
        pick = np.nonzero(mats == mi)[0]
        if not len(pick):
            continue
        m = materials[mi]
        out_mats.append({"doubleSided": True, "name": m.name,
                         "pbrMetallicRoughness": {"baseColorFactor": [*m.linear, 1.0], "metallicFactor": float(m.metallic),
                                                  "roughnessFactor": float(m.roughness)}})
        p = tris[pick].reshape(-1, 3)
        n = nrms[pick].reshape(-1, 3)
        rows = np.concatenate([
            np.stack([p[:, 0], p[:, 2], -p[:, 1]], axis=1),
            np.stack([n[:, 0], n[:, 2], -n[:, 1]], axis=1),
            uvs[pick].reshape(-1, 2),
            np.stack([edge[pick].reshape(-1), np.repeat(part[pick], 3)], axis=1),
            vis[pick][..., 0:2].reshape(-1, 2),
            vis[pick][..., 2:4].reshape(-1, 2),
            lin[pick].reshape(-1, 3),
            ao[pick].reshape(-1, 1),
        ], axis=1).astype(np.float32)
        unique, inverse = np.unique(rows, axis=0, return_inverse=True)
        inverse = inverse.reshape(-1)
        attrs = {"POSITION": add(unique[:, 0:3], "VEC3", 5126, 34962),
                 "NORMAL": add(unique[:, 3:6], "VEC3", 5126, 34962),
                 "TEXCOORD_0": add(unique[:, 6:8], "VEC2", 5126, 34962),
                 "TEXCOORD_1": add(unique[:, 8:10], "VEC2", 5126, 34962),
                 "TEXCOORD_2": add(unique[:, 10:12], "VEC2", 5126, 34962),
                 "TEXCOORD_3": add(unique[:, 12:14], "VEC2", 5126, 34962),
                 "COLOR_0": add(unique[:, 14:18], "VEC4", 5126, 34962)}
        prims.append({"attributes": attrs, "indices": add(inverse.astype(np.uint32), "SCALAR", 5125, 34963),
                      "material": len(out_mats) - 1, "mode": 4})
    while len(blob) % 4:
        blob.append(0)
    doc = {"asset": {"generator": GENERATOR, "version": "2.0"}, "scene": 0,
           "scenes": [{"name": "Scene", "nodes": [0]}], "nodes": [{"name": name, "mesh": 0}],
           "materials": out_mats, "meshes": [{"name": name, "primitives": prims}], "accessors": accessors,
           "bufferViews": views, "buffers": [{"byteLength": len(blob)}]}
    text = json.dumps(doc, separators=(",", ":")).encode()
    text += b" " * ((4 - len(text) % 4) % 4)
    total = 12 + 8 + len(text) + 8 + len(blob)
    with open(path, "wb") as f:
        f.write(struct.pack("<III", 0x46546C67, 2, total))
        f.write(struct.pack("<II", len(text), 0x4E4F534A) + text)
        f.write(struct.pack("<II", len(blob), 0x004E4942) + bytes(blob))


# --- geo.py's helpers --------------------------------------------------------------------------

def bend(points, rng, amount):
    out = [Vector(points[0])]
    for p in points[1:-1]:
        out.append(Vector(p) + Vector((rng.uniform(-amount, amount), rng.uniform(-amount, amount), 0.0)))
    out.append(Vector(points[-1]))
    return out


def branch_path(start, direction, length, steps, rng, droop=0.0, wobble=0.08):
    d = Vector(direction).normalized()
    pts = [Vector(start)]
    for i in range(1, steps + 1):
        f = i / steps
        p = Vector(start) + d * (length * f)
        p.z -= droop * f * f
        if i < steps:
            p = p + Vector((rng.uniform(-wobble, wobble), rng.uniform(-wobble, wobble), rng.uniform(-wobble, wobble)))
        pts.append(p)
    return pts


def polar(angle, elevation):
    c = math.cos(elevation)
    return Vector((math.cos(angle) * c, math.sin(angle) * c, math.sin(elevation)))
