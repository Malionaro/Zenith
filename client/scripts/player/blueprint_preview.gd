extends Node3D
## A held blueprint's (a book's active page's) or the clipboard's entities at the cursor, as Factorio
## draws a held blueprint: each entity its own model, see-through in Factorio's ghost blue (the build
## preview's ghost.gdshader, its depth laid first as the map's ghosts are in ghosts.gd, so it reads as
## one clean layer), red where it can't be built (something in the way it doesn't replace, empty space,
## a planet that forbids it), and its tiles as flat ghost squares. Belts curve, pipes and walls join
## as they will once built, from the blueprint's own pieces. A model still being read shows nothing
## until it is made (MODEL_WAIT_MSEC at most, then a box); a mod's building without a model is its
## picture card, as in the world.
##
## A blueprint may hold thousands of entities: they are drawn as one MultiMesh per model, laid out in
## the blueprint's own frame (its middle at this node's origin), so moving the cursor only moves the
## node. A new blueprint, R or a flip lays it out again, and crossing a tile checks again what is in
## the way, both a slice a frame (FrameBudget's `blueprint`). The check reads a per-chunk index of what
## stands on each tile, made when the preview first covers a chunk and again once the world says the
## chunk changed; it goes round the entities in turn, so a cursor that keeps moving still gets every
## one checked, the latest position first for the one after the last checked.

const WorldMirror := preload("res://scripts/world/world.gd")
const ProtoDB := preload("res://scripts/world/protos.gd")
const Visuals := preload("res://scripts/world/visuals.gd")
const ModelLibrary := preload("res://scripts/world/model_library.gd")
const SpriteStandins := preload("res://scripts/world/sprite_standins.gd")
const FrameBudget := preload("res://scripts/world/frame_budget.gd")
const GhostShader := preload("res://shaders/ghost.gdshader")
const GhostDepthShader := preload("res://shaders/ghost_depth.gdshader")

## The build preview's ghost and refused tints (player_input.gd _ghost_model_tints).
const TINT := Color(0.58, 0.68, 1.0, 0.42)
const BAD_TINT := Color(1.0, 0.3, 0.25, 0.5)
## ghosts.gd's: every ghost's depth first, then their colour.
const DEPTH_PRIORITY := 1
const COLOR_PRIORITY := 2
## A model not read yet is waited for this long before the layout goes on without it (a box).
const MODEL_WAIT_MSEC := 3000
## Tiles a world entity's footprint may reach past its chunk (a silo is 9 x 9): its neighbours' are
## looked at within this of a chunk when indexing it.
const REACH := 6.0
## Chunk indexes kept; past this they are all made again as needed.
const MAX_INDEXED := 400
## What never stands in the way (player_input.gd _blocked).
const PASSABLE := {"resource": true, "entity-ghost": true, "tile-ghost": true}
## Trees and rocks: Shift's forced build marks them for deconstruction instead.
const NATURE := {"tree": true, "simple-entity": true}
## The machines a flip mirrors (Factorio's `mirror`), and the rails that mirror into other pieces of
## the same rail (planners.lua MIRROR_TYPES, RAIL_MIRROR: the mod's mirrored copy).
const MIRROR_TYPES := {"assembling-machine": true, "furnace": true}
const RAIL_MIRROR_8 := {"straight-rail": 16, "elevated-straight-rail": 16, "half-diagonal-rail": 18,
	"elevated-half-diagonal-rail": 18}
const RAIL_MIRROR_16 := {"curved-rail-a": 18, "elevated-curved-rail-a": 18, "curved-rail-b": 18, "elevated-curved-rail-b": 18}
## North, east, south, west (world.gd PIPE_STEPS), doubled: the layout keys tiles by half tiles.
const STEPS := [Vector2i(0, -2), Vector2i(2, 0), Vector2i(0, 2), Vector2i(-2, 0)]
const BELTS := {"transport-belt": true, "underground-belt": true, "linked-belt": true}
const PIPES := {"pipe": true, "infinity-pipe": true, "pipe-to-ground": true, "heat-pipe": true}
## In a chunk's index: more than one kind on the tile (in everything's way), empty space.
const MIXED := -1
const VOID := -2

var world: WorldMirror
## Types that fast-replace each other across types (player_input.gd REPLACE_GROUPS).
var replace_groups := {}
## Callable(proto id) -> bool: the surface forbids it (a planet's pressure, gravity, field).
var refused := Callable()

var _material: ShaderMaterial
## What is laid out: the caller's key, entries, tiles, turn and flip.
var _key: Variant = null
var _entries: Array = []
var _tiles: Array = []
var _turn := 0
var _mirror := false
## The layout's stage: 0 drawn (or nothing), 1 placing, 2 joining and asking for models, 3 waiting
## for them, 4 instances, 5 the MultiMeshes' buffers, 6 putting them in.
var _stage := 0
var _i := 0
var _place: Array = []  # per entry: [proto, local Vector2, dir, flipped, extra from the blueprint] or null
var _extra: Array = []  # per entry: the model's extra (belt shape, pipe and wall joins, underground end)
var _belt_at := {}  # doubled local tile -> entry index (belts and undergrounds)
var _pipe_at := {}
var _wall_at := {}
var _models := {}  # model key -> [name, type, extra, dir]
var _wait_from := 0
var _xfs := {}  # Mesh -> Array of Transform3D
## Each model's MultiMesh buffer, filled a slice at a time: the models in turn, the one being filled
## (a member, written in place: a packed array taken out of a container is a copy), those done.
var _fill_meshes: Array = []
var _fill_m := 0
var _fill_i := 0
var _fill_buf := PackedFloat32Array()
var _filled: Array = []  # [Mesh, PackedFloat32Array, instances]
var _cards := {}  # picture card Mesh -> Array of Transform3D
var _tile_xf: Array = []
var _items: Array = []  # [proto, local centre, footprint (as turned), Mesh or null, instance]
## What is drawn: its entities (as _items), each model's MultiMesh, and which are red.
var _shown: Array = []
var _mm_of := {}
var _shown_xfs := {}  # Mesh -> Array of Transform3D, as the MultiMeshes were filled
var _bad := PackedByteArray()
## The check round the entities: the next one, how many still to check for the latest state.
var _centre := Vector2.INF
var _mode := -1
var _check_i := 0
var _check_left := 0
var _refused := {}
var _index := {}  # chunk -> [PackedInt32Array (proto id + 1, MIXED, VOID), PackedByteArray (trees and rocks), its ChunkView's id]
var _unloaded := {}  # chunks looked at that weren't loaded: checked again when they come
var _index_chunk := Vector2i(1 << 30, 0)
var _index_last: Array = []
## Time spent and entities laid out and checked, for tests and probes.
var usec_spent := 0
var laid_out := 0
var checked := 0


func _ready() -> void:
	var colour := ShaderMaterial.new()
	colour.shader = GhostShader
	colour.render_priority = COLOR_PRIORITY
	colour.set_shader_parameter("tint", TINT)
	colour.set_shader_parameter("bad_tint", BAD_TINT)
	colour.set_shader_parameter("instance_tint", true)
	_material = ShaderMaterial.new()
	_material.shader = GhostDepthShader
	_material.render_priority = DEPTH_PRIORITY
	_material.next_pass = colour
	visible = false
	if world != null:
		world.entities_changed.connect(_on_changed)
		world.tiles_changed.connect(_on_changed)


## Draws `entries` ([{"p": proto id, "at": offset from the middle (tiles), "d", "x"?: the model's
## extra, "f"?: mirrored}]) and `tiles` (their corners, offsets from the middle) with the middle at
## `centre`, flipped east-west first with `mirror`, then turned `turn` quarter turns clockwise.
## `key` says when they changed (compared with ==; the entries may be the same array refilled).
## `mode` is Factorio's build mode for what stands in the way: 0 normal, 1 forced (trees and rocks
## are marked for deconstruction instead), 2 super-forced (everything in the way is). Call every
## frame while it shows: the layout and the check go on a slice a frame.
func show_blueprint(key: Variant, entries: Array, tiles: Array, centre: Vector2, turn: int, mirror: bool, mode: int) -> void:
	if world == null or (entries.is_empty() and tiles.is_empty()):
		clear()
		return
	visible = true
	turn = posmod(turn, 4)
	if _key == null or key != _key or turn != _turn or mirror != _mirror:
		_begin(key, entries, tiles, turn, mirror)
	position = Vector3(centre.x, 0.0, centre.y)
	if centre != _centre or mode != _mode:
		_centre = centre
		_mode = mode
		_again()
	if _stage == 0 and _check_left == 0:
		return
	var t0 := Time.get_ticks_usec()
	var allow := FrameBudget.grant(&"blueprint")
	_work(t0, allow)
	var used := Time.get_ticks_usec() - t0
	usec_spent += used
	FrameBudget.spent(&"blueprint", used, (_entries.size() if _stage != 0 else 0) + _check_left)


## Nothing held any more: hidden (the layout is kept, should the same blueprint come back).
func clear() -> void:
	visible = false
	_centre = Vector2.INF
	if _index.size() > MAX_INDEXED:
		_forget_index()


## The layout is drawn and every entity checked where it stands now.
func settled() -> bool:
	return _stage == 0 and _check_left == 0


## For tests: the drawn entities ([proto, local centre, footprint, Mesh or null, instance]).
func shown_items() -> Array:
	return _shown


func is_bad(i: int) -> bool:
	return i >= 0 and i < _bad.size() and _bad[i] == 1


func bad_count() -> int:
	var n := 0
	for b in _bad:
		n += b
	return n


## For tests: drawn entity `i`'s transform in the preview's frame (its MultiMesh's instance).
func instance_transform(i: int) -> Transform3D:
	if i < 0 or i >= _shown.size() or _shown[i][3] == null:
		return Transform3D()
	return (_shown_xfs[_shown[i][3]] as Array)[int(_shown[i][4])]


## The MultiMesh drawing `mesh`, or null.
func multimesh_of(mesh: Mesh) -> MultiMesh:
	return _mm_of.get(mesh)


## The flat ghost squares of its tiles.
func tile_count() -> int:
	return _tile_xf.size() if _stage == 0 else 0


func _begin(key: Variant, entries: Array, tiles: Array, turn: int, mirror: bool) -> void:
	_key = key
	_entries = entries
	_tiles = tiles
	_turn = turn
	_mirror = mirror
	_stage = 1
	_i = 0
	_place = []
	_extra = []
	_belt_at.clear()
	_pipe_at.clear()
	_wall_at.clear()
	_models.clear()
	_xfs.clear()
	_fill_meshes = []
	_fill_m = 0
	_fill_i = 0
	_fill_buf = PackedFloat32Array()
	_filled = []
	_cards.clear()
	_tile_xf = []
	_items = []
	# The old layout faces another way: it goes now, not when the new one is done.
	for c in get_children():
		c.visible = false


func _again() -> void:
	_check_left = _shown.size()
	_refused.clear()
	_index_chunk = Vector2i(1 << 30, 0)
	_index_last = []


func _work(t0: int, allow: int) -> void:
	while true:
		if Time.get_ticks_usec() - t0 > allow:
			return
		match _stage:
			1:
				_step_place()
			2:
				_step_extra()
			3:
				if not _models_ready() and Time.get_ticks_msec() - _wait_from < MODEL_WAIT_MSEC:
					return  # the models are read on worker threads; nothing to do here meanwhile
				_stage = 4
				_i = 0
			4:
				_step_build()
			5:
				_step_fill()
			6:
				_install()
			_:
				if _check_left == 0:
					return
				_step_check(t0, allow)


func _step_place() -> void:
	var end := mini(_i + 64, _entries.size())
	while _i < end:
		var e: Dictionary = _entries[_i]
		var proto: ProtoDB.EntityProto = world.protos.entity(int(e.get("p", -1)))
		if proto == null:
			_place.append(null)
			_i += 1
			continue
		var at: Vector2 = e.get("at", Vector2.ZERO)
		var dir := int(e.get("d", 0))
		var flipped := bool(e.get("f", false))
		if _mirror:
			# East-west, as the mod mirrors the blueprint (planners.lua mirrored).
			at.x = -at.x
			dir = _mirrored_dir(proto.type, dir)
			if MIRROR_TYPES.has(proto.type):
				flipped = not flipped
		for t in _turn:
			at = Vector2(-at.y, at.x)  # a quarter turn clockwise (y is south)
		dir = posmod(dir + _turn * 4, 16)
		var x = e.get("x")
		_place.append([proto, at, dir, flipped, x if x is Dictionary else {}])
		var k := Vector2i(roundi(at.x * 2.0), roundi(at.y * 2.0))
		if BELTS.has(proto.type):
			_belt_at[k] = _i
		elif PIPES.has(proto.type):
			_pipe_at[k] = _i
		elif proto.type == "wall" or proto.type == "gate":
			_wall_at[k] = _i
		_i += 1
	if _i >= _entries.size():
		_stage = 2
		_i = 0


static func _mirrored_dir(type: String, dir: int) -> int:
	if RAIL_MIRROR_8.has(type):
		return posmod(int(RAIL_MIRROR_8[type]) - dir, 8)
	if RAIL_MIRROR_16.has(type):
		return posmod(int(RAIL_MIRROR_16[type]) - dir, 16)
	return posmod(16 - dir, 16)


func _step_extra() -> void:
	var end := mini(_i + 64, _place.size())
	while _i < end:
		var p = _place[_i]
		var extra := {}
		if p != null:
			var proto: ProtoDB.EntityProto = p[0]
			var k := Vector2i(roundi((p[1] as Vector2).x * 2.0), roundi((p[1] as Vector2).y * 2.0))
			match proto.type:
				"transport-belt":
					extra = {"s": _belt_shape(k, int(p[2]))}
				"underground-belt", "linked-belt":
					extra = {"u": "o" if str((p[4] as Dictionary).get("u", "i")) == "o" else "i"}
				"pipe", "infinity-pipe", "heat-pipe":
					extra = {"pc": _pipe_mask(k, proto.type == "heat-pipe")}
				"wall":
					extra = {"wc": _wall_mask(k)}
			var key := ModelLibrary.model_name(proto.name, proto.type, extra, int(p[2])) + "|" + proto.name
			if not _models.has(key):
				_models[key] = [proto.name, proto.type, extra, int(p[2])]
		_extra.append(extra)
		_i += 1
	if _i >= _place.size():
		_stage = 3
		_wait_from = Time.get_ticks_msec()
		_models_ready()  # asks for them all now


## Factorio's rule: a belt fed from behind is straight; one fed from exactly one side (and not from
## behind) curves: "l" when its items come from its left (world.gd belt_continues' shapes).
func _belt_shape(k: Vector2i, dir: int) -> String:
	var ci := (dir >> 2) & 3
	if _belt_feeds_at(k - STEPS[ci], dir):
		return "s"
	var left := _belt_feeds_at(k + STEPS[(ci + 3) % 4], ((ci + 1) % 4) * 4)
	var right := _belt_feeds_at(k + STEPS[(ci + 1) % 4], ((ci + 3) % 4) * 4)
	if left != right:
		return "l" if left else "r"
	return "s"


## Whether the blueprint's belt at `k` sends its items on going `dir`.
func _belt_feeds_at(k: Vector2i, dir: int) -> bool:
	var j = _belt_at.get(k)
	if j == null or _place[j] == null:
		return false
	var p: Array = _place[j]
	return WorldMirror.belt_feeds(dir, (p[0] as ProtoDB.EntityProto).type, int(p[2]), str((p[4] as Dictionary).get("u", "")))


## world.gd _connect_pipe's joins, among the blueprint's own pipes.
func _pipe_mask(k: Vector2i, heat: bool) -> int:
	var mask := 0
	for i in 4:
		var j = _pipe_at.get(k + STEPS[i])
		if j == null or _place[j] == null:
			continue
		var p: Array = _place[j]
		var type := (p[0] as ProtoDB.EntityProto).type
		if heat != (type == "heat-pipe"):
			continue
		if type == "pipe-to-ground" and int(p[2]) != ((i + 2) % 4) * 4:
			continue
		mask |= 1 << i
	return mask


## world.gd _connect_wall's joins, among the blueprint's own walls and gates.
func _wall_mask(k: Vector2i) -> int:
	var mask := 0
	for i in 4:
		var j = _wall_at.get(k + STEPS[i])
		if j == null or _place[j] == null:
			continue
		var p: Array = _place[j]
		if (p[0] as ProtoDB.EntityProto).type == "gate" and (int(p[2]) / 4) % 2 != i % 2:
			continue
		mask |= 1 << i
	if mask & 6 == 6:
		var j = _wall_at.get(k + Vector2i(2, 2))
		if j != null and _place[j] != null and (_place[j][0] as ProtoDB.EntityProto).type == "wall":
			mask |= 16
	return mask


func _models_ready() -> bool:
	var all := true
	for key in _models:
		var m: Array = _models[key]
		if not ModelLibrary.entity_ready(str(m[0]), str(m[1]), m[2], int(m[3])):
			all = false
	return all


func _step_build() -> void:
	var end := mini(_i + 64, _place.size())
	while _i < end:
		var p = _place[_i]
		_i += 1
		if p == null:
			continue
		var proto: ProtoDB.EntityProto = p[0]
		var at: Vector2 = p[1]
		var dir := int(p[2])
		var extra: Dictionary = _extra[_i - 1]
		var size := proto.tile_size
		if posmod(roundi(dir / 4.0), 2) == 1:
			size = Vector2i(size.y, size.x)
		var flip := Basis.from_scale(Vector3(-1, 1, 1)) if bool(p[3]) else Basis.IDENTITY
		var mesh: Mesh = null
		if ModelLibrary.entity_ready(proto.name, proto.type, extra, dir):
			mesh = ModelLibrary.mesh_for_entity(proto.name, proto.type, extra, dir)
		var xf: Transform3D
		if mesh != null:
			xf = ModelLibrary.placed(proto.name, proto.type, dir, extra, Vector3(at.x, 0.0, at.y), flip)
		else:
			var card := SpriteStandins.card(proto.name, dir, proto.size(), proto.type) if proto.type != "resource" else null
			if card != null:
				if not _cards.has(card):
					_cards[card] = []
				(_cards[card] as Array).append(SpriteStandins.transform(at))
				_items.append([proto, at, size, null, -1])
				continue
			mesh = Visuals.box_mesh()
			xf = Visuals.placeholder_transform(proto, at, dir, Visuals.height_for(proto))
			xf.basis = xf.basis * flip
		if not _xfs.has(mesh):
			_xfs[mesh] = []
		var list: Array = _xfs[mesh]
		_items.append([proto, at, size, mesh, list.size()])
		list.append(xf)
	if _i >= _place.size():
		for t in _tiles:
			var c: Vector2 = (t as Vector2) + Vector2(0.5, 0.5)
			if _mirror:
				c.x = -c.x
			for q in _turn:
				c = Vector2(-c.y, c.x)
			_tile_xf.append(Transform3D(Basis.from_scale(Vector3(0.96, 0.02, 0.96)), Vector3(c.x, 0.04, c.y)))
		_fill_meshes = _xfs.keys()
		_fill_m = 0
		_fill_i = 0
		_stage = 5


## Up to 256 instances into the buffer being filled; a model done goes to _filled.
func _step_fill() -> void:
	if _fill_m >= _fill_meshes.size():
		_stage = 6
		return
	var list: Array = _xfs[_fill_meshes[_fill_m]]
	if _fill_i == 0:
		_fill_buf = PackedFloat32Array()
		_fill_buf.resize(list.size() * 16)
	var end := mini(_fill_i + 256, list.size())
	for i in range(_fill_i, end):
		_write_row(i, list[i])
	_fill_i = end
	if end < list.size():
		return
	_filled.append([_fill_meshes[_fill_m], _fill_buf, list.size()])
	_fill_buf = PackedFloat32Array()
	_fill_i = 0
	_fill_m += 1


## Instance `i`'s transform into the buffer being filled: a MultiMesh's 16 floats an instance are the
## transform's rows, then its custom data.
func _write_row(i: int, t: Transform3D) -> void:
	var k := i * 16
	_fill_buf[k] = t.basis.x.x
	_fill_buf[k + 1] = t.basis.y.x
	_fill_buf[k + 2] = t.basis.z.x
	_fill_buf[k + 3] = t.origin.x
	_fill_buf[k + 4] = t.basis.x.y
	_fill_buf[k + 5] = t.basis.y.y
	_fill_buf[k + 6] = t.basis.z.y
	_fill_buf[k + 7] = t.origin.y
	_fill_buf[k + 8] = t.basis.x.z
	_fill_buf[k + 9] = t.basis.y.z
	_fill_buf[k + 10] = t.basis.z.z
	_fill_buf[k + 11] = t.origin.z
	for c in 4:
		_fill_buf[k + 12 + c] = 0.0  # custom data: not red


## An instance's 16 floats in a MultiMesh's buffer: its transform's rows, then its custom data (0:
## not red).
static func _row(t: Transform3D) -> PackedFloat32Array:
	return PackedFloat32Array([t.basis.x.x, t.basis.y.x, t.basis.z.x, t.origin.x,
		t.basis.x.y, t.basis.y.y, t.basis.z.y, t.origin.y,
		t.basis.x.z, t.basis.y.z, t.basis.z.z, t.origin.z, 0.0, 0.0, 0.0, 0.0])


func _install() -> void:
	for c in get_children():
		remove_child(c)
		c.queue_free()
	_mm_of.clear()
	for f in _filled:
		_mm_of[f[0]] = _add(f[0], f[1], int(f[2]), _material)
	if not _tile_xf.is_empty():
		var buf := PackedFloat32Array()
		for t in _tile_xf:
			buf.append_array(_row(t))
		_add(Visuals.box_mesh(), buf, _tile_xf.size(), _material)
	for card in _cards:
		var buf := PackedFloat32Array()
		for t in _cards[card]:
			buf.append_array(_row(t))
		_add(card, buf, (_cards[card] as Array).size(), SpriteStandins.ghost_material(card, TINT))
	_shown = _items
	_shown_xfs = _xfs
	laid_out = _shown.size()
	_xfs = {}
	_filled = []
	_bad = PackedByteArray()
	_bad.resize(_shown.size())
	_check_i = 0
	_stage = 0
	_again()


func _add(mesh: Mesh, buf: PackedFloat32Array, n: int, material: Material) -> MultiMesh:
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_custom_data = true
	mm.mesh = mesh
	mm.instance_count = n
	mm.buffer = buf
	var mmi := MultiMeshInstance3D.new()
	mmi.multimesh = mm
	mmi.material_override = material
	mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(mmi)
	return mm


func _step_check(t0: int, allow: int) -> void:
	var n := _shown.size()
	var steps := 0
	while _check_left > 0:
		if (steps & 15) == 15 and Time.get_ticks_usec() - t0 > allow:
			return
		var i := _check_i
		_check_i = (i + 1) % n
		_check_left -= 1
		steps += 1
		var it: Array = _shown[i]
		var b := 1 if _blocked(it) else 0
		checked += 1
		if b != _bad[i]:
			_bad[i] = b
			if it[3] != null:
				(_mm_of[it[3]] as MultiMesh).set_instance_custom_data(int(it[4]), Color(float(b), 0.0, 0.0, 0.0))


## Something it doesn't replace is on its footprint (player_input.gd _blocked's rule: ore, ghosts, the
## same type and its fast-replace group don't count; trees and rocks not when forced, nothing when
## super-forced), or empty space, or the surface forbids it.
func _blocked(it: Array) -> bool:
	var proto: ProtoDB.EntityProto = it[0]
	if refused.is_valid():
		if not _refused.has(proto.id):
			_refused[proto.id] = bool(refused.call(proto.id))
		if _refused[proto.id]:
			return true
	var pos: Vector2 = _centre + (it[1] as Vector2)
	var size: Vector2i = it[2]
	var x0 := floori(pos.x - size.x * 0.5 + 0.05)
	var y0 := floori(pos.y - size.y * 0.5 + 0.05)
	var group := str(replace_groups.get(proto.type, ""))
	for dy in size.y:
		for dx in size.x:
			var tx := x0 + dx
			var ty := y0 + dy
			var c := Vector2i(floori(tx / float(WorldMirror.CHUNK)), floori(ty / float(WorldMirror.CHUNK)))
			var ix := _index_for(c)
			if ix.is_empty():
				continue
			var k := (ty - c.y * WorldMirror.CHUNK) * WorldMirror.CHUNK + (tx - c.x * WorldMirror.CHUNK)
			var id := (ix[0] as PackedInt32Array)[k]
			if id == VOID:
				return true
			if _mode < 2:
				if id == MIXED:
					return true
				if id > 0:
					var other: ProtoDB.EntityProto = world.protos.entity(id - 1)
					if other != null and other.type != proto.type and (group == "" or str(replace_groups.get(other.type, "")) != group):
						return true
				if _mode == 0 and (ix[1] as PackedByteArray)[k] != 0:
					return true
	return false


## A chunk's index of what stands on each of its tiles, made the first time it is asked for; [] for a
## chunk not loaded (nothing known there stands in the way, as the build preview has it).
func _index_for(c: Vector2i) -> Array:
	if c == _index_chunk:
		return _index_last
	var got = _index.get(c)
	if got != null:
		# Made for the chunk then loaded there: another surface's (world.gd reset) is made again.
		var cv = world.chunks.get(c)
		if cv == null or int(got[2]) != cv.get_instance_id():
			got = null
	if got == null:
		got = _make_index(c)
		if (got as Array).is_empty():
			_unloaded[c] = true
		else:
			_index[c] = got
	_index_chunk = c
	_index_last = got
	return got


func _make_index(c: Vector2i) -> Array:
	var cv = world.chunks.get(c)
	if cv == null:
		return []
	var n := WorldMirror.CHUNK
	var solid := PackedInt32Array()
	solid.resize(n * n)
	var nature := PackedByteArray()
	nature.resize(n * n)
	if cv.tile_ids.size() == n * n:
		for k in n * n:
			if world.protos.is_void(cv.tile_ids[k]):
				solid[k] = VOID
	var area := Rect2(Vector2(c) * n, Vector2(n, n))
	var near := area.grow(REACH)
	for dy in range(-1, 2):
		for dx in range(-1, 2):
			var other_cv = world.chunks.get(c + Vector2i(dx, dy))
			if other_cv == null:
				continue
			for r: WorldMirror.Rec in other_cv.entities.values():
				if (dx != 0 or dy != 0) and not near.has_point(r.pos):
					continue
				if r.extra.has("hid"):
					continue  # removed by the player, the game's `del` on its way
				var other: ProtoDB.EntityProto = world.protos.entity(r.proto_id)
				if other == null or PASSABLE.has(other.type):
					continue
				var rect := WorldMirror.selection_rect(other, r.pos, r.dir).grow(-0.05).intersection(area)
				if not rect.has_area():
					continue
				var is_nature := NATURE.has(other.type)
				for ty in range(floori(rect.position.y), ceili(rect.end.y)):
					for tx in range(floori(rect.position.x), ceili(rect.end.x)):
						var k := (ty - c.y * n) * n + (tx - c.x * n)
						if is_nature:
							nature[k] = 1
							continue
						var cur := solid[k]
						if cur == 0:
							solid[k] = other.id + 1
						elif cur > 0 and cur != other.id + 1:
							var was: ProtoDB.EntityProto = world.protos.entity(cur - 1)
							if was == null or was.type != other.type:
								solid[k] = MIXED
	return [solid, nature, cv.get_instance_id()]


## A chunk changed (built, mined, its tiles laid): its index and its neighbours' (a building reaches
## into them) are made again, and every entity is checked once more.
func _on_changed(c: Vector2i) -> void:
	var touched := _unloaded.erase(c)
	for dy in range(-1, 2):
		for dx in range(-1, 2):
			if _index.erase(c + Vector2i(dx, dy)):
				touched = true
	_index_chunk = Vector2i(1 << 30, 0)
	_index_last = []
	if touched and visible:
		_again()


func _forget_index() -> void:
	_index.clear()
	_unloaded.clear()
	_index_chunk = Vector2i(1 << 30, 0)
	_index_last = []
