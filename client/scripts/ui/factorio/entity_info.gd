extends PanelContainer
## Factorio's entity info panel on the right of the screen: what the mouse is over in the world,
## with its name, quality, health, working state, recipe (when Alt-mode or a screen told us),
## train stop name (rich text), ore left, ghost (with the item it needs and how many the inventory has)
## and deconstruction / upgrade marks, then the entity's stats from Factoriopedia's data (crafting
## speed, energy, pollution, health, resistances, module slots...), as Factorio's tooltips list them,
## the craft's progress and the burning fuel (drawn on between the mod's answers, I26), a crafting
## machine's ingredients and products a second (J15) and what is
## inside: a machine's input, output and fuel, a chest's or wagon's contents (I2). factorio_ui.gd places it
## under the minimap and calls show_entity() every frame with the hovered entity (or null).
##
## Laid out as Factorio 2.1's (measured on tools/ui_reference/hover.py's pictures): as wide as the
## side menu (256) and flush with it, a picture of the entity on a dark strip (its icon here, where
## Factorio films it), the name on the tooltip's cream title bar, a status dot and word, then the
## lines; no key hints.

const Kit := preload("res://scripts/ui/factorio/kit.gd")
const GuiAssets := preload("res://scripts/ui/factorio/gui_assets.gd")
const WorldMirror := preload("res://scripts/world/world.gd")
const Info := preload("res://scripts/ui/factorio/info_text.gd")
const RichText := preload("res://scripts/ui/factorio/rich_text.gd")
const Slot := preload("res://scripts/ui/factorio/slot.gd")
const ProductionPanels := preload("res://scripts/ui/factorio/production_panels.gd")
const SmoothBar := preload("res://scripts/ui/factorio/smooth_bar.gd")

const WIDTH := 256  # the side menu's width: Factorio's panel sits flush under it
const PICTURE := 96
## Entities whose modules and beacons the mod is asked about (`hinfo`).
const EFFECT_TYPES := ["beacon", "assembling-machine", "furnace", "mining-drill", "lab", "rocket-silo"]
## Entities whose contents the mod is asked about (`hinfo` `inv`, I2), besides those above, the
## electric ones and those burning fuel.
const CONTENT_TYPES := ["container", "logistic-container", "linked-container", "infinity-container", "cargo-wagon",
	"artillery-wagon", "artillery-turret", "ammo-turret", "car", "spider-vehicle", "roboport", "space-platform-hub",
	"cargo-landing-pad", "locomotive", "boiler", "reactor", "burner-generator"]
## The contents' headings by role, in Factorio's words.
const ROLE_NAMES := {"chest": "Contents", "trash": "Trash", "cargo": "Cargo", "trunk": "Trunk", "ammo": "Ammo",
	"input": "Input", "output": "Output", "robots": "Robots", "repair": "Repair packs", "fuel": "Fuel",
	"burnt": "Burnt result"}
## Slots a row in the contents' grids, and their size (the panel is 256 wide).
const CONTENT_COLUMNS := 6
const CONTENT_SLOT := 36
const EFFECT_NAMES := [["sp", "Speed"], ["pr", "Productivity"], ["co", "Consumption"], ["po", "Pollution"], ["q", "Quality"]]
## The "Consumes electricity" heading and the Electricity bar, sampled from Factorio's panel.
const HEADING := Color(1.0, 211 / 255.0, 73 / 255.0)
const BAR := Color(40 / 255.0, 209 / 255.0, 36 / 255.0)
## fluids_power.gd's power states (`pw`) as Factorio's status line words them.
const POWER_STATUS := {0: ["No power", "red"], 1: ["Low power", "yellow"], 2: ["Not plugged in electric network", "red"]}

var model
var player: Node = null

var _title: Label
var _icon: TextureRect
var _status: Label
var _dot: TextureRect
var _lines := VBoxContainer.new()
var _key := ""
## What _key was last made from, compared first (show_entity runs every frame the mouse is over
## something): the record, its extra's hash, health, working and power states, the `hinfo` answer
## (a new Dictionary per answer) and how much Factoriopedia knows. The key itself took three
## JSON.stringify calls and a copy of the answer every frame (client-cpu.md 8).
var _seen_rec: Object = null
var _seen_extra := 0
var _seen_health := -2.0
var _seen_working := -2
var _seen_power := -2
var _seen_info: Dictionary = {}
var _seen_stats := -1
var _no_info := {}  # (never written: the answer for entities nothing is asked about)
## The craft's progress and the fuel left, drawn on between `hinfo` answers (I26), for this unit.
var _craft := SmoothBar.new(true, 2500)
var _fuel := SmoothBar.new(false, 2500)
var _bars_unit := 0
var _bars_at := -1
var _craft_bar: ProgressBar = null
var _fuel_bar: ProgressBar = null
var _frame_msec := 0


func _ready() -> void:
	theme_type_variation = "FTooltip"
	add_theme_stylebox_override("panel", Kit.style_with_margins("tooltip", 4, 4, 4, 6))
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	custom_minimum_size.x = Kit.px(WIDTH)
	visible = false
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", Kit.px(4))
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(box)
	# the picture: Factorio films the entity; the client shows its icon on the same dark strip
	var picture := Kit.panel("FDeepFrame")
	picture.custom_minimum_size.y = Kit.px(PICTURE)
	picture.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.add_child(picture)
	_icon = TextureRect.new()
	_icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_icon.custom_minimum_size = Kit.pxv(64, 64)
	_icon.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	_icon.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_icon.texture_filter = Kit.ICON_FILTER
	picture.add_child(_icon)
	var head := Kit.panel("FTooltipTitle")
	box.add_child(head)
	_title = Kit.label("", "FTooltipTitleLabel")
	_title.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_title.custom_minimum_size.x = Kit.px(WIDTH - 28)
	head.add_child(_title)
	var body := MarginContainer.new()
	for side in ["left", "right"]:
		body.add_theme_constant_override("margin_" + side, Kit.px(6))
	body.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.add_child(body)
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", Kit.px(2))
	column.mouse_filter = Control.MOUSE_FILTER_IGNORE
	body.add_child(column)
	var status := HBoxContainer.new()
	status.add_theme_constant_override("separation", Kit.px(6))
	column.add_child(status)
	_dot = TextureRect.new()
	_dot.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_dot.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_dot.custom_minimum_size = Kit.pxv(14, 14)
	_dot.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	status.add_child(_dot)
	_status = Kit.label("")
	status.add_child(_status)
	_lines.add_theme_constant_override("separation", Kit.px(2))
	_lines.mouse_filter = Control.MOUSE_FILTER_IGNORE
	column.add_child(_lines)


## The hovered entity (a world record) or null.
func show_entity(r) -> void:
	if r == null or player == null:
		visible = false
		_key = ""
		_seen_rec = null
		return
	var world = player.get("world")
	var proto = world.protos.entity(r.proto_id) if world != null else null
	if proto == null:
		visible = false
		return
	var health := _health_of(r)
	var working := int(world.working.get(r.unit, -1)) if r.unit > 0 else -1
	var icon: Array = WorldMirror.alt_icon(r)
	var inner_name: String = proto.name
	if proto.type == "entity-ghost" and r.extra.has("gh") and world.protos.entity(int(r.extra["gh"])) != null:
		inner_name = world.protos.entity(int(r.extra["gh"])).name
	var stats: Dictionary = model.pedia_data("entity", inner_name) if model != null else {}
	var electric: bool = str(stats.get("etype", "")) == "electric" and proto.type != "entity-ghost"
	var effects: Dictionary = _no_info
	var burner: bool = str(stats.get("etype", "")) == "burner" and proto.type != "entity-ghost"
	if model != null and r.unit > 0 and (proto.type in EFFECT_TYPES or electric or burner or proto.type in CONTENT_TYPES):
		model.ask_hover_info(r.unit, r.proto_id, r.fixed)
		if int(model.hover_info.get("u", 0)) == r.unit:
			effects = model.hover_info
	_report_bars(r.unit, effects, working)
	var power := _power_state(r)
	var extra_hash: int = r.extra.hash()
	if _key != "" and is_same(r, _seen_rec) and extra_hash == _seen_extra and health == _seen_health and working == _seen_working \
			and power == _seen_power and is_same(effects, _seen_info) and stats.size() == _seen_stats:
		visible = true
		_draw_bars()
		return
	_seen_rec = r
	_seen_extra = extra_hash
	_seen_health = health
	_seen_working = working
	_seen_power = power
	_seen_info = effects
	_seen_stats = stats.size()
	# Not the bars' values: they move in place every frame (_draw_bars).
	var shown := effects.duplicate()
	for k in ["pr", "ps", "bn", "at"]:
		shown.erase(k)
	var key := "%s|%s|%s|%s|%s|%d|%s|%d|%s|%s" % [str(r.key), JSON.stringify(r.extra), health, working, JSON.stringify(icon), stats.size(),
		JSON.stringify(shown), power, effects.has("pr"), effects.has("bn")]
	visible = true
	if key == _key:
		_draw_bars()
		return
	_key = key
	_craft_bar = null
	_fuel_bar = null
	for c in _lines.get_children():
		_lines.remove_child(c)
		c.queue_free()
	var shown_name: String = proto.name
	if proto.type == "entity-ghost" and r.extra.has("gh"):
		var inner = world.protos.entity(int(r.extra["gh"]))
		if inner != null:
			shown_name = inner.name
		_line("Ghost: robots will build it", Kit.DISABLED_TEXT)
		var item := _item_for(world, shown_name)
		if item != "":
			var have: int = model.count_of(item) if model != null else 0
			_line("Needs: %s (you have %d)" % [Kit.pretty(item), have], Kit.GREEN_TEXT if have > 0 else Kit.RED_TEXT, item)
	_title.text = Kit.entity_name(shown_name)
	_icon.texture = Kit.item_icon(shown_name)
	if r.extra.has("q"):
		_line("Quality: %s" % str(r.extra["q"]).capitalize(), Kit.YELLOW_TEXT)
	# Factorio's status: a coloured dot and the word; short of power says so, as Factorio's does
	_status.get_parent().visible = working >= 0 or power >= 0
	if power >= 0:
		_status.text = POWER_STATUS[power][0]
		_dot.texture = GuiAssets.status_dot(POWER_STATUS[power][1])
	elif working >= 0:
		_status.text = "Working" if working == 1 else "Not working"
		_dot.texture = GuiAssets.status_dot("green" if working == 1 else "yellow")
	if icon.size() >= 2:
		_line(("Recipe: " if icon[0] == "recipe" else "Filter: ") + (Kit.recipe_name(str(icon[1])) if icon[0] == "recipe" else Kit.pretty(str(icon[1]))))
	if effects.get("io") is Dictionary:
		_rates(effects["io"])
	if r.extra.has("a"):
		_line("Remaining: %s" % Kit.count_text(int(r.extra["a"])))
	if r.extra.has("n"):
		var station := RichText.label("Station: " + str(r.extra["n"]), Kit.WHITE)
		station.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_lines.add_child(station)
	if r.extra.has("d"):
		_line("Marked for deconstruction", Kit.RED_TEXT)
	if r.extra.has("up"):
		var target = world.protos.entity(int(r.extra["up"]))
		_line("To be upgraded to %s" % (Kit.entity_name(target.name) if target != null else "?"), Kit.GREEN_TEXT)
	_effect_lines(effects, proto.type == "beacon")
	_bar_lines(effects)
	var health_shown := false
	for line in Info.entity_lines(stats):
		if str(line[0]).begins_with("Size"):
			continue
		if electric and (str(line[0]).begins_with("Energy consumption") or str(line[0]).begins_with("Drain")):
			continue  # under "Consumes electricity" below, as Factorio has them
		if str(line[0]).begins_with("Health") and health >= 0.0 and stats.has("hp"):
			# the current health over the most, as Factorio's panel has it
			_line("Health: %d/%d" % [roundi(health * float(stats["hp"])), roundi(float(stats["hp"]))])
			health_shown = true
			continue
		_line(str(line[0]), line[2] if line.size() > 2 else Kit.WHITE)
	if not health_shown and health >= 0.0 and health < 1.0:
		_line("Health: %d%%" % roundi(health * 100.0))
	if electric:
		_electricity(stats, effects.get("el", {}))
	_contents(effects.get("inv", []))
	_draw_bars()
	reset_size()


## A `hinfo` answer's progress and fuel, once per answer, to the bars that run on between them.
func _report_bars(unit: int, info: Dictionary, working: int) -> void:
	if unit != _bars_unit:
		_bars_unit = unit
		_bars_at = -1
		_craft = SmoothBar.new(true, 2500)
		_fuel = SmoothBar.new(false, 2500)
	var at := int(info.get("at", -1))
	if at < 0 or at == _bars_at:
		return
	_bars_at = at
	var running := working != 0  # -1: the mod hasn't said; it runs until told otherwise
	if info.has("pr"):
		_craft.report(int(info["pr"]) / 1000.0, int(info["ps"]) / 1000.0 if info.has("ps") else -1.0, running)
	if info.has("bn"):
		_fuel.report(int(info["bn"]) / 1000.0, -1.0, running)


## The bars moved on to now (show_entity runs every frame).
func _draw_bars() -> void:
	var now := Time.get_ticks_msec()
	var delta := clampf((now - _frame_msec) / 1000.0, 0.0, 0.25)
	_frame_msec = now
	var v := _craft.advance(delta)
	if is_instance_valid(_craft_bar) and v >= 0.0:
		ProductionPanels.set_percent(_craft_bar, v)
	var f := _fuel.advance(delta)
	if is_instance_valid(_fuel_bar) and f >= 0.0:
		_fuel_bar.value = f * 1000.0


## The craft's progress (green, with its %) and the fuel left in the burning item (red), as the
## machine's screen draws them.
func _bar_lines(info: Dictionary) -> void:
	if info.has("pr"):
		_craft_bar = ProductionPanels.text_bar(ProductionPanels.PRODUCTION_GREEN, int(info["pr"]) / 1000.0, "0%", 20)
		_craft_bar.name = "Progress"
		_lines.add_child(_labelled("Progress:", _craft_bar))
	if info.has("bn"):
		_fuel_bar = ProductionPanels.thin_bar(ProductionPanels.BURNING_RED, int(info["bn"]) / 1000.0)
		_fuel_bar.name = "Fuel"
		_lines.add_child(_labelled("Fuel left:", _fuel_bar))


func _labelled(text: String, bar: Control) -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", Kit.px(6))
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var label := Kit.label(text)
	label.add_theme_font_override("font", Kit.font("bold"))
	row.add_child(label)
	bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(bar)
	return row


## A crafting machine's ingredients and products a second (J15, `hinfo` io: running flat out at its
## crafting speed with its modules and beacons, products with its productivity), under Factorio's
## headings: each the item's icon, its name and the rate on the right.
func _rates(io: Dictionary) -> void:
	for part in [["i", "Ingredients"], ["o", "Products"]]:
		var rows: Array = io.get(part[0]) if io.get(part[0]) is Array else []
		if rows.is_empty():
			continue
		var head := Kit.label("%s:" % part[1])
		head.add_theme_font_override("font", Kit.font("bold"))
		_lines.add_child(head)
		for rec in rows:
			if not (rec is Array and rec.size() >= 3):
				continue
			var row := HBoxContainer.new()
			row.add_theme_constant_override("separation", Kit.px(4))
			row.mouse_filter = Control.MOUSE_FILTER_IGNORE
			var t := TextureRect.new()
			t.texture = Kit.item_icon(str(rec[1]))
			t.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
			t.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
			t.custom_minimum_size = Kit.pxv(20, 20)
			t.texture_filter = Kit.ICON_FILTER
			row.add_child(t)
			var label := Kit.label(Kit.pretty(str(rec[1])))
			label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			label.clip_text = true
			row.add_child(label)
			row.add_child(Kit.label(rate_text(int(rec[2]))))
			_lines.add_child(row)


## A rate in thousandths a second as Factorio's tooltips write it: 2/s, 1.5/s, 0.75/s (two decimals
## at most; a rate too small for them isn't shown as 0).
static func rate_text(thousandths: int) -> String:
	if thousandths % 1000 == 0:
		return "%d/s" % (thousandths / 1000)
	if thousandths > 0 and thousandths < 10:
		return "<0.01/s"
	var text := "%.2f" % (thousandths / 1000.0)
	return text.rstrip("0").rstrip(".") + "/s"


## What is inside (I2): each inventory under its heading as a grid of Factorio's slots, the item's
## icon and its count, as the entity info lists them.
func _contents(inv: Array) -> void:
	for rec in inv:
		if not (rec is Array and rec.size() >= 2 and rec[1] is Array and not (rec[1] as Array).is_empty()):
			continue
		var role := str(rec[0])
		var head := Kit.label("%s:" % str(ROLE_NAMES.get(role, role.capitalize())))
		head.add_theme_font_override("font", Kit.font("bold"))
		_lines.add_child(head)
		var grid := Kit.slot_grid(CONTENT_COLUMNS)
		grid.mouse_filter = Control.MOUSE_FILTER_IGNORE
		for it in rec[1]:
			if not (it is Array and it.size() >= 2):
				continue
			var s := Slot.new()
			s.custom_minimum_size = Kit.pxv(CONTENT_SLOT, CONTENT_SLOT)
			s.icon_px = CONTENT_SLOT - 8
			s.mouse_filter = Control.MOUSE_FILTER_IGNORE
			s.set_stack(str(it[0]), int(it[1]))
			if it.size() >= 3 and str(it[2]) != "normal":
				s.set_extra({"quality": str(it[2])})
			grid.add_child(s)
		_lines.add_child(grid)


## Factorio's "Consumes electricity" part at the foot of the panel (H20): a rule across, the
## lightning and the yellow heading over a fainter rule, Max. and Min. consumption (the mod's live
## figures with modules and beacons, else the prototype's), and the Electricity bar: the machine's
## buffer, full when it has all the power it wants.
func _electricity(stats: Dictionary, el: Dictionary) -> void:
	var most := float(el.get("mx", stats.get("energy", 0.0)))
	var least := float(el.get("mn", stats.get("drain", 0.0)))
	if most <= 0.0 and el.is_empty():
		return
	_lines.add_child(_rule(Color(0.03, 0.02, 0.02), Color(0.45, 0.4, 0.33), Kit.px(3)))
	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", Kit.px(6))
	head.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var bolt := TextureRect.new()
	bolt.texture = _bolt_icon()
	bolt.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	bolt.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	bolt.custom_minimum_size = Kit.pxv(16, 16)
	bolt.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	bolt.texture_filter = Kit.ICON_FILTER
	head.add_child(bolt)
	var title := Kit.label("Consumes electricity", "FHeading")
	title.add_theme_color_override("font_color", HEADING)
	head.add_child(title)
	_lines.add_child(head)
	_lines.add_child(_rule(Color(0.23, 0.22, 0.2), Color(0, 0, 0, 0), 1))
	_line("Max. consumption: %s" % power_text(most))
	if least > 0.0:
		_line("Min. consumption: %s" % power_text(least))
	if el.has("b") and float(el["b"]) > 0.0:
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", Kit.px(6))
		row.mouse_filter = Control.MOUSE_FILTER_IGNORE
		var label := Kit.label("Electricity:")
		label.add_theme_font_override("font", Kit.font("bold"))
		row.add_child(label)
		var bar := Kit.progress_bar(BAR)
		bar.max_value = 1000
		bar.value = roundi(clampf(float(el["e"]) / float(el["b"]), 0.0, 1.0) * 1000.0)
		bar.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		bar.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		bar.name = "Electricity"
		row.add_child(bar)
		_lines.add_child(row)


## A horizontal rule: `top` over `bottom` (Factorio's dark-then-light line), `height` pixels.
static func _rule(top: Color, bottom: Color, height: int) -> Control:
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 0)
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	for c in [top, bottom]:
		if c.a <= 0.0:
			continue
		var line := ColorRect.new()
		line.color = c
		line.custom_minimum_size.y = maxi(1, height - 1) if c == top else 1
		line.mouse_filter = Control.MOUSE_FILTER_IGNORE
		box.add_child(line)
	return box


## Watts as Factorio's entity info writes them: 217 kW, 77.5 kW, 7.0 kW, 1.2 MW.
static func power_text(w: float) -> String:
	var prefixes := [[1e9, "G"], [1e6, "M"], [1e3, "k"], [1.0, ""]]
	for p in prefixes:
		if absf(w) >= float(p[0]) or str(p[1]) == "":
			var v := w / float(p[0])
			return ("%d" % roundi(v) if absf(v) >= 100.0 else "%.1f" % v) + " %sW" % p[1]
	return "0 W"


## Factorio's tooltip lightning (the left picture of its sheet, which holds smaller ones beside it).
static func _bolt_icon() -> Texture2D:
	var sheet := GuiAssets.core_sprite("icons/tooltips/tooltip-category-electricity.png")
	if sheet == null:
		return null
	var atlas := AtlasTexture.new()
	atlas.atlas = sheet
	atlas.region = Rect2(0, 0, sheet.get_height() * 0.8, sheet.get_height())
	return atlas


## The hovered machine's power from fluids_power.gd (`pw`): -1 powered (or not electric), 0 no
## power, 1 low power, 2 not connected to any pole.
func _power_state(r) -> int:
	if r.unit == 0 or player == null or player.get_parent() == null:
		return -1
	var power = player.get_parent().get_node_or_null("FluidsPower")
	return int(power.power_state(r.unit)) if power != null and power.has_method("power_state") else -1


## What Factorio's entity info adds for modules and beacons: the modules in it, a beacon's
## distribution effectivity and the machines it reaches, a machine's beacons, then the effects (a
## machine's total; a beacon's its modules' sum, which 2.1.23 reports before the distribution
## effectivity), green where they help, red where they cost.
func _effect_lines(info: Dictionary, beacon: bool) -> void:
	if info.is_empty():
		return
	var mods: Array = info.get("m", [])
	if not mods.is_empty():
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", Kit.px(4))
		row.mouse_filter = Control.MOUSE_FILTER_IGNORE
		var head := Kit.label("Modules:")
		head.add_theme_font_override("font", Kit.font("bold"))
		row.add_child(head)
		for m in mods:
			var t := TextureRect.new()
			t.texture = Kit.item_icon(str(m[0]))
			t.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
			t.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
			t.custom_minimum_size = Kit.pxv(20, 20)
			t.texture_filter = Kit.ICON_FILTER
			t.tooltip_text = Kit.pretty(str(m[0]))
			row.add_child(t)
			row.add_child(Kit.label("x%d" % int(m[1])))
		_lines.add_child(row)
	if beacon:
		if info.has("de"):
			_line("Distribution effectivity: %s" % effect_text(int(info["de"])).trim_prefix("+"))
		if info.has("n"):
			_line("Machines affected: %d" % int(info["n"]))
	elif info.has("b"):
		_line("Beacons: %d" % int(info["b"]))
	var eff: Dictionary = info.get("eff", {})
	if eff.is_empty():
		return
	_line("Module effects:" if beacon else "Effects:")
	for e in EFFECT_NAMES:
		if eff.has(e[0]):
			_line("%s: %s" % [e[1], effect_text(int(eff[e[0]]))], Kit.GREEN_TEXT if effect_helps(e[0], int(eff[e[0]])) else Kit.RED_TEXT)


## An effect in thousandths as Factorio writes it: +150%, -15%, +2.5%.
static func effect_text(thousandths: int) -> String:
	var number := ("%d" % (thousandths / 10)) if thousandths % 10 == 0 else ("%.1f" % (thousandths / 10.0))
	return ("+" if thousandths > 0 else "") + number + "%"


## Speed, productivity and quality help when they go up; consumption and pollution when they go down.
static func effect_helps(kind: String, thousandths: int) -> bool:
	return thousandths > 0 if kind in ["sp", "pr", "q"] else thousandths < 0


func _line(text: String, color := Kit.WHITE, item := "") -> void:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 0)
	for part in Kit.key_value_labels(text, color):
		row.add_child(part)
	if item == "":
		_lines.add_child(row)
		return
	var l := row
	row = HBoxContainer.new()
	row.add_theme_constant_override("separation", Kit.px(4))
	var t := TextureRect.new()
	t.texture = Kit.item_icon(item)
	t.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	t.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	t.custom_minimum_size = Kit.pxv(20, 20)
	t.texture_filter = Kit.ICON_FILTER
	row.add_child(t)
	row.add_child(l)
	_lines.add_child(row)


## The item that builds an entity: the one of the same name, or the one whose place result it is
## (the rail planner builds rails).
static func _item_for(world, entity: String) -> String:
	if world.protos.item_names.values().has(entity):
		return entity
	for item in world.protos.item_places:
		if str(world.protos.item_places[item]) == entity:
			return str(item)
	return ""


## 0..1 from the combat layer's health bars (entities below full health), 1 otherwise, -1 for
## entities without health (ore).
func _health_of(r) -> float:
	if r.unit == 0:
		return -1.0
	var combat = player.get("combat")
	var hp = combat.get("_health") if combat != null else null
	if hp is Dictionary and (hp as Dictionary).has(r.unit):
		return float(hp[r.unit])
	return 1.0
