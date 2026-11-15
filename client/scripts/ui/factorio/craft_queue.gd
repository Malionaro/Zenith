extends HBoxContainer
## Factorio's crafting queue in the bottom-left corner: one crafting_queue_slot per queue entry
## with the recipe's icon and count, the first with the orange progress pie, the slots touching;
## the tooltip is Factorio's recipe tooltip. Click cancels one craft, right click five,
## Shift+click the whole entry; the ingredients come back. Needs the mod's
## `cq` (ui_model.craft_queue); with only the queue length (`me.q`) it shows nothing.
##
## `cq` says how far the first craft is six times a second. Zenith draws the pie itself: from where
## the craft stood when it started, by the recipe's time and the character's crafting speed, at the
## game's measured tick rate (owner's P47: it stepped along). Each craft is checked against the
## bridge once, the first `cq` after it starts; the others don't move it unless they are far off
## (owner's I26). A craft asked for shows here at once (ui_model `craft`, P48), its pie already
## moving.
##
## J13: the row holds as many slots as the HUD leaves it room for (set_room, from factorio_ui.gd's
## layout). A longer queue ends the row with "+N" (the entries left over); hovering it opens them
## upwards over the row, in rows as wide as it, and a click on it holds them open (pressed) so
## crafts can be cancelled there, until it is clicked again or the queue fits the row.

const Kit := preload("res://scripts/ui/factorio/kit.gd")
const Slot := preload("res://scripts/ui/factorio/slot.gd")
const UiModel := preload("res://scripts/ui/factorio/ui_model.gd")
const CraftingPanel := preload("res://scripts/ui/factorio/crafting_panel.gd")

## Slots in the row until the HUD's layout says how many fit (this many fill a row at 1280x720
## beside the weapons).
const MAX_SHOWN := 12
## An update further than this from the drawn pie is a new craft: it jumps there instead of easing;
## past PIE_CHECKED a craft already checked is out of step (a pause, a lost update) and is corrected.
const PIE_SNAP := 0.4
const PIE_CHECKED := 0.15
## How fast the drawn pie closes on what `cq` said (per second).
const PIE_EASE := 8.0
## With no `cq` for this long the game is paused or gone: the pie waits.
const PIE_WAIT_MS := 700

var model: UiModel
var _slots: Array[Slot] = []
## The first craft's drawn progress (-1: nothing crafting), what is left to correct, the recipe and
## how many remain, and when and at which game tick the last `cq` came.
var _pie := -1.0
var _pie_gap := 0.0
var _pie_recipe := ""
var _pie_count := 0
var _pie_at_ms := 0
var _pie_tick := 0
var _ticks_per_s := 60.0
## The drawn craft has been checked against a `cq` (once a craft, I26), and the last progress
## reported (the queue shown again for a predicted craft repeats it: not a new report).
var _pie_checked := false
var _pie_reported := -1.0
## How many slots the row has room for (the last one "+N" when the queue is longer).
var _fit := MAX_SHOWN
## "+N" at the row's end, and the entries it opens upwards (rows of _fit slots, the first of them
## nearest the row); held open by a click on "+N".
var more_button: Button
var more_panel: VBoxContainer
var _more_slots: Array[Slot] = []
var pinned := false
## The queue's entries now (count > 0), in order.
var _entries: Array = []


func _ready() -> void:
	anchor_top = 1.0
	anchor_bottom = 1.0
	grow_vertical = Control.GROW_DIRECTION_BEGIN
	offset_left = Kit.px(8)
	offset_bottom = -Kit.px(8)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_theme_constant_override("separation", 0)  # crafting_queue_slots touch, as in Factorio
	more_button = Button.new()
	more_button.name = "More"
	more_button.theme_type_variation = "FQueueSlot"
	more_button.custom_minimum_size = Kit.pxv(Kit.SLOT, Kit.SLOT)
	more_button.focus_mode = Control.FOCUS_NONE
	more_button.toggle_mode = true
	more_button.add_theme_font_override("font", Kit.font("bold"))
	more_button.add_theme_font_size_override("font_size", Kit.px(14))
	more_button.visible = false
	more_button.toggled.connect(func(on: bool) -> void:
		pinned = on
		_place_more())
	add_child(more_button)
	more_panel = VBoxContainer.new()
	more_panel.name = "MoreCrafts"
	more_panel.top_level = true  # over the row, outside its layout
	more_panel.add_theme_constant_override("separation", 0)
	more_panel.visible = false
	add_child(more_panel)
	model.queue_changed.connect(refresh)
	refresh()


## The width the HUD leaves the row (pixels): as many slots as fit, at least two.
func set_room(px: float) -> void:
	var fit := maxi(2, floori(px / float(Kit.px(Kit.SLOT))))
	if fit != _fit:
		_fit = fit
		refresh()


## How many entries the queue has.
func entry_count() -> int:
	return _entries.size()


## How many entries the row shows itself (the rest behind "+N").
func shown_in_row() -> int:
	return _entries.size() if _entries.size() <= _fit else _fit - 1


func refresh() -> void:
	_entries = []
	for e in model.craft_queue:
		if e is Dictionary and int(e.get("count", 0)) > 0:
			_entries.append(e)
	var shown := shown_in_row()
	while _slots.size() < shown:
		_slots.append(_new_slot(_slots.size()))
	for i in _slots.size():
		var s := _slots[i]
		s.visible = i < shown
		if s.visible:
			_show_entry(s, i)
	var rest := _entries.size() - shown
	more_button.visible = rest > 0
	more_button.text = "+%d" % rest
	more_button.tooltip_text = "%d more in the queue: click to keep them open" % rest
	move_child(more_button, get_child_count() - 1)
	if rest <= 0 and pinned:
		more_button.set_pressed_no_signal(false)
		pinned = false
	_fill_more(shown)
	if _entries.is_empty():
		_pie = -1.0
		_pie_recipe = ""


## Entry `i` of the queue on slot `s`: its recipe's icon and count, the pie on the first, what a
## click cancels, Factorio's recipe tooltip.
func _show_entry(s: Slot, i: int) -> void:
	var e: Dictionary = _entries[i]
	var recipe := str(e.get("recipe", ""))
	var r := model.recipe(recipe)
	s.set_stack(_icon_item(recipe, r), int(e.get("count", 1)))
	if i == 0:
		_pie_update(recipe, int(e.get("count", 1)), float(e.get("progress", 0.0)))
		s.set_progress(_pie)
	else:
		s.set_progress(-1.0)
	s.set_meta("index", 0 if e.get("predicted", false) else int(e.get("index", i + 1)))
	s.set_meta("count", int(e.get("count", 1)))
	s.set_tip("%s (Recipe)" % Kit.recipe_name(recipe), CraftingPanel.recipe_tip_lines(model, r))


## The entries from `first` on, in rows of _fit going up: the first row nearest the queue's row.
func _fill_more(first: int) -> void:
	var rest := maxi(0, _entries.size() - first)
	while _more_slots.size() < rest:
		var s := _new_slot(-1)
		remove_child(s)
		_more_slots.append(s)
	var rows := ceili(rest / float(_fit))
	while more_panel.get_child_count() < rows:
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 0)
		row.mouse_filter = Control.MOUSE_FILTER_IGNORE
		more_panel.add_child(row)
	for i in more_panel.get_child_count():
		(more_panel.get_child(i) as Control).visible = i < rows
	for i in _more_slots.size():
		var s := _more_slots[i]
		s.visible = i < rest
		if not s.visible:
			continue
		# The first _fit of them are the panel's last row, the one over the queue's row.
		var row: Control = more_panel.get_child(rows - 1 - floori(float(i) / _fit))
		if s.get_parent() != row:
			if s.get_parent() != null:
				s.get_parent().remove_child(s)
			row.add_child(s)
		row.move_child(s, mini(i % _fit, row.get_child_count() - 1))
		_show_entry(s, first + i)
	_place_more()


## The open rest sits on top of the row, its left edge with the row's; hidden while neither held
## open nor under the mouse.
func _place_more() -> void:
	var open := more_button.visible and (pinned or _more_hovered())
	more_panel.visible = open
	if not open:
		return
	more_panel.reset_size()
	var at := get_global_rect().position
	more_panel.global_position = Vector2(at.x, at.y - more_panel.size.y)


## The mouse is on "+N" or on what it opened (flush over the row: no gap to cross on the way up).
func _more_hovered() -> bool:
	if more_button.is_hovered():
		return true
	if not more_panel.visible or not is_inside_tree():
		return false
	return more_panel.get_global_rect().has_point(get_viewport().get_mouse_position())


## A `cq` (or the same craft shown again): measures the game's tick rate and corrects the drawn pie.
func _pie_update(recipe: String, count: int, progress: float) -> void:
	if recipe == _pie_recipe and count == _pie_count and is_equal_approx(progress, _pie_reported) and _pie >= 0.0:
		return
	_pie_reported = progress
	var now := Time.get_ticks_msec()
	var tick: int = Bridge.server_tick
	if _pie_at_ms > 0 and now > _pie_at_ms and tick > _pie_tick:
		var measured := float(tick - _pie_tick) * 1000.0 / float(now - _pie_at_ms)
		_ticks_per_s = lerpf(_ticks_per_s, clampf(measured, 1.0, 120.0), 0.2)
	_pie_at_ms = now
	_pie_tick = tick
	var gap := progress - _pie
	gap -= roundf(gap)  # 0.98 drawn and 0.02 sent: the craft came round, 0.04 ahead
	if recipe != _pie_recipe or _pie < 0.0 or absf(gap) > PIE_SNAP:
		# a craft starts: drawn from where the game has it, checked with the next `cq`
		_pie = progress
		_pie_gap = 0.0
		_pie_checked = false
	elif count != _pie_count:
		# the next craft of the entry: the drawn pie came round already (or is about to); this is its check
		if _pie > 0.5 and progress < 0.5:
			_pie -= 1.0
		_pie_gap = progress - _pie
		_pie_checked = true
	elif not _pie_checked or absf(gap) > PIE_CHECKED:
		_pie_gap = gap
		_pie_checked = true
	_pie_recipe = recipe
	_pie_count = count


func _process(delta: float) -> void:
	model.expire_predicted_crafts()
	if more_button.visible:
		_place_more()  # opened by the mouse on "+N" or held by a click; follows the row
	elif more_panel.visible:
		more_panel.visible = false
	if _pie < 0.0 or _slots.is_empty() or not _slots[0].visible:
		return
	if Time.get_ticks_msec() - _pie_at_ms < PIE_WAIT_MS:
		_pie += _pie_rate() * delta
	var ease_by := _pie_gap * (1.0 - exp(-delta * PIE_EASE))
	_pie += ease_by
	_pie_gap -= ease_by
	if _pie >= 1.0:
		# A craft done: on to the next if there is one, else full until the game says it is gone.
		_pie = fmod(_pie, 1.0) if _pie_count > 1 else 0.999
		_pie_checked = _pie_count <= 1
	_pie = maxf(_pie, 0.0)
	_slots[0].set_progress(_pie)


## How much of the first craft a second makes: 0 when the recipe's details aren't known.
func _pie_rate() -> float:
	var energy := float(model.recipe(_pie_recipe).get("energy", -1.0))
	if energy <= 0.0:
		return 0.0
	# `cinfo` craft: the character's crafting speed in thousandths.
	var speed := float(model.character_info.get("craft", 1000)) / 1000.0
	return speed / energy * _ticks_per_s / 60.0


func _new_slot(_i: int) -> Slot:
	var s := Slot.new()
	s.theme_type_variation = "FQueueSlot"
	var on_click := func(button_index: int, shift: bool) -> void:
		if button_index == MOUSE_BUTTON_MIDDLE or int(s.get_meta("index", 0)) <= 0:
			return  # no index: shown ahead of the game, which hasn't numbered it yet
		var n := 5 if button_index == MOUSE_BUTTON_RIGHT else 1
		if shift:
			n = int(s.get_meta("count", 1))
		model.cancel_craft(int(s.get_meta("index", 1)), n)
	s.clicked.connect(on_click)
	add_child(s)
	return s


static func _icon_item(recipe: String, r: Dictionary) -> String:
	var products: Array = r.get("products", [])
	if products.size() == 1 and products[0] is Array:
		return str(products[0][0])
	return recipe
