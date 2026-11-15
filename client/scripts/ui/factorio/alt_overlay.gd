extends Control
## Factorio's Alt-mode (Alt): over each machine in view the icon of what it is set to make or let
## through (an assembler's or furnace's recipe, an inserter's, splitter's or storage chest's
## filter), from its record's `extra.ai` (issue #9: every machine the client has loaded, kept per
## chunk in ChunkView.alt and changed by `aiu`), over each chest without such an icon what it holds
## most of (world.gd's alt_contents from `ac`, J6: up to four kinds in a grid, as Factorio's Alt-mode
## shows container contents), in rows over machines their modules and over labs their science packs
## (world.gd's alt_machines from `am`, K1, K2), and on every pipe, underground pipe, pump and
## tank the icon of the fluid in it (fluids_power.gd's `fl`). Where each goes is Factorio's own: an
## entity's icon by its prototype's icon_draw_specification (`eprops` ids: a shift from its centre
## and a scale), the rows by its icons_positioning (`eprops` isq, sequence_cells). As in Factorio the icons have no
## disc behind them, only a soft dark shadow, and are drawn flat over the world at the entity's
## position projected through the camera, sized with the zoom. Only chunks in the camera's view
## are looked at; all the shadows are drawn first and then the icons picture by picture, so the
## canvas batches them (a shadow between two icons would split every batch).
##
## factorio_ui.gd sets `player` (player_input.gd: its world mirror and camera rig).

const Kit := preload("res://scripts/ui/factorio/kit.gd")
const Slot := preload("res://scripts/ui/factorio/slot.gd")
const WorldMirror := preload("res://scripts/world/world.gd")
const Visuals := preload("res://scripts/world/visuals.gd")
const DepthIcon := preload("res://shaders/billboard_icon_depth.gdshader")
const GroundHeight := preload("res://scripts/world/ground_height.gd")

## The icon is this many tiles across (measured on Factorio's alt-mode over assemblers).
const ICON_TILES := 1.2
## Over a chest: Factorio scales a chest's icons by its prototype's icon_draw_specification, 0.7 on
## every chest of the base game (wooden to steel, the five logistic chests).
const CHEST_TILES := ICON_TILES * 0.7
const CHEST_TYPES := ["container", "logistic-container", "infinity-container", "linked-container"]
## A fluid's icon on a pipe.
const FLUID_TILES := 0.55
const FLUID_TYPES := ["pipe", "pipe-to-ground", "pump", "storage-tank", "infinity-pipe"]
## Plain pipes carry the icon only now and then, as Factorio's Alt-mode (owner's P50: one on every
## pipe covered a run). One tile in this many, on a slanted lattice (`pipe_shows_icon`).
const PIPE_ICON_EVERY := 5
const SPARSE_FLUID_TYPES := ["pipe", "infinity-pipe"]
const SHADOW := Color(0, 0, 0, 0.6)
## A module's or science pack's icon at its row's scale 1 is this many tiles across. Factorio's own
## rows fit at 1: Space Age's lab puts six packs a row at scale 0.5 and separation 1/1.1 over its
## three tiles, with its modules' row under them (larger, the rows would overflow and overlap).
const SEQUENCE_TILE := 1.0
## Its quality's mark, at the icon's bottom left, this share of its side (as in a slot).
const QUALITY_SHARE := 0.4
## Beacons draw their modules only while the mouse is on them (Factorio 2.1.8's changelog).
const HOVER_ONLY_TYPES := ["beacon"]
## --alt-icon-spec=off: every machine's own icon centred at ICON_TILES as before K1 (eprops ids unread).
static var use_spec := true
static var _args_read := false

var model
var player: Node = null
var on := false

var _shadow: Texture2D
## First person: the icons as 3D quads with the depth test on, so buildings in front hide them
## (from above, nothing stands between the camera and an icon). Pooled; a material per picture.
var _quads: Array[MeshInstance3D] = []
var _quad_holder: Node3D
var _quad_materials := {}  # Texture2D -> ShaderMaterial
var _quads_used := 0
## The remote view's fog (the player's remote_fog): no icons for what no radar sees.
var _fog: Node = null


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	texture_filter = Kit.ICON_FILTER
	# Factorio's icon shadow: a soft dark blur, darkest in the middle.
	var g := Gradient.new()
	g.set_color(0, SHADOW)
	g.set_color(1, Color(0, 0, 0, 0))
	g.add_point(0.55, Color(0, 0, 0, SHADOW.a * 0.75))
	var t := GradientTexture2D.new()
	t.gradient = g
	t.fill = GradientTexture2D.FILL_RADIAL
	t.fill_from = Vector2(0.5, 0.5)
	t.fill_to = Vector2(1.0, 0.5)
	t.width = 64
	t.height = 64
	_shadow = t


func _process(_delta: float) -> void:
	if on:
		queue_redraw()
	elif _quads_used > 0 or (not _quads.is_empty() and _quads[0].visible):
		_quads_used = 0
		_hide_quads()


func _draw() -> void:
	collect()
	for rect in _shadows:
		draw_texture_rect(_shadow, rect, false)
	for texture in _icons:
		for rect in _icons[texture]:
			draw_texture_rect(texture, rect, false)
	for texture in _marks:
		for rect in _marks[texture]:
			draw_texture_rect(texture, rect, false)


## Works out this frame's icons (first person: places the quads) into _shadows, _icons and _marks.
func collect() -> void:
	_read_args()
	_quads_used = 0
	_marks_3d = 0
	_shadows.clear()
	_icons.clear()
	_marks.clear()
	drawn = 0
	if not on or model == null or player == null:
		_hide_quads()
		return
	var world = player.get("world")
	var rig = player.get("rig")
	if world == null or rig == null:
		_hide_quads()
		return
	var camera: Camera3D = rig.camera
	_in_3d = bool(rig.get("first_person"))
	_fog = player.get("remote_fog")
	var planes := camera.get_frustum()
	for c in world.chunks:
		var cv = world.chunks[c]
		if cv.alt.is_empty() or not _chunk_in_view(c, planes):
			continue
		for key in cv.alt:
			var r: WorldMirror.Rec = cv.alt[key]
			var icon := WorldMirror.alt_icon(r)
			if icon.is_empty():
				continue
			var textures: Array[Texture2D] = []
			for i in range(1, icon.size()):  # a filter inserter's filters, every one
				textures.append(Kit.item_icon(str(icon[i])))
			var spec := _spec_for(r)
			var tiles: float = ICON_TILES * spec[1] if not spec.is_empty() else _tiles_for(world, r)
			_draw_icon(world, camera, r, textures, tiles, spec[0] if not spec.is_empty() else Vector2.ZERO)
	_draw_contents(world, camera, planes)
	_draw_sequences(world, camera, planes)
	var parent: Node = world.get_parent()
	var fluids_layer = parent.get_node_or_null("FluidsPower") if parent != null else null
	if fluids_layer != null:
		_draw_fluids(world, camera, fluids_layer)
	drawn = _shadows.size() + _quads_used - _marks_3d
	_hide_quads()


static func _read_args() -> void:
	if _args_read:
		return
	_args_read = true
	use_spec = not OS.get_cmdline_user_args().has("--alt-icon-spec=off")


## [shift (tiles from the centre, right and down), scale] of the entity's own icon from its
## prototype's icon_draw_specification (`eprops` ids), or [] when the bridge sent none (the default,
## or a bridge from before K1).
func _spec_for(r: WorldMirror.Rec) -> Array:
	if not use_spec or model == null:
		return []
	var ids = (_overlay_of(r.proto_id)).get("ids")
	if not (ids is Array) or ids.size() < 3:
		return []
	return [Vector2(float(ids[0]), float(ids[1])), maxf(float(ids[2]), 0.05)]


func _overlay_of(proto_id: int) -> Dictionary:
	var ep = model.eprops.get(proto_id)
	if not (ep is Dictionary):
		return {}
	var x = ep.get("x")
	return x if x is Dictionary else {}


## Whether a chunk's box (the ground up to 8 tiles) is at least partly inside the camera's frustum.
static func _chunk_in_view(c: Vector2i, planes: Array[Plane]) -> bool:
	# An add-on's hills (ground_height.gd) lift the icons with the buildings under them, by no more
	# than the field's range.
	var lift := GroundHeight.lift_range()
	var lo := Vector3(c.x * 32.0, -1.0 + lift.x, c.y * 32.0)
	var hi := lo + Vector3(32.0, 9.0 + lift.y - lift.x, 32.0)
	for plane in planes:
		# The box's corner furthest into the frustum (against the plane's outward normal).
		var n := plane.normal
		var p := Vector3(lo.x if n.x > 0.0 else hi.x, lo.y if n.y > 0.0 else hi.y, lo.z if n.z > 0.0 else hi.z)
		if plane.distance_to(p) > 0.0:
			return false
	return true


## A chest's icons are smaller than a machine's (CHEST_TILES).
static func _tiles_for(world, r: WorldMirror.Rec) -> float:
	var proto = world.protos.entity(r.proto_id)
	return CHEST_TILES if proto != null and CHEST_TYPES.has(proto.type) else ICON_TILES


## The chests' contents (J6) over those in view without an icon of their own (a requester's requests
## and a storage chest's filter come first, as in Factorio).
func _draw_contents(world, camera: Camera3D, planes: Array[Plane]) -> void:
	if not world.has_method("alt_contents_now"):
		return
	var contents: Dictionary = world.alt_contents_now()
	if contents.is_empty():
		return
	var in_view := {}  # chunk -> whether it is, this frame
	for unit in contents:
		var r: WorldMirror.Rec = world.entities.get(unit)
		if r == null or not WorldMirror.alt_icon(r).is_empty():
			continue
		if not in_view.has(r.chunk):
			in_view[r.chunk] = _chunk_in_view(r.chunk, planes)
		if not bool(in_view[r.chunk]):
			continue
		var textures: Array[Texture2D] = []
		for item in contents[unit]:
			textures.append(Kit.item_icon(str(item)))
		var spec := _spec_for(r)
		_draw_icon(world, camera, r, textures, ICON_TILES * spec[1] if not spec.is_empty() else CHEST_TILES,
			spec[0] if not spec.is_empty() else Vector2.ZERO)


## The modules in machines and the science packs in labs (K1, K2), in rows laid out by their
## prototype's icons_positioning (`eprops` isq); a beacon's only while the mouse is on it.
func _draw_sequences(world, camera: Camera3D, planes: Array[Plane]) -> void:
	if not world.has_method("alt_machines_now"):
		return
	var shown: Dictionary = world.alt_machines_now()
	if shown.is_empty():
		return
	var hovered = player.get("hovered")
	var in_view := {}
	for unit in shown:
		var r: WorldMirror.Rec = world.entities.get(unit)
		if r == null:
			continue
		var proto = world.protos.entity(r.proto_id)
		if proto == null or (HOVER_ONLY_TYPES.has(proto.type) and hovered != r):
			continue
		var isq = _overlay_of(r.proto_id).get("isq")
		if not (isq is Array):
			continue
		if not in_view.has(r.chunk):
			in_view[r.chunk] = _chunk_in_view(r.chunk, planes)
		if not bool(in_view[r.chunk]):
			continue
		var lists: Array = shown[unit]
		var spec := _spec_for(r)
		var ref: float = ICON_TILES * (spec[1] if not spec.is_empty() else 1.0)
		for row in isq:
			if not (row is Array) or row.size() < 8:
				continue
			var items: Array = lists[0] if str(row[0]) == "m" else lists[1] if str(row[0]) == "l" else []
			if items.is_empty():
				continue
			var cells := sequence_cells(items.size(), row)
			var textures: Array[Texture2D] = []
			var qualities: Array[String] = []
			for i in cells.size():
				textures.append(Kit.item_icon(str(items[i][0])))
				qualities.append(str(items[i][1]))
			_draw_cells(world, camera, r, textures, cells, ref, qualities)


## Where Factorio's IconSequencePositioning `row` ([kind, shift x, shift y, scale, icons a row, rows,
## separation, first row's lift], `eprops` isq) puts `n` icons: [[centre (tiles from the entity's
## centre, right and down), side (tiles)], ...], at most a row's icons times its rows. Rows of up to
## `icons a row` from the top, each centred on the shift, one `scale x separation` apart both ways; a
## last row not full is centred; with several rows the first is lifted by `first row's lift` per row
## after it (the docs give the parameters, not the rule: rebuilt from 2.1's numbers, its labs and
## beacons, not measured on Factorio's screen).
static func sequence_cells(n: int, row: Array) -> Array:
	var shift := Vector2(float(row[1]), float(row[2]))
	var scale := float(row[3])
	var per_row := maxi(1, int(row[4]))
	var rows_max := maxi(1, int(row[5]))
	var step := scale * float(row[6]) * SEQUENCE_TILE
	n = mini(n, per_row * rows_max)
	var rows := ceili(float(n) / per_row)
	var top := shift.y + float(row[7]) * (rows - 1)
	var out := []
	for i in n:
		var r := i / per_row
		var in_row := mini(per_row, n - r * per_row)
		var col := i % per_row
		out.append([Vector2(shift.x + (col - (in_row - 1) * 0.5) * step, top + r * step), scale * SEQUENCE_TILE])
	return out


func _draw_fluids(world, camera: Camera3D, fluids_layer) -> void:
	for unit in fluids_layer.fluids:
		var r: WorldMirror.Rec = world.entities.get(unit)
		if r == null:
			continue
		var proto = world.protos.entity(r.proto_id)
		if proto == null or not FLUID_TYPES.has(proto.type):
			continue
		if SPARSE_FLUID_TYPES.has(proto.type) and not pipe_shows_icon(Vector2i(r.pos.floor())):
			continue
		var boxes: Array = fluids_layer.fluids[unit]
		for b in boxes:
			var fluid := str(b.get("fluid", ""))
			if fluid != "" and float(b.get("amount", 0.0)) > 0.0:
				_draw_icon(world, camera, r, [Kit.item_icon(fluid)], FLUID_TILES)
				break


## Whether a plain pipe on this tile shows its fluid. Decided by the tile alone, so an icon never
## moves when pipes are built or mined beside it; x + 2y puts one in every PIPE_ICON_EVERY tiles of
## a straight run either way, and a staircase of pipes crosses it too (x + y would miss some).
static func pipe_shows_icon(tile: Vector2i) -> bool:
	return posmod(tile.x + 2 * tile.y, PIPE_ICON_EVERY) == 0


## Cells of a grid for `n` icons in a square of side 1 (top-left corners and the cell's side), as
## Factorio fits a filter inserter's filters into the one icon's room: 2 side by side, 3 and 4 in a
## 2 x 2 square, 5 in 3 + 2; a last row that isn't full is centred.
static func grid(n: int) -> Array:
	var cols := ceili(sqrt(float(n)))
	var rows := ceili(float(n) / cols)
	var cell := 1.0 / maxi(cols, rows)
	var top := (1.0 - rows * cell) * 0.5
	var out := []
	for i in n:
		var row := i / cols
		var in_row := mini(cols, n - row * cols)
		var left := (1.0 - in_row * cell) * 0.5
		out.append([Vector2(left + (i % cols) * cell, top + row * cell), cell])
	return out


## The icons in the one icon's square of side `tiles` (grid: a filter inserter's filters, a chest's
## kinds), centred `shift` tiles from the entity's centre (its icon_draw_specification).
func _draw_icon(world, camera: Camera3D, r: WorldMirror.Rec, textures: Array[Texture2D], tiles: float, shift := Vector2.ZERO) -> void:
	if r == null or textures.is_empty():
		return
	var cells := []
	for c in grid(textures.size()):
		var side: float = float(c[1])
		cells.append([shift + ((c[0] as Vector2) + Vector2(side, side) * 0.5 - Vector2(0.5, 0.5)) * tiles, side * tiles])
	_draw_cells(world, camera, r, textures, cells, tiles)


## Draws `textures` at `cells` ([[centre (tiles from the entity's icon point, right and down on the
## screen), side (tiles)], ...]), with `qualities`' marks where not normal. `ref` is the size of the
## entity's own icon: its size on screen is held between 8 and 80 pixels, and every cell scales with it.
func _draw_cells(world, camera: Camera3D, r: WorldMirror.Rec, textures: Array[Texture2D], cells: Array, ref: float,
		qualities: Array[String] = []) -> void:
	if r == null or textures.is_empty():
		return
	var proto = world.protos.entity(r.proto_id)
	if proto == null:
		return
	var c: Vector2 = WorldMirror.selection_rect(proto, r.pos, r.dir).get_center()
	if _fog != null and not _fog.seen(c):
		return
	var at := Vector3(c.x, Visuals.height_for(proto), c.y)
	if _in_3d:
		# Lifted onto the hills by the quads' shader.
		_place_quads(world, camera, at + Vector3(0, ref * 0.5, 0), textures, cells, qualities)
		return
	# Over the building where an add-on's hills put it, not on the flat ground under the hill.
	at.y += GroundHeight.at(at.x, at.z)
	if camera.is_position_behind(at):
		return
	var p := camera.unproject_position(at)
	var edge := camera.unproject_position(at + camera.global_basis.x * ref * 0.5)
	var half := clampf(p.distance_to(edge), Kit.px(4), Kit.px(40))
	var per_tile := half * 2.0 / ref
	for i in mini(textures.size(), cells.size()):
		if textures[i] == null:
			continue
		var side: float = float(cells[i][1]) * per_tile
		var mid: Vector2 = p + (cells[i][0] as Vector2) * per_tile
		var s := side * 0.65
		_shadows.append(Rect2(mid - Vector2(s, s), Vector2(s, s) * 2.0))
		var rects: Array = _icons.get(textures[i], [])
		if rects.is_empty():
			_icons[textures[i]] = rects
		rects.append(Rect2(mid - Vector2(side, side) * 0.5, Vector2(side, side)))
		var mark: Texture2D = Slot.quality_icon(qualities[i]) if i < qualities.size() else null
		if mark != null:
			var qs := side * QUALITY_SHARE
			var marks: Array = _marks.get(mark, [])
			if marks.is_empty():
				_marks[mark] = marks
			marks.append(Rect2(mid + Vector2(-side * 0.5, side * 0.5 - qs), Vector2(qs, qs)))


var _in_3d := false
## This frame's icons: their shadows, their rectangles by picture and their quality marks by picture
## (drawn in that order).
var _shadows: Array[Rect2] = []
var _icons := {}  # Texture2D -> [Rect2, ...]
var _marks := {}  # Texture2D -> [Rect2, ...]
## First person: the quads this frame used for quality marks (not counted as icons).
var _marks_3d := 0
## Icons drawn in the last frame (tests, the stutter probe).
var drawn := 0


## First person: the icons over `top` as camera-facing quads in the world, at the same cells
## (tiles right and down from `top`), their quality marks a little in front.
func _place_quads(world, camera: Camera3D, top: Vector3, textures: Array[Texture2D], cells: Array,
		qualities: Array[String] = []) -> void:
	if _quad_holder == null or not is_instance_valid(_quad_holder):
		_quad_holder = Node3D.new()
		_quad_holder.name = "AltIcons3D"
		(world as Node).get_parent().add_child(_quad_holder)
		_quads.clear()
	var right := camera.global_basis.x
	var up := camera.global_basis.y
	var toward := camera.global_basis.z
	for i in mini(textures.size(), cells.size()):
		if textures[i] == null:
			continue
		var side: float = float(cells[i][1])
		var mid: Vector2 = cells[i][0]
		var at := top + right * mid.x - up * mid.y
		_quad(at, side, textures[i])
		var mark: Texture2D = Slot.quality_icon(qualities[i]) if i < qualities.size() else null
		if mark != null:
			var qs := side * QUALITY_SHARE
			_quad(at + right * (qs - side) * 0.5 - up * (side - qs) * 0.5 + toward * 0.02, qs, mark)
			_marks_3d += 1


func _quad(at: Vector3, side: float, texture: Texture2D) -> void:
	if _quads_used >= _quads.size():
		var q := MeshInstance3D.new()
		var mesh := QuadMesh.new()
		mesh.size = Vector2.ONE
		q.mesh = mesh
		q.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		_quad_holder.add_child(q)
		_quads.append(q)
	var q := _quads[_quads_used]
	_quads_used += 1
	q.position = at
	q.scale = Vector3(side, side, side)
	q.material_override = _quad_material(texture)
	q.visible = true


func _quad_material(texture: Texture2D) -> ShaderMaterial:
	var m: ShaderMaterial = _quad_materials.get(texture)
	if m == null:
		m = ShaderMaterial.new()
		m.shader = DepthIcon
		m.set_shader_parameter("icon", texture)
		_quad_materials[texture] = m
	return m


## Hides the quads this frame didn't use (all of them out of first person).
func _hide_quads() -> void:
	for i in range(_quads_used, _quads.size()):
		_quads[i].visible = false
