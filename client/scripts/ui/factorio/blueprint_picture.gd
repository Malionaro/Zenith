extends Control
## A blueprint seen from above, as Factorio draws one in a blueprint's tooltip (K11) and in the
## blueprint window's preview (blueprint_window.gd, which draws with the static functions here): each
## entity's own sprite frame from the player's install (sprite_projection.gd's sheets: the frame for
## its direction, its anchor on the entity's position; belts their own animation's first frames),
## tiles as squares in their map colour. An entity without a sheet (or without Factorio) is its
## footprint in its map colour with its icon. A book shows its active page.
##
## As a tooltip's picture (slot.gd _tip_picture): `record` is the blueprint, or `source` gives it once
## it is known (an inventory blueprint is exported by the bridge on request), asked every frame until
## then; the picture keeps its size meanwhile, as a tooltip doesn't grow once shown.

const Kit := preload("res://scripts/ui/factorio/kit.gd")
const BpString := preload("res://scripts/ui/factorio/bp_string.gd")
const SpriteProjection := preload("res://scripts/world/sprite_projection.gd")
const ItemIcons := preload("res://scripts/world/item_icons.gd")
## Belts have no sheet in sprite_projection.json: their own animation sheet's first frames (rows
## east, west, north, south; a 128 px frame is 2 tiles).
const BELT_SHEETS := {"transport-belt": "base", "fast-transport-belt": "base", "express-transport-belt": "base",
	"turbo-transport-belt": "space-age"}
## The tooltip's picture (GUI pixels at 100%): this wide, as tall as the blueprint's shape asks
## within these, at most TILE_MOST pixels a tile.
const WIDTH := 240
const HEIGHT_LEAST := 64
const HEIGHT_MOST := 240
const HEIGHT_UNKNOWN := 180
const MARGIN := 8
const TILE_MOST := 24
const BACKGROUND := Color8(37, 37, 37)

var record := {}
var protos  # proto_db.gd: footprints and colours (optional)
var source := Callable()

static var _belts := {}  # name -> ImageTexture (four frames, east west north south) or null


func _init() -> void:
	name = "BlueprintPicture"
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	clip_contents = true


func _ready() -> void:
	record = page_of(record)
	var h := HEIGHT_UNKNOWN
	if not record.is_empty():
		var r := bounds(layout(record, protos))
		if r.size.x > 0.0:
			h = clampi(roundi(WIDTH * r.size.y / r.size.x), HEIGHT_LEAST, HEIGHT_MOST)
	custom_minimum_size = Kit.pxv(WIDTH, h)
	set_process(record.is_empty() and source.is_valid())


func _process(_delta: float) -> void:
	var r: Dictionary = source.call()
	if not r.is_empty():
		record = page_of(r)
		set_process(false)
		queue_redraw()


## The entities and tiles drawn (for tests): 0 while the record isn't known.
func item_count() -> int:
	return layout(record, protos).size() if not record.is_empty() else 0


func _draw() -> void:
	draw_rect(Rect2(Vector2.ZERO, size), BACKGROUND)
	if record.is_empty():
		return
	var items := layout(record, protos)
	var f := fit(items, size, float(Kit.px(MARGIN)), float(Kit.px(TILE_MOST)))
	draw_items(self, items, f[0], f[1], {})


## A book's active page; anything else as it is.
static func page_of(r: Dictionary) -> Dictionary:
	if BpString.kind(r) != "blueprint_book":
		return r
	var active := int(BpString.body(r).get("active_index", 0))
	for p in BpString.pages(r):
		if int(p[0]) == active:
			return p[1]
	return {}


## What is drawn: [rect in tiles, name ("" a tile), entity_number, colour, direction], tiles first.
static func layout(r: Dictionary, entity_protos) -> Array:
	var b := BpString.body(r)
	var items: Array = []
	for t in BpString._list(b.get("tiles")):
		var p: Dictionary = t.get("position", {})
		items.append([Rect2(float(p.get("x", 0)), float(p.get("y", 0)), 1, 1), "", 0, tile_color(entity_protos, str(t.get("name", ""))), 0])
	for e in BpString._list(b.get("entities")):
		var p: Dictionary = e.get("position", {})
		var size := Vector2.ONE
		var color := Color(0.45, 0.45, 0.45)
		if entity_protos != null:
			var proto = entity_protos.entities_by_name.get(str(e.get("name", "")))
			if proto != null:
				size = Vector2(proto.tile_size)
				color = proto.color
		var d := int(e.get("direction", 0))
		if d == 4 or d == 12:
			size = Vector2(size.y, size.x)
		var at := Vector2(float(p.get("x", 0)), float(p.get("y", 0)))
		items.append([Rect2(at - size * 0.5, size), str(e.get("name", "")), int(e.get("entity_number", 0)), color, d])
	return items


static func tile_color(entity_protos, tile_name: String) -> Color:
	if entity_protos != null:
		var i: int = entity_protos.tile_names.find(tile_name)
		if i >= 0 and i < entity_protos.tile_colors.size():
			return entity_protos.tile_colors[i]
	return Color(0.35, 0.35, 0.35)


## What the items cover, in tiles.
static func bounds(items: Array) -> Rect2:
	if items.is_empty():
		return Rect2()
	var r: Rect2 = items[0][0]
	for it in items:
		r = r.merge(it[0])
	return r


## [scale, offset]: tiles to pixels, the items fitted into `area` within `margin`, at most `most`
## pixels a tile.
static func fit(items: Array, area: Vector2, margin: float, most: float) -> Array:
	if items.is_empty():
		return [1.0, Vector2.ZERO]
	var r := bounds(items)
	var k := minf((area.x - margin * 2) / maxf(r.size.x, 1.0), (area.y - margin * 2) / maxf(r.size.y, 1.0))
	k = minf(k, most)
	return [k, area * 0.5 - r.get_center() * k]


## Back to front, as Factorio sorts them: tiles, then entities by their southern edge. `removed`:
## entity numbers drawn faded red (the blueprint window's right clicks).
static func draw_items(on: CanvasItem, items: Array, k: float, off: Vector2, removed: Dictionary) -> void:
	items.sort_custom(func(a: Array, b: Array) -> bool:
		if (str(a[1]) == "") != (str(b[1]) == ""):
			return str(a[1]) == ""
		return (a[0] as Rect2).end.y < (b[0] as Rect2).end.y)
	for it in items:
		var r := Rect2((it[0] as Rect2).position * k + off, (it[0] as Rect2).size * k)
		var gone: bool = removed.has(int(it[2])) and int(it[2]) > 0
		if str(it[1]) == "":
			on.draw_rect(r, (it[3] as Color).darkened(0.2))
			continue
		var tint := Color(1, 0.4, 0.4, 0.35) if gone else Color.WHITE
		if draw_sprite(on, str(it[1]), int(it[4]), r.get_center(), k, tint):
			continue
		on.draw_rect(r.grow(-1), Color(it[3], 0.35 if not gone else 0.12))
		var s := minf(r.size.x, r.size.y) * 0.8
		on.draw_texture_rect(Kit.item_icon(str(it[1])), Rect2(r.get_center() - Vector2(s, s) * 0.5, Vector2(s, s)), false,
			Color(1, 0.4, 0.4, 0.35) if gone else Color.WHITE)


## The entity's sprite frame with its anchor at `at`; false when there is no sheet for it.
static func draw_sprite(on: CanvasItem, entity: String, d: int, at: Vector2, k: float, tint: Color) -> bool:
	if BELT_SHEETS.has(entity):
		var sheet := belt(entity)
		if sheet == null:
			return false
		var row: int = {4: 0, 12: 1, 0: 2, 8: 3}.get(posmod(d, 16), 2)
		on.draw_texture_rect_region(sheet, Rect2(at - Vector2(k, k), Vector2(k, k) * 2.0), Rect2(0, row * 128, 128, 128), tint)
		return true
	var p = SpriteProjection.for_flat(entity)
	if p == null or p.texture == null or p.mode == 3 or p.cells < 1:
		return false
	var cell := 0
	if p.mode == 1:
		cell = (posmod(d, 16) / 4) % p.cells
	var slot := Vector2(float(p.atlas_size.x) / int(p.cells), float(p.atlas_size.y))
	var src := Rect2(Vector2(slot.x * cell, 0), slot)
	var ratio: float = k / float(p.px_per_tile)
	var anchor: Vector2 = p.anchors[cell]
	on.draw_texture_rect_region(p.texture, Rect2(at - (anchor - src.position) * ratio, slot * ratio), src, tint)
	return true


static func belt(entity: String) -> Texture2D:
	if _belts.has(entity):
		return _belts[entity]
	_belts[entity] = null
	var dir := ItemIcons.factorio_data_dir()
	var path := dir.path_join("%s/graphics/entity/%s/%s.png" % [BELT_SHEETS[entity], entity, entity]) if dir != "" else ""
	if path != "" and FileAccess.file_exists(path):
		var img := Image.load_from_file(path)
		if img != null and img.get_width() >= 128 and img.get_height() >= 512:
			_belts[entity] = ImageTexture.create_from_image(img.get_region(Rect2i(0, 0, 128, 512)))
	return _belts[entity]
