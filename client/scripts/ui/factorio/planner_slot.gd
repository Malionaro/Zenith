extends "res://scripts/ui/factorio/slot.gd"
## A slot holding a blueprint, book or planner, drawn as Factorio draws them: the item's picture
## with the record's icons over it (one big, or up to four in a square), its label in the tooltip.
## The blueprint library and the book window drag these about: dragging carries {"f3d_record":
## index, "from": the owner's id}, and dropping calls `on_record_drop(from_index, owner_id)`.

const BpString := preload("res://scripts/ui/factorio/bp_string.gd")
const BlueprintPicture := preload("res://scripts/ui/factorio/blueprint_picture.gd")

## [[type, name], ...] drawn over the item.
var icons: Array = []
## Where this slot sits in its list (drag and drop).
var index := -1
## Which list it belongs to, so drops between lists can be told apart.
var owner_id := 0
## Called with (from index, from owner id) when a record is dropped here.
var on_record_drop := Callable()
## Draws a frame round it: the book's active page, the selected record.
var marked := false
## The list views' big picture: the item and its icons fill the slot (Factorio's book and library
## rows), the active one framed green.
var big := false
## The record shown (set_record), for its tooltip's picture.
var record := {}


func set_record(r: Dictionary) -> void:
	record = r
	set_stack(BpString.item_of(r), -1)
	icons = BpString.icons(r)
	var lines: Array = []
	var d := BpString.description(r)
	if d != "":
		lines.append([d])
	match BpString.kind(r):
		"blueprint":
			var n := 0
			for c in BpString.components(r):
				n += int(c[1])
			lines.append(["%d entities and tiles" % n, "", Kit.DISABLED_TEXT])
		"blueprint_book":
			lines.append(["%d blueprints" % BpString.pages(r).size(), "", Kit.DISABLED_TEXT])
	set_tip(BpString.title(r), lines)
	queue_redraw()


## The record's own picture: a blueprint's, a book's active page's (K11).
func _tip_picture() -> Control:
	if record.is_empty():
		return null
	var page := BlueprintPicture.page_of(record)
	if BpString.kind(page) != "blueprint" or BpString._list(BpString.body(page).get("entities")).is_empty() 			and BpString._list(BpString.body(page).get("tiles")).is_empty():
		return null
	var picture := BlueprintPicture.new()
	picture.record = page
	picture.protos = picture_protos.call() if picture_protos.is_valid() else null
	return picture


func set_listed(item_name: String, label: String, list_icons: Array) -> void:
	record = {}
	set_stack(item_name, -1)
	icons = list_icons
	set_tip(label if label != "" else "Untitled")
	queue_redraw()


func _draw() -> void:
	if big:
		_draw_big()
		return
	super()
	if item == "":
		return
	var n := mini(icons.size(), 4)
	if n > 0:
		var cell := float(Kit.px(28 if n == 1 else 14))
		var origin := (size - Vector2(cell, cell) * (1.0 if n == 1 else 2.0)) * 0.5
		for i in n:
			var at := origin + Vector2(i % 2, i / 2) * cell if n > 1 else origin
			draw_texture_rect(Kit.item_icon(str(icons[i][1])), Rect2(at, Vector2(cell, cell)), false)
	if marked:
		draw_rect(Rect2(Vector2.ZERO, size).grow(-Kit.px(1)), Kit.ORANGE, false, Kit.px(2))


func _get_drag_data(_at_position: Vector2) -> Variant:
	if item == "" or index < 0:
		return null
	var preview := TextureRect.new()
	preview.texture = Kit.item_icon(item)
	preview.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	preview.size = Kit.pxv(32, 32)
	preview.position = -preview.size * 0.5
	var holder := Control.new()
	holder.add_child(preview)
	set_drag_preview(holder)
	return {"f3d_record": index, "from": owner_id}


func _can_drop_data(_at_position: Vector2, data: Variant) -> bool:
	return on_record_drop.is_valid() and data is Dictionary and data.has("f3d_record")


func _drop_data(_at_position: Vector2, data: Variant) -> void:
	on_record_drop.call(int(data["f3d_record"]), int(data.get("from", 0)))


func _draw_big() -> void:
	var side := minf(size.x, size.y) - Kit.px(8)
	var rect := Rect2((size - Vector2(side, side)) * 0.5, Vector2(side, side))
	if marked:
		draw_rect(Rect2(Vector2.ZERO, size).grow(-Kit.px(2)), Color8(90, 200, 70), false, Kit.px(4))
	if item == "":
		return
	draw_texture_rect(Kit.item_icon(item), rect, false)
	var n := mini(icons.size(), 4)
	if n == 0:
		return
	var cell := side * (0.6 if n == 1 else 0.32)
	var origin := rect.position + (rect.size - Vector2(cell, cell) * (1.0 if n == 1 else 2.0)) * 0.5
	for i in n:
		var at := origin + Vector2(i % 2, i / 2) * cell if n > 1 else origin
		draw_texture_rect(Kit.item_icon(str(icons[i][1])), Rect2(at, Vector2(cell, cell)), false)
