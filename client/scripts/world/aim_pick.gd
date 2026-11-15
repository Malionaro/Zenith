extends RefCounted
## What a view ray meets first among the world's entities (K7, owner: "first person should target
## the object and not have to look at the ground"). The angled view picks what is under the mouse's
## ground point (world.gd pick()), as Factorio does from above; in first person that meant looking
## down at a machine's foot to act on it, and a belt behind a chest was picked through the chest.
## Here each entity is its Factorio selection box raised from the ground under it to the height its
## model is drawn, and the nearest box the ray enters wins, as a shooter picks.
##
## No physics bodies: models are MultiMesh instances. The ray walks world.gd's pick index (the
## PICK_CELL squares each selection box touches) square by square, nearest first, and stops once
## the next square starts past the best hit, so a frame tests only the entities along the ray.

const WorldMirror := preload("res://scripts/world/world.gd")
const ProtoDB := preload("res://scripts/world/protos.gd")
const ChunkView := preload("res://scripts/world/chunk_view.gd")
const ModelLibrary := preload("res://scripts/world/model_library.gd")
const Visuals := preload("res://scripts/world/visuals.gd")
const GroundHeight := preload("res://scripts/world/ground_height.gd")

## Things that lie under everything else (ore, tile ghosts) are this high, so what stands on them is
## met first; a remnant is the building flattened (model_library.gd REMNANT_SQUASH).
const FLAT := 0.05
const REMNANT := 0.3
## Hits this close (tiles along the ray) count as one place: the smaller box wins, as in pick().
const TIE := 0.01

## Prototype name -> its model's top (tiles), once its model is in.
static var _heights := {}


## The entity the ray from `from` along `dir` meets first within `limit` tiles of it:
## [Rec, distance along the ray, the point hit (Vector3), the face's outward normal (Vector3), its
## selection rect (Rect2)], or []. A box the ray starts in is passed over (the eye in a tree's box,
## standing by its trunk).
static func pick(world: WorldMirror, from: Vector3, dir: Vector3, limit: float) -> Array:
	if world == null or limit <= 0.0:
		return []
	dir = dir.normalized()
	var cell_size := WorldMirror.PICK_CELL
	var reach := world._pick_reach()
	var o := Vector2(from.x, from.z)
	var flat := Vector2(dir.x, dir.z)
	var cell := Vector2i(floori(o.x / cell_size), floori(o.y / cell_size))
	var step := Vector2i(1 if flat.x > 0.0 else -1, 1 if flat.y > 0.0 else -1)
	# Amanatides and Woo: where (in distance along the ray) its ground track crosses the next column
	# and row of squares, and how far apart they are.
	var t_next := Vector2(INF, INF)
	var t_delta := Vector2(INF, INF)
	if absf(flat.x) > 1e-6:
		t_delta.x = cell_size / absf(flat.x)
		t_next.x = ((cell.x + (1 if flat.x > 0.0 else 0)) * cell_size - o.x) / flat.x
	if absf(flat.y) > 1e-6:
		t_delta.y = cell_size / absf(flat.y)
		t_next.y = ((cell.y + (1 if flat.y > 0.0 else 0)) * cell_size - o.y) / flat.y
	var best: Array = []
	var best_t := limit
	var best_area := INF
	var seen := {}
	var t_cell := 0.0
	var cells := 0
	var max_cells := int(limit * flat.length() / cell_size) * 2 + 4
	while t_cell <= best_t + TIE and cells < max_cells:
		cells += 1
		var centre := (Vector2(cell) + Vector2(0.5, 0.5)) * cell_size
		var home := WorldMirror.chunk_of(centre)
		# As pick(): a neighbour's entities reach the square only if it is within `reach` of that chunk.
		var local := centre - Vector2(home * WorldMirror.CHUNK)
		var far := WorldMirror.CHUNK - reach
		for dy in range(-1 if local.y < reach else 0, (1 if local.y > far else 0) + 1):
			for dx in range(-1 if local.x < reach else 0, (1 if local.x > far else 0) + 1):
				var cv: ChunkView = world.chunks.get(home + Vector2i(dx, dy))
				if cv == null:
					continue
				for entry: Array in world._pick_grid(cv).get(cell, []):
					var r: WorldMirror.Rec = entry[0]
					var id := r.get_instance_id()
					if seen.has(id):
						continue
					seen[id] = true
					var rect: Rect2 = entry[1]
					if rect.size.x < 0.01 or rect.size.y < 0.01 or r.extra.has("hid"):
						continue
					var top := height_of(world, r)
					if top <= 0.0:
						continue
					var base := GroundHeight.at(r.pos.x, r.pos.y)
					var hit := ray_box(from, dir, Vector3(rect.position.x, base, rect.position.y),
						Vector3(rect.end.x, base + top, rect.end.y))
					if hit.is_empty():
						continue
					var t: float = hit[0]
					var area := float(entry[2])
					var better := t <= limit if best.is_empty() else (t < best_t - TIE or (t <= best_t + TIE and area < best_area))
					if better:
						best_t = t
						best_area = area
						best = [r, t, from + dir * t, hit[1], rect]
		if t_next.x < t_next.y:
			t_cell = t_next.x
			t_next.x += t_delta.x
			cell.x += step.x
		else:
			t_cell = t_next.y
			t_next.y += t_delta.y
			cell.y += step.y
	return best


## How tall an entity is drawn (tiles above the ground under it): its model's top once the model is
## in (a ghost: what it will build), else the placeholder's (visuals.gd); 0 for what isn't drawn.
static func height_of(world: WorldMirror, r: WorldMirror.Rec) -> float:
	var proto: ProtoDB.EntityProto = world.protos.entity(r.proto_id)
	if proto == null or ModelLibrary.hidden(proto.name):
		return 0.0
	if proto.type == "entity-ghost" and r.extra.has("gh"):
		var inner: ProtoDB.EntityProto = world.protos.entity(int(r.extra["gh"]))
		if inner != null:
			proto = inner
	if proto.type == "resource" or proto.type == "tile-ghost":
		return FLAT
	if ModelLibrary.REMNANT_TYPES.has(proto.type):
		return REMNANT
	var known = _heights.get(proto.name)
	if known != null:
		return float(known)
	# Only a model already read: asking for one here could read it on the main thread.
	var mesh: Mesh = ModelLibrary._cache.get(proto.name)
	if mesh == null:
		return Visuals.height_for(proto)
	var h := maxf(mesh.get_aabb().end.y, FLAT)
	_heights[proto.name] = h
	return h


## A ray against a box (lo, hi corners): [distance along `dir` where it enters, the outward normal
## of the face it enters through], or [] when it misses, the box is behind or the ray starts in it.
static func ray_box(from: Vector3, dir: Vector3, lo: Vector3, hi: Vector3) -> Array:
	var t0 := -INF
	var t1 := INF
	var normal := Vector3.ZERO
	for axis in 3:
		var o: float = from[axis]
		var d: float = dir[axis]
		if absf(d) < 1e-9:
			if o < lo[axis] or o > hi[axis]:
				return []
			continue
		var a: float = (lo[axis] - o) / d
		var b: float = (hi[axis] - o) / d
		var n := -1.0  # going up the axis it comes in through the low face
		if a > b:
			var swap := a
			a = b
			b = swap
			n = 1.0
		if a > t0:
			t0 = a
			normal = Vector3.ZERO
			normal[axis] = n
		t1 = minf(t1, b)
		if t0 > t1:
			return []
	if t0 < 0.0:
		return []
	return [t0, normal]
