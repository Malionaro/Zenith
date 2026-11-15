extends RefCounted
## Factorio's electricity coverage (J4): while an electric pole is held, the supply areas of the poles
## round the cursor and the held pole's own are tinted blue on the ground, one tint wherever any of
## them covers (overlaps don't stack); hovering a pole shows its own. A pole's supply area is its
## prototype's (`eprops` supply, half the square's side) plus a tile each way per quality level.
##
## The poles are read per chunk only when the chunk changed (ChunkView.content_rev), and their union
## is worked out again only when those or the cursor's chunk change: cursor_overlay.gd draws it.

const ProtoDB := preload("res://scripts/world/protos.gd")
const WorldMirror := preload("res://scripts/world/world.gd")
const CursorOverlay := preload("res://scripts/player/cursor_overlay.gd")

## Chunks either side of the cursor's whose poles are shown (a view's worth round the cursor).
const RADIUS := 2
## Quality levels as Factorio's quality prototypes have them; a pole's supply area grows by a tile
## each way per level (the wiki's small pole: 5x5, 7x7, 9x9, 11x11, legendary 15x15).
const QUALITY_LEVEL := {"uncommon": 1, "rare": 2, "epic": 3, "legendary": 5}

var world: WorldMirror
var _chunks := {}  # Vector2i -> [ChunkView's instance id, content_rev, [Rect2, ...]]: the window's poles' areas
var _key := ""
var _union: Array = []


## A pole of `proto_id` in `quality`: half the side of the square it supplies, 0 when none.
static func supply_of(proto_id: int, quality: String, eprops: Dictionary) -> float:
	var s := float(eprops.get(proto_id, {}).get("supply", 0.0))
	return s + float(QUALITY_LEVEL.get(quality, 0)) if s > 0.0 else 0.0


static func area(pos: Vector2, supply: float) -> Rect2:
	return Rect2(pos - Vector2(supply, supply), Vector2(supply, supply) * 2.0)


## The supply area of the pole record `r`, or an empty Rect2 when it isn't a built pole.
func area_of(r: WorldMirror.Rec, eprops: Dictionary) -> Rect2:
	var proto: ProtoDB.EntityProto = world.protos.entity(r.proto_id)
	if proto == null or proto.type != "electric-pole" or r.extra.has("hid"):
		return Rect2()
	var s := supply_of(r.proto_id, str(r.extra.get("q", "normal")), eprops)
	return area(r.pos, s) if s > 0.0 else Rect2()


## The supply areas of the poles in the chunks round `at`, as rectangles that don't overlap.
func around(at: Vector2, eprops: Dictionary) -> Array:
	var c := WorldMirror.chunk_of(at)
	var key := "%s %d" % [c, eprops.size()]
	var rects: Array = []
	var fresh := false
	var kept := {}
	for dy in range(-RADIUS, RADIUS + 1):
		for dx in range(-RADIUS, RADIUS + 1):
			var at_c := c + Vector2i(dx, dy)
			var cv = world.chunks.get(at_c)
			if cv == null:
				key += " -"
				continue
			# By instance id: a chunk sent again is a new ChunkView whose content_rev starts over.
			var seen: Array = _chunks.get(at_c, [])
			if seen.is_empty() or int(seen[0]) != cv.get_instance_id() or int(seen[1]) != int(cv.content_rev):
				var areas: Array = []
				for r: WorldMirror.Rec in cv.entities.values():
					var a := area_of(r, eprops)
					if a.has_area():
						areas.append(a)
				seen = [cv.get_instance_id(), cv.content_rev, areas]
				fresh = true
			kept[at_c] = seen
			key += " %d" % int(seen[1])
			rects.append_array(seen[2])
	_chunks = kept
	if fresh or key != _key:
		_key = key
		_union = CursorOverlay.union_rects(rects)
	return _union


## What the overlay draws while a pole of `proto_id` (in `quality`) is held at `pos`: the poles'
## areas round it and its own, one tint. [] when it supplies nothing.
func held_marks(proto_id: int, quality: String, pos: Vector2, eprops: Dictionary) -> Array:
	var s := supply_of(proto_id, quality, eprops)
	if s <= 0.0:
		return []
	var near := around(pos, eprops)
	var rects := near.duplicate()
	rects.append_array(CursorOverlay.minus(area(pos, s), near))
	return [CursorOverlay.cover(rects)]
