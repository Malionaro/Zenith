extends Node3D
## What Factorio's pollution does to the land (owner's I15), from the bridge's `pol` (pollution.lua:
## each chunk's pollution round the focus, every five seconds). One texel a chunk round the view,
## read by the shaders through pollution.gdshaderinc: trees' leaves grey, thin and fall where it is
## heavy (factorio_material.gdshaderinc LEAF_CUT), lakes turn a murky green (water.gdshader), and a
## smog lies over the ground (shaders/smog.gdshader, a full-screen pass like the remote view's fog,
## Settings > Graphics > Smog). Nothing where there is no pollution, and nothing on a space platform
## (the bridge sends none there, and a change of surface clears it). The smog's pass is drawn only
## while a chunk it can read for the camera holds smog (smog_in_view).
##
## Levels ease towards each update over EASE seconds, so a tree doesn't drop its leaves in one
## frame when the numbers come in, and the smog thickens and thins gently.

const Settings := preload("res://scripts/menu/settings.gd")
const SMOG_SHADER := preload("res://shaders/smog.gdshader")
const GLOBAL_TEX := &"f3d_pollution"
const GLOBAL_RECT := &"f3d_pollution_rect"
## Chunks a side of the texture (2,048 tiles), centred near the view; the bridge sends 25 x 25.
const SIZE := 64
## Re-centred when the view gets this many chunks from the texture's middle.
const RECENTRE := 16
## Seconds to ease a chunk from its old level to the new one.
const EASE := 4.0
## How often the texture is written while levels ease (a few hundred pixels a write).
const WRITE_EVERY := 0.1
## Trees: unharmed up to the map's tree damage threshold (`md`, Factorio's
## min_pollution_to_damage_trees, 60 by default), bare at BARE times it. Factorio damages trees over
## time above the threshold; the chunks round a factory, which sit far above it for hours, are the
## ones whose trees are dead, so the level grows with the logarithm of the pollution.
const BARE := 15.0
## Smog: none below SMOG_FROM, thickest at SMOG_FULL (Factorio's pollution map turns deep red there).
const SMOG_FROM := 40.0
const SMOG_FULL := 4000.0
## The least smog a chunk's texel can hold above 0 (half the 8-bit texture's first step: a level
## under it is written as 0). The pass draws nothing where every texel it reads is 0, but even one
## step shows in first person, where a ray runs hundreds of tiles through the layer.
const SMOG_SHOWN := 0.5 / 255.0
## How far under the lowest ground the smog's layer reaches (smog.gdshader: a tile, and a margin).
const LAYER_BELOW := 1.5
const GroundHeight := preload("res://scripts/world/ground_height.gd")

var _image := Image.create(SIZE, SIZE, false, Image.FORMAT_RG8)
var _texture: ImageTexture
var _origin := Vector2i.ZERO
var _damage := 60.0
## Chunk -> Vector2(dying, smog) as the last `pol` says, and as drawn now (easing towards it).
var _target := {}
var _shown := {}
var _easing := false
var _write_timer := 0.0
var _redraw := true
var _quad := MeshInstance3D.new()
var _material := ShaderMaterial.new()
var _strength := 0.5
## Chunks whose texel holds smog (as last written), their bounds, and a count of the writes that
## changed them; whether the view has any of them, for the view's chunks and the write it was found for.
var _smog_chunks: Array[Vector2i] = []
var _smog_bounds := Rect2i()
var _smog_version := 0
var _seen := false
var _seen_rect := Rect2i()
var _seen_version := -1


func _ready() -> void:
	_texture = ImageTexture.create_from_image(_image.duplicate() as Image)
	RenderingServer.global_shader_parameter_set(GLOBAL_TEX, _texture)
	RenderingServer.global_shader_parameter_set(GLOBAL_RECT, Vector4(0.0, 0.0, 32.0, 0.0))
	_material.shader = SMOG_SHADER
	# After the see-through things (ghosts, smoke, item cards, effects: up to 2), before the remote
	# view's fog (5), which covers it, and the cursor's build preview and name tags (10).
	_material.render_priority = 4
	var quad := QuadMesh.new()
	quad.size = Vector2(2.0, 2.0)
	_quad.mesh = quad
	_quad.material_override = _material
	_quad.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_quad.extra_cull_margin = 16384.0  # it covers the screen wherever it is
	_quad.name = "Smog"
	_quad.visible = false
	add_child(_quad)
	_read_setting()
	Settings.listen(_on_setting)


func _exit_tree() -> void:
	RenderingServer.global_shader_parameter_set(GLOBAL_RECT, Vector4(0.0, 0.0, 32.0, 0.0))


## `pol` from the bridge: the whole square round the focus (w 0: none).
func handle(msg: Dictionary) -> void:
	_target.clear()
	var w := int(msg.get("w", 0))
	if w > 0:
		_damage = maxf(1.0, float(msg.get("md", 60)))
		var cx := int(msg.get("cx", 0))
		var cy := int(msg.get("cy", 0))
		var l: Variant = msg.get("l")
		var values: Array = l if l is Array else []
		for i in mini(values.size(), w * w):
			var p := float(values[i])
			if p > 0.0:
				var level := levels(p, _damage)
				if level != Vector2.ZERO:
					_target[Vector2i(cx + i % w, cy + i / w)] = level
	_easing = true


## A new surface (or a new game): everything goes at once, nothing eases over from the last one.
func clear() -> void:
	_target.clear()
	_shown.clear()
	_smog_chunks = []
	_smog_version += 1
	_easing = false
	_redraw = true


## (dying, smog), each 0 to 1, for `p` pollution on a map whose trees take damage from `damage`.
static func levels(p: float, damage: float) -> Vector2:
	var dying := clampf(log(p / damage) / log(BARE), 0.0, 1.0) if p > damage else 0.0
	var smog := 0.0
	if p > SMOG_FROM:
		smog = clampf(log(p / SMOG_FROM) / log(SMOG_FULL / SMOG_FROM), 0.0, 1.0)
	return Vector2(dying, smog)


## Every frame: the view's focus (tiles) and the game's darkness (0 day to about 0.85 at night).
func update(at: Vector2, darkness: float, delta: float) -> void:
	var chunk := Vector2i(floori(at.x / 32.0), floori(at.y / 32.0))
	var middle := _origin + Vector2i(SIZE / 2, SIZE / 2)
	if absi(chunk.x - middle.x) > RECENTRE or absi(chunk.y - middle.y) > RECENTRE:
		_origin = chunk - Vector2i(SIZE / 2, SIZE / 2)
		_redraw = true
	if _easing:
		_ease(delta)
	_write_timer -= delta
	if _redraw and _write_timer <= 0.0:
		_write_timer = WRITE_EVERY
		_redraw = false
		_write()
	_material.set_shader_parameter("light", clampf(1.0 - darkness * 0.9, 0.12, 1.0))
	# Only while smog can show in view: the pass reads the depth and does its sums on every pixel
	# before discarding them (estimated at 0.1 ms at 4K), and any pollution in the bridge's 25 x 25
	# chunks round the focus kept it on wherever the view was.
	_quad.visible = _strength > 0.001 and smog_in_view()


## Whether a chunk the smog pass can read for the camera now holds smog.
func smog_in_view() -> bool:
	if _smog_chunks.is_empty():
		return false
	var cam := get_viewport().get_camera_3d()
	if cam == null:
		return true
	var view: Variant = view_chunks(cam, get_viewport().get_visible_rect().size, GroundHeight.lift_range().x - LAYER_BELOW)
	if not (view is Rect2i):
		return true
	var rect: Rect2i = view
	if rect == _seen_rect and _seen_version == _smog_version:
		return _seen
	_seen_rect = rect
	_seen_version = _smog_version
	_seen = false
	if rect.intersects(_smog_bounds):
		for c in _smog_chunks:
			if rect.has_point(c):
				_seen = true
				break
	return _seen


## The chunks the smog pass can read for this camera: every pixel's ray is cut to the layer before
## its pollution is read, so what it reads lies between the camera and where the screen's corners
## meet the layer's bottom (`low`); and a chunk round that, as the pass reads between chunk centres.
## null when a corner doesn't come down to it (the horizon in view): anything may then show.
static func view_chunks(cam: Camera3D, screen: Vector2, low: float) -> Variant:
	var lo := Vector2(INF, INF)
	var hi := Vector2(-INF, -INF)
	for p: Vector2 in [Vector2.ZERO, Vector2(screen.x, 0.0), Vector2(0.0, screen.y), screen]:
		var origin := cam.project_ray_origin(p)
		var ray := cam.project_ray_normal(p)
		if origin.y <= low or ray.y > -0.01:
			return null
		var hit := origin + ray * ((low - origin.y) / ray.y)
		for q: Vector2 in [Vector2(origin.x, origin.z), Vector2(hit.x, hit.z)]:
			lo = Vector2(minf(lo.x, q.x), minf(lo.y, q.y))
			hi = Vector2(maxf(hi.x, q.x), maxf(hi.y, q.y))
	var a := Vector2i(floori(lo.x / 32.0) - 1, floori(lo.y / 32.0) - 1)
	var b := Vector2i(floori(hi.x / 32.0) + 1, floori(hi.y / 32.0) + 1)
	return Rect2i(a, b - a + Vector2i.ONE)


## Moves every shown level towards its target; those that reach 0 are let go.
func _ease(delta: float) -> void:
	var step := delta / EASE
	var moving := false
	for c in _target:
		if not _shown.has(c):
			_shown[c] = Vector2.ZERO
	for c in _shown.keys():
		var now: Vector2 = _shown[c]
		var want: Vector2 = _target.get(c, Vector2.ZERO)
		if now == want:
			if want == Vector2.ZERO:
				_shown.erase(c)
			continue
		var next := Vector2(move_toward(now.x, want.x, step), move_toward(now.y, want.y, step))
		_shown[c] = next
		moving = true
	_easing = moving
	_redraw = true


## The shown levels into the texture. Writes a copy, as remote_fog.gd does: with the renderer on its
## own thread the upload happens there later.
func _write() -> void:
	_image.fill(Color.BLACK)
	var bounds := Rect2i(Vector2i.ZERO, Vector2i(SIZE, SIZE))
	var smoggy: Array[Vector2i] = []
	var smog_bounds := Rect2i()
	for c: Vector2i in _shown:
		var local := c - _origin
		if bounds.has_point(local):
			var v: Vector2 = _shown[c]
			_image.set_pixelv(local, Color(v.x, v.y, 0.0))
			if v.y >= SMOG_SHOWN:
				smog_bounds = Rect2i(c, Vector2i.ONE) if smoggy.is_empty() else smog_bounds.merge(Rect2i(c, Vector2i.ONE))
				smoggy.append(c)
	if smoggy != _smog_chunks:
		_smog_chunks = smoggy
		_smog_bounds = smog_bounds
		_smog_version += 1
	_texture.update(_image.duplicate() as Image)
	var on := 0.0 if _shown.is_empty() else 1.0
	RenderingServer.global_shader_parameter_set(GLOBAL_RECT, Vector4(_origin.x * 32.0, _origin.y * 32.0, 32.0, on))


## The Smog setting as drawn now, 0 to 1 (settings_probe.gd reads it).
func strength() -> float:
	return _strength


func _on_setting(section: String, key: String) -> void:
	if section == "graphics" and key == "smog":
		_read_setting()


func _read_setting() -> void:
	_strength = clampf(float(Settings.get_value("graphics", "smog")), 0.0, 1.0)
	_material.set_shader_parameter("strength", _strength)
