extends Control
## Factorio's flying text (issue #19): "+5 Iron plate (25)" and "-5 Coal (20)" rising from where
## items came into or left the inventory: mining, picking up, fast transfer. The bridge sends what
## changed in a `fly` message (docs/PROTOCOL.md); each line is a label pinned over its spot in the
## world, drifting up and fading out.

const LocaleNames := preload("res://scripts/world/locale_names.gd")

## Seconds a line shows, the last FADE of them fading out.
const LIFETIME := 2.0
const FADE := 0.6
## Tiles above the ground it starts at, and how far it rises over its life.
const START_HEIGHT := 1.2
const RISE := 1.0
## At most this many lines at once; the oldest go first.
const MAX_LINES := 24

## [label, world position, line index in its message, age in seconds], oldest first.
var _lines: Array = []


func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE


## One `fly` message: at (x, y) in tiles, l = [[item, change, total now], ...].
func add(at: Vector2, rows: Array) -> void:
	var index := 0
	for row in rows:
		if not (row is Array and row.size() >= 3):
			continue
		var change := int(row[1])
		if change == 0:
			continue
		var label := Label.new()
		label.text = text_for(str(row[0]), change, int(row[2]))
		label.theme_type_variation = "FGameLabel"
		label.mouse_filter = Control.MOUSE_FILTER_IGNORE
		label.visible = false  # placed on the next frame
		add_child(label)
		_lines.append([label, Vector3(at.x, START_HEIGHT, at.y), index, 0.0])
		index += 1
	while _lines.size() > MAX_LINES:
		(_lines.pop_front()[0] as Label).queue_free()


## "+5 Iron plate (25)", as Factorio writes it.
static func text_for(item: String, change: int, total: int) -> String:
	return "%s%d %s (%d)" % ["+" if change > 0 else "", change, LocaleNames.item(item), total]


func clear() -> void:
	for line in _lines:
		(line[0] as Label).queue_free()
	_lines.clear()


func _process(delta: float) -> void:
	if _lines.is_empty():
		return
	var cam := get_viewport().get_camera_3d()
	var keep: Array = []
	for line in _lines:
		var label: Label = line[0]
		line[3] = float(line[3]) + delta
		var age: float = line[3]
		if age >= LIFETIME or cam == null:
			label.queue_free()
			continue
		keep.append(line)
		var at: Vector3 = line[1] + Vector3(0.0, RISE * age / LIFETIME, 0.0)
		if cam.is_position_behind(at):
			label.visible = false
			continue
		var p := cam.unproject_position(at)
		label.reset_size()
		label.position = p + Vector2(-label.size.x * 0.5, label.size.y * (int(line[2]) - 1))
		label.modulate.a = clampf((LIFETIME - age) / FADE, 0.0, 1.0)
		label.visible = true
	_lines = keep
