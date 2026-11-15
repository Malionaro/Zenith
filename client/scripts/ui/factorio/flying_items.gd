extends Control
## Items flying between the world and the player after a Ctrl+click (I3, I4), as Factorio 2.x shows
## a fast transfer: the item's icon with its count leaves the cursor for the building it went into,
## or leaves the building for the character it came to, on a short arc, shrinking and fading as it
## lands. factorio_ui.gd starts them when the mod's answer (the inventory changing) arrives.
## Ends are screen points (Vector2), world points (Vector3, followed as the camera moves), "mouse"
## or "character" (the player's character, from `player`).

const Kit := preload("res://scripts/ui/factorio/kit.gd")
const GroundHeight := preload("res://scripts/world/ground_height.gd")

const SECONDS := 0.42
## Each further item of one transfer leaves a little later.
const STAGGER := 0.07
const MAX_FLIGHTS := 24

## player_input.gd (avatar), for "character".
var player: Node = null

var _flights: Array = []  # [item, count text, from, to, start msec]


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	texture_filter = Kit.ICON_FILTER
	z_index = 99


## One item's icon (with "+n" / "-n") from `from` to `to`; `order` staggers several of one transfer.
func fly(item: String, count: int, from, to, order := 0) -> void:
	if item == "":
		return
	var text: String = (("+%s" if count > 0 else "-%s") % Kit.count_text(absi(count))) if count != 0 else ""
	_flights.append([item, text, from, to, Time.get_ticks_msec() + int(order * STAGGER * 1000.0)])
	while _flights.size() > MAX_FLIGHTS:
		_flights.pop_front()


func flying() -> int:
	return _flights.size()


func _process(_delta: float) -> void:
	if not _flights.is_empty() or _drawn:
		queue_redraw()


var _drawn := false


func _draw() -> void:
	_drawn = not _flights.is_empty()
	var now := Time.get_ticks_msec()
	var side := float(Kit.px(56))  # owner: larger than the 32 px slot icon, to read at a glance
	var i := 0
	while i < _flights.size():
		var f: Array = _flights[i]
		var t := float(now - int(f[4])) / (SECONDS * 1000.0)
		if t >= 1.0:
			_flights.remove_at(i)
			continue
		i += 1
		if t < 0.0:
			continue
		var a = _screen(f[2])
		var b = _screen(f[3])
		if a == null or b == null:
			continue
		var e := ease(t, -1.8)  # quick out, slowing in
		var at: Vector2 = (a as Vector2).lerp(b, e)
		at.y -= sin(t * PI) * float(Kit.px(56))  # a little arc, as a thrown thing
		var scale := lerpf(1.0, 0.75, t)
		var alpha := 1.0 - clampf((t - 0.7) / 0.3, 0.0, 1.0)
		var s := side * scale
		var rect := Rect2(at - Vector2(s, s) * 0.5, Vector2(s, s))
		draw_texture_rect(Kit.item_icon(str(f[0])), rect, false, Color(1, 1, 1, alpha))
		if str(f[1]) != "":
			var font := Kit.font("bold")
			var fs := Kit.px(22)
			var pos := rect.end + Vector2(Kit.px(2), 0)
			draw_string_outline(font, pos, str(f[1]), HORIZONTAL_ALIGNMENT_LEFT, -1, fs, Kit.px(5), Color(0, 0, 0, 0.9 * alpha))
			draw_string(font, pos, str(f[1]), HORIZONTAL_ALIGNMENT_LEFT, -1, fs, Color(1, 1, 1, alpha))


## An end of a flight on the screen now, or null (behind the camera, no character).
func _screen(where):
	if where is Vector2:
		return where
	if where is String:
		if where == "mouse":
			return get_local_mouse_position()
		if where == "character" and player != null and player.get("avatar") != null:
			var g: Vector2 = player.avatar.ground_position()
			where = Vector3(g.x, 1.2, g.y)
		else:
			return null
	if where is Vector3:
		# The building or character as drawn: an add-on's hills (ground_height.gd) lift them.
		var p := GroundHeight.lift(where as Vector3)
		var cam := get_viewport().get_camera_3d()
		if cam == null or cam.is_position_behind(p):
			return null
		return get_global_transform_with_canvas().affine_inverse() * cam.unproject_position(p)
	return null
