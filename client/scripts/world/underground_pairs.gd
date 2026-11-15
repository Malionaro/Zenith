extends RefCounted
## Underground belts' and pipes-to-ground's pairs, found in the world mirror as Factorio pairs them:
## the piece one is connected to (J23: R turns both ends), and the piece a held one would join, with
## Factorio's marks for it (J24).
##
## An underground belt's direction is the way items go, an exit's too (its model is turned round).
## An entrance (`extra` "u" "i") looks ahead that way for the nearest underground belt of its own
## kind (or a ghost of it) facing the same way, up to the prototype's max_distance (`eprops` "under"):
## an exit there is its other end, another entrance cuts it off. Other kinds, and pieces facing
## another way, are passed over (Factorio lets them braid), as the mod's underground_type does. An
## exit looks back for its entrance. A pipe-to-ground's direction is its pipe connection, so its
## underground side is behind it: it looks back for one of its kind facing the other way (one
## facing its own way on the line cuts it off).

const WorldMirror := preload("res://scripts/world/world.gd")
const ProtoDB := preload("res://scripts/world/protos.gd")
const CursorOverlay := preload("res://scripts/player/cursor_overlay.gd")

## Factorio's underground_sprite (core/graphics/arrows/underground-lines.png): the lane's edges orange
## to yellow, its arrow yellow. Where the furthest exit can go it is tinted green (the utility
## constants' underground_belt_max_distance_tint); past that, too far to connect, red (the red of its
## underground-lines-remove sprite).
const TUNNEL := Color(1.0, 0.75, 0.0, 0.95)
const MAX_REACH := Color(0.0, 1.0, 0.016, 0.95)
const TOO_FAR := Color(1.0, 0.0, 0.14, 0.95)


static func is_underground(type: String) -> bool:
	return type == "underground-belt" or type == "pipe-to-ground"


## The unit vector of a 16-way direction (north is (0, -1)).
static func _vec(dir: int) -> Vector2:
	return CursorOverlay.dir_vector(dir).round()


## The prototype a piece is of: its own, or a ghost's entity's.
static func _kind(r: WorldMirror.Rec) -> int:
	return int(r.extra["gh"]) if r.extra.has("gh") else r.proto_id


## The first piece of `kind` along `step` from `pos`, within `reach` tiles, facing one of `dirs`
## (others on the line are passed over): [rec, tiles away], or [] for none.
static func _first_on_line(world: WorldMirror, kind: int, pos: Vector2, step: Vector2, dirs: Array, reach: int) -> Array:
	for k in range(1, reach + 1):
		var r: WorldMirror.Rec = world.pick(pos + step * k)
		if r != null and _kind(r) == kind and dirs.has(r.dir):
			return [r, k]
	return []


## The other end of `rec` (an underground belt or pipe-to-ground) as Factorio connects them, or null.
static func partner(world: WorldMirror, rec: WorldMirror.Rec, reach: int) -> WorldMirror.Rec:
	if rec == null or reach <= 0:
		return null
	var kind := _kind(rec)
	var proto: ProtoDB.EntityProto = world.protos.entity(kind)
	if proto == null:
		return null
	if proto.type == "underground-belt":
		var entrance := str(rec.extra.get("u", "i")) == "i"
		var found := _first_on_line(world, kind, rec.pos, _vec(rec.dir) * (1.0 if entrance else -1.0), [rec.dir], reach)
		if found.is_empty():
			return null
		var other: WorldMirror.Rec = found[0]
		return other if (str(other.extra.get("u", "i")) == "i") != entrance else null
	if proto.type == "pipe-to-ground":
		var back := posmod(rec.dir + 8, 16)
		var found := _first_on_line(world, kind, rec.pos, -_vec(rec.dir), [rec.dir, back], reach)
		if found.is_empty():
			return null
		var other: WorldMirror.Rec = found[0]
		return other if other.dir == back else null
	return null


## What a held underground of `proto` at `pos` facing `dir` would join: {"partner": Rec, "k": tiles
## between their centres, "far": true when that is past `reach`, too far to connect (looked for up
## to twice the reach)}, or {} when there is nothing to join (it would be a new entrance).
static func held_join(world: WorldMirror, proto: ProtoDB.EntityProto, pos: Vector2, dir: int, reach: int) -> Dictionary:
	if proto == null or reach <= 0 or not is_underground(proto.type):
		return {}
	var back := -_vec(dir)
	var found: Array
	if proto.type == "underground-belt":
		# An entrance facing the same way: this would be its exit. An exit there ends the search.
		found = _first_on_line(world, proto.id, pos, back, [dir], reach * 2)
		if found.is_empty() or str((found[0] as WorldMirror.Rec).extra.get("u", "i")) != "i":
			return {}
	else:
		var other := posmod(dir + 8, 16)
		found = _first_on_line(world, proto.id, pos, back, [dir, other], reach * 2)
		if found.is_empty() or (found[0] as WorldMirror.Rec).dir != other:
			return {}
	return {"partner": found[0], "k": found[1], "far": int(found[1]) > reach}


## Factorio's marks for a held underground: its underground_sprite on every tile between the piece
## it would join and it, and on the furthest tile its exit may go, green; red from the piece once it
## is past that, too far to connect. With nothing to join, the furthest its exit could go, green.
## Pipes-to-ground have no arrow, as Factorio draws their connection.
static func held_marks(world: WorldMirror, proto: ProtoDB.EntityProto, pos: Vector2, dir: int, reach: int) -> Array:
	if proto == null or reach <= 0 or not is_underground(proto.type):
		return []
	var belt := proto.type == "underground-belt"
	var join := held_join(world, proto, pos, dir, reach)
	if join.is_empty():
		# A new entrance: where its exit could go at most (a pipe-to-ground's is behind it).
		return [tunnel(pos + _vec(dir) * (reach if belt else -reach), _vec(dir), MAX_REACH, belt)]
	var r: WorldMirror.Rec = join["partner"]
	var k: int = join["k"]
	var way := (pos - r.pos).normalized().round()
	var flow := _vec(dir) if belt else way
	var colour := TOO_FAR if bool(join["far"]) else TUNNEL
	var out: Array = []
	for i in range(1, k):
		if i != reach:
			out.append(tunnel(r.pos + way * i, flow, colour, belt))
	if reach != k:
		out.append(tunnel(r.pos + way * reach, flow, MAX_REACH, belt))
	return out


## One tile of Factorio's underground connection at `at` (the tile's centre) for things going `flow`:
## the lane's edges as dashes and, for belts, a hollow arrow (cursor_overlay.gd draws it).
static func tunnel(at: Vector2, flow: Vector2, colour: Color, arrow := true) -> Dictionary:
	return {"k": "tunnel", "at": at, "dir": flow, "c": colour, "arrow": arrow}
