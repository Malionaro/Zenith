extends RefCounted
## Each item's own inventory sounds, as Factorio 2.x gives them in the item prototypes
## (`inventory_move_sound`, `pick_sound`: iron plates clink, wood knocks), read from the player's
## install with a light text scan (no Lua is run): the `item_sound("file.ogg", volume)` tables in
## base's and Space Age's prototypes/item_sounds.lua, and which of them each item names. Used for
## Ctrl+click transfers (I3, I4). Without an install, or before the scan is done, every item
## sounds like Factorio's generic core/sound/inventory-move.

const SoundBank := preload("res://scripts/fx/sound_bank.gd")

const GENERIC := "core/sound/inventory-move.ogg"
## The variable each mod's item files keep their sound table in, and that mod's folder.
const TABLES := {"item_sounds": "base", "space_age_item_sounds": "space-age"}
const MODS := ["base", "space-age", "quality", "elevated-rails"]

static var _lock := Mutex.new()
static var _started := false
static var _move := {}  # item -> [path, volume]
static var _pick := {}


## Starts the scan in the background (once).
static func prepare() -> void:
	if _started:
		return
	_started = true
	if SoundBank.data_dir() == "":
		return
	WorkerThreadPool.add_task(_scan, false, "Factorio item sounds")


## [path, volume] of what moving `item` in or out of an inventory sounds like.
static func move_sound(item: String) -> Array:
	return _sound_of(_move, item)


## [path, volume] of what picking `item` up sounds like.
static func pick_sound(item: String) -> Array:
	return _sound_of(_pick, item)


static func _sound_of(table: Dictionary, item: String) -> Array:
	prepare()
	_lock.lock()
	var s: Array = table.get(item, [])
	_lock.unlock()
	return s if not s.is_empty() else [GENERIC, 1.0]


static func _scan() -> void:
	var data := SoundBank.data_dir()
	var defs := {}  # "table.key" -> [path, volume]
	var def_re := RegEx.create_from_string("(\\w+)\\s*=\\s*item_sound\\(\\s*\"([^\"]+)\"\\s*(?:,\\s*([0-9.]+))?")
	for table in TABLES:
		var text := FileAccess.get_file_as_string(data.path_join("%s/prototypes/item_sounds.lua" % TABLES[table]))
		for m in def_re.search_all(text):
			var volume := float(m.get_string(3)) if m.get_string(3) != "" else 1.0
			defs["%s.%s" % [table, m.get_string(1)]] = ["%s/sound/item/%s" % [TABLES[table], m.get_string(2)], volume]
	var files: Array = []
	for mod in MODS:
		_collect(data.path_join("%s/prototypes" % mod), files)
	var name_re := RegEx.create_from_string("\\bname\\s*=\\s*\"([^\"]+)\"")
	var use_re := RegEx.create_from_string("\\b(inventory_move_sound|pick_sound)\\s*=\\s*(\\w+)\\.(\\w+)")
	var move := {}
	var pick := {}
	for path in files:
		var text := FileAccess.get_file_as_string(path)
		if not text.contains("inventory_move_sound") and not text.contains("pick_sound"):
			continue
		var names := name_re.search_all(text)
		var n := 0
		for m in use_re.search_all(text):
			# The item is the nearest `name = "..."` before the sound in its prototype's table.
			while n + 1 < names.size() and names[n + 1].get_start() < m.get_start():
				n += 1
			if names.is_empty() or names[n].get_start() > m.get_start():
				continue
			var def: Array = defs.get("%s.%s" % [m.get_string(2), m.get_string(3)], [])
			if def.is_empty():
				continue
			if m.get_string(1) == "inventory_move_sound":
				move[names[n].get_string(1)] = def
			else:
				pick[names[n].get_string(1)] = def
	_lock.lock()
	_move = move
	_pick = pick
	_lock.unlock()


static func _collect(dir: String, out: Array) -> void:
	var d := DirAccess.open(dir)
	if d == null:
		return
	for f in d.get_files():
		if f.ends_with(".lua"):
			out.append(dir.path_join(f))
	for sub in d.get_directories():
		_collect(dir.path_join(sub), out)
