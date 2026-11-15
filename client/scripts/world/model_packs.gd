extends RefCounted
## Model packs (MODDING.md, docs/MODELLERS.md): folders or zips of 3D models made for a Factorio
## mod (or to replace Zenith's own), loaded beside the built-in models without a fork. A pack is a
## folder with a pack.json, or a .zip of one (pack.json at the zip's root or one folder down, as
## Factorio's mod zips), unpacked by Zenith into user://model-packs-cache/ when it starts (again
## only when the zip changes). Looked for in these places, in this order:
##   --model-packs=<folder>[,<folder>...]   a pack's own folder, or a folder of packs (always on)
##   user://model-packs                     Zenith's user data (Windows: %APPDATA%\Godot\app_userdata\Zenith\model-packs)
##   <Zenith's folder>/model-packs          beside Zenith.exe in a download (in a checkout: the repo's root)
##
## pack.json:
##   {"id": "my-mod-models", "name": "My mod's models", "version": "1.0.0", "author": "...",
##    "description": "...", "mod": "my-mod", "mod_version": ">=1.2.0", "replace": false,
##    "models": "models"}
## - id: lower case letters, digits, - and _ (required); version (required).
## - models: the folder in the pack holding the .glb / .gltf files, named after the prototypes as
##   any model (docs/MODELLERS.md); the pack's own folder when left out.
## - replace: false (the default) fills in entities that have no model; true replaces Zenith's own
##   models of the same names (a pack of better base-game models).
## - mod, mod_version: the Factorio mod the pack is for, and which of its versions ("1.2.3",
##   ">=1.2.0", "<2"...). A game that doesn't run that mod, or another version, is said in the log
##   when the game starts (check_mods); the pack's models are used either way, since they are found
##   by prototype name and a mod's prototypes only appear when it runs.
##
## Of two packs with one id, the one given on the command line is kept, else the newer version.
## Of two packs with a model of the same name, the one found first wins. Whether each pack is on is
## kept in the settings file's [model_packs] section (id -> bool); on until switched off.

const AddonLoader := preload("res://scripts/addons/addon_loader.gd")
const Paths := preload("res://scripts/menu/paths.gd")
const Settings := preload("res://scripts/menu/settings.gd")

const MANIFEST := "pack.json"
const MODEL_EXTENSIONS := ["glb", "gltf"]

## Extra folders to look in instead of the usual places (tests).
static var test_folders: Array = []
## Where zipped packs are unpacked (tests point it elsewhere).
static var cache_root := "user://model-packs-cache"


## [[folder, source], ...] in the order they are searched. Source: "command line", "user", "Zenith".
static func folders() -> Array:
	if not test_folders.is_empty():
		return test_folders.map(func(f: String) -> Array: return [f, "test"])
	var out: Array = []
	var given := Settings.arg_value("--model-packs=")
	if given != "":
		for f in given.split(",", false):
			out.append([f.strip_edges().replace("\\", "/"), "command line"])
	out.append([ProjectSettings.globalize_path("user://model-packs"), "user"])
	out.append([Paths.repo_dir().path_join("model-packs"), "Zenith"])
	return out


## Every pack found, as manifests (read() / read_zip()), in search order, one per id.
static func scan(where: Array = []) -> Array:
	if where.is_empty():
		where = folders()
	var out: Array = []
	var seen := {}  # id -> index in out
	for pair in where:
		var dir := str(pair[0])
		var source := str(pair[1])
		var candidates: Array = []
		if dir.to_lower().ends_with(".zip") and FileAccess.file_exists(dir):
			candidates.append(dir)
		elif FileAccess.file_exists(dir.path_join(MANIFEST)):
			candidates.append(dir)
		elif DirAccess.dir_exists_absolute(dir):
			var subs := DirAccess.get_directories_at(dir)
			subs.sort()
			for sub in subs:
				if FileAccess.file_exists(dir.path_join(sub).path_join(MANIFEST)):
					candidates.append(dir.path_join(sub))
			var files := DirAccess.get_files_at(dir)
			files.sort()
			for f in files:
				if f.to_lower().ends_with(".zip"):
					candidates.append(dir.path_join(f))
		for c in candidates:
			var m := read_zip(c, source) if str(c).to_lower().ends_with(".zip") else read(c, source)
			var id := str(m["id"])
			if not seen.has(id):
				seen[id] = out.size()
				out.append(m)
				continue
			var kept: Dictionary = out[seen[id]]
			if str(kept["source"]) != "command line" and bool(m["ok"]) and (not bool(kept["ok"])
					or AddonLoader.compare_versions(str(m["version"]), str(kept["version"])) > 0):
				out[seen[id]] = m
	return out


## A pack folder's manifest: {id, name, version, author, description, mod, mod_version, replace,
## models (the subfolder), dir, source, ok, problem}.
static func read(dir: String, source := "") -> Dictionary:
	var m := _blank(dir.get_file(), dir, source)
	_fill(m, FileAccess.get_file_as_string(dir.path_join(MANIFEST)))
	if m["problem"] == "" and not DirAccess.dir_exists_absolute(models_dir(m)):
		m["problem"] = "its models folder \"%s\" is missing" % str(m["models"])
	m["ok"] = m["problem"] == ""
	return m


## A zipped pack's manifest, read from inside the zip: as read(), plus "zip" and "inner" (the folder
## in the zip holding pack.json); "dir" is where it is unpacked (prepare()).
static func read_zip(zip_path: String, source := "") -> Dictionary:
	var base := zip_path.get_file().get_basename()
	var m := _blank(base, cache_root.path_join(base), source)
	m["zip"] = zip_path
	m["inner"] = ""
	var zip := ZIPReader.new()
	if zip.open(zip_path) != OK:
		m["problem"] = "the zip can't be read (broken or not a zip)"
		return m
	var manifest := ""
	for f in zip.get_files():
		if f == MANIFEST or (f.get_file() == MANIFEST and f.count("/") == 1):
			if manifest == "" or f.length() < manifest.length():
				manifest = f
	if manifest == "":
		zip.close()
		m["problem"] = "the zip has no pack.json at its root or one folder down"
		return m
	m["inner"] = manifest.get_base_dir() + "/" if manifest.contains("/") else ""
	_fill(m, zip.read_file(manifest).get_string_from_utf8())
	zip.close()
	m["ok"] = m["problem"] == ""
	if m["ok"]:
		m["dir"] = cache_root.path_join(str(m["id"]))
	return m


static func _blank(id: String, dir: String, source: String) -> Dictionary:
	return {"id": id, "name": id, "version": "", "author": "", "description": "", "mod": "", "mod_version": "",
		"replace": false, "models": "", "dir": dir, "source": source, "ok": false, "problem": "", "count": 0}


## pack.json's text into a manifest, and "problem" when it can't be used.
static func _fill(m: Dictionary, text: String) -> void:
	var json := JSON.new()  # an instance: a broken file is reported here, not as an engine error
	var parsed = json.data if text != "" and json.parse(text) == OK else null
	if not parsed is Dictionary:
		m["problem"] = "its pack.json isn't valid JSON"
		return
	var j: Dictionary = parsed
	for key in ["id", "name", "version", "author", "description", "mod", "mod_version", "models"]:
		if j.has(key) and j[key] != null:
			m[key] = str(j[key])
	m["replace"] = j.get("replace") == true
	var id := str(m["id"])
	if id == "" or not AddonLoader._valid_id(id):
		m["problem"] = "its id \"%s\" must be lower case letters, digits, - and _" % id
	elif str(m["version"]) == "":
		m["problem"] = "its pack.json has no version"
	elif str(m["models"]).contains(".."):
		m["problem"] = "its models folder must be inside the pack"


## The folder holding the pack's models.
static func models_dir(m: Dictionary) -> String:
	var sub := str(m["models"]).strip_edges().trim_prefix("./").trim_suffix("/")
	return str(m["dir"]) if sub == "" or sub == "." else str(m["dir"]).path_join(sub)


## On unless switched off (settings [model_packs] id = false). Packs given with --model-packs are
## always on.
static func enabled(m: Dictionary) -> bool:
	if str(m.get("source", "")) == "command line":
		return true
	var id := str(m["id"])
	if Settings.has_value("model_packs", id):
		return bool(Settings.get_value("model_packs", id))
	return true


static func set_enabled(id: String, on: bool) -> void:
	Settings.set_value("model_packs", id, on)


## The packs to load: found, usable and on, zips unpacked; each with "path" (its models folder,
## an absolute path) and "count" (its models). A pack that can't be used is said in the log.
static func active(where: Array = []) -> Array:
	var out: Array = []
	for m in scan(where):
		if not bool(m["ok"]):
			push_warning("[model packs] %s is left out: %s" % [str(m.get("zip", m["dir"])), str(m["problem"])])
			continue
		if not enabled(m):
			continue
		if m.has("zip"):
			var why := AddonLoader.unpack(m)
			if why != "":
				push_warning("[model packs] %s is left out: %s" % [str(m["zip"]), why])
				continue
			if not DirAccess.dir_exists_absolute(models_dir(m)):
				push_warning("[model packs] %s is left out: its models folder \"%s\" is missing" % [str(m["zip"]), str(m["models"])])
				continue
		m["path"] = ProjectSettings.globalize_path(models_dir(m)).replace("\\", "/")
		m["count"] = count_models(str(m["path"]))
		out.append(m)
	return out


static func count_models(dir: String) -> int:
	var n := 0
	for f in DirAccess.get_files_at(dir):
		if f.get_extension().to_lower() in MODEL_EXTENSIONS:
			n += 1
	return n


## Lines for the log about packs made for a mod this game doesn't run, or another version of it.
## `mods`: the game's active mods, name -> version (the bridge's welcome).
static func check_mods(packs: Array, mods: Dictionary) -> Array:
	var out: Array = []
	for m in packs:
		var mod := str(m.get("mod", ""))
		if mod == "":
			continue
		if not mods.has(mod):
			out.append("model pack %s is for the mod %s, which this game doesn't run" % [str(m["id"]), mod])
		elif not version_matches(str(mods[mod]), str(m.get("mod_version", ""))):
			out.append("model pack %s is for %s %s; this game runs %s" % [str(m["id"]), mod, str(m["mod_version"]), str(mods[mod])])
	return out


## Whether `version` meets `rule`: "" (any), "1.2.3" (that one), or ">=", ">", "<=", "<", "=" and a
## version.
static func version_matches(version: String, rule: String) -> bool:
	rule = rule.strip_edges()
	if rule == "":
		return true
	for op in [">=", "<=", ">", "<", "="]:
		if rule.begins_with(op):
			var c := AddonLoader.compare_versions(version, rule.substr(op.length()).strip_edges())
			match op:
				">=":
					return c >= 0
				"<=":
					return c <= 0
				">":
					return c > 0
				"<":
					return c < 0
				"=":
					return c == 0
	return AddonLoader.compare_versions(version, rule) == 0
