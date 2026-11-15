extends RefCounted
## Look-only turns of buildings Factorio can't rotate (I9, owner's request): R over a furnace, lab,
## chest, radar or the like turns its model a quarter in Zenith alone. Nothing goes to the game. A
## turn is kept per save (the bridge's welcome `sid`, Bridge.save_id) and building (its unit
## number) in user://visual_turns.cfg, put on the building's record as it arrives (world.gd _add),
## and forgotten when the game says the building is gone (`del`: mined or destroyed), so one built
## again stands as Factorio puts it.
## One turned in the build cursor before it is placed (K21) is put down by the game as it always
## is, unturned: the build waits here (expect()) for the building's `add` at that spot, which takes
## the cursor's turn as its own (claim(), world.gd), so it stands as the preview did.

const ProtoDB := preload("res://scripts/world/protos.gd")

const PATH := "user://visual_turns.cfg"
## How long a build sent turned waits for its building (the bridge builds on its next tick and
## sends the `add` at once; predicted.gd gives up on a build after the same time).
const EXPECT_MSEC := 4000
## Types Factorio never turns on R. Square ones only (eligible()): a turned footprint would no
## longer be where the game has it. Crafting machines turn in Factorio when they have fluid boxes
## or put their results out (eligible()), so only those without are here.
const TYPES := ["furnace", "assembling-machine", "lab", "container", "logistic-container", "infinity-container",
	"radar", "beacon", "roboport", "solar-panel", "accumulator", "rocket-silo", "reactor", "agricultural-tower",
	"cargo-landing-pad", "lightning-attractor", "electric-energy-interface"]

static var _cfg: ConfigFile = null
static var _section := ""
static var _turns := {}  # unit -> quarter turns (1-3), the current save's
static var _expected: Array = []  # builds sent turned: [proto id, position (tiles), direction wanted, msec]


## Whether R over this building turns it here only: a square building of a type Factorio never
## turns (`x`: its `eprops` overlay, whose fluid boxes or result vector make a machine turnable).
static func eligible(proto: ProtoDB.EntityProto, x: Dictionary) -> bool:
	if proto == null or not proto.type in TYPES or proto.tile_size.x != proto.tile_size.y:
		return false
	if proto.type == "furnace" or proto.type == "assembling-machine":
		return not x.has("fb") and not x.has("vp")
	return true


## Quarter turns kept for a building of this save (0 none).
static func quarters(sid: String, unit: int) -> int:
	if unit <= 0:
		return 0
	_use(sid)
	return int(_turns.get(unit, 0))


## Whether this save has any turns kept (world.gd skips the lookup otherwise).
static func any(sid: String) -> bool:
	_use(sid)
	return not _turns.is_empty()


## Turns a building a quarter more (back with `reverse`) and keeps it; the turns it has now.
static func turn(sid: String, unit: int, reverse: bool) -> int:
	if unit <= 0:
		return 0
	_use(sid)
	var q := posmod(int(_turns.get(unit, 0)) + (-1 if reverse else 1), 4)
	_keep(unit, q)
	return q


## A build of `proto_id` sent to the game at `pos` (its footprint's centre, snapped as the bridge
## snaps it) turned `dir` in the cursor (K21): its building takes that turn when its `add` comes.
static func expect(proto_id: int, pos: Vector2, dir: int) -> void:
	var now := Time.get_ticks_msec()
	_drop_stale(now)
	for e: Array in _expected:
		if int(e[0]) == proto_id and (e[1] as Vector2).distance_squared_to(pos) < 0.04:
			e[2] = dir  # built again over itself before the game answered: the newer turn
			e[3] = now
			return
	_expected.append([proto_id, pos, dir, now])


## Whether builds are waiting for their buildings (world.gd skips claim() otherwise).
static func expecting() -> bool:
	return not _expected.is_empty()


## The game's `add` of a new building: if a build sent turned was waiting for it (same prototype,
## same spot), it keeps the cursor's turn over the direction the game gave it (`dir`, north for
## all of these). True when it took one.
static func claim(sid: String, unit: int, proto_id: int, pos: Vector2, dir: int) -> bool:
	if unit <= 0 or _expected.is_empty():
		return false
	_drop_stale(Time.get_ticks_msec())
	for i in _expected.size():
		var e: Array = _expected[i]
		if int(e[0]) != proto_id or (e[1] as Vector2).distance_squared_to(pos) >= 0.04:
			continue
		_expected.remove_at(i)
		var q := posmod(roundi((int(e[2]) - dir) / 4.0), 4)
		if q != 0:
			_use(sid)
			_keep(unit, q)
		return q != 0
	return false


static func _drop_stale(now: int) -> void:
	var i := 0
	while i < _expected.size():
		if now - int(_expected[i][3]) > EXPECT_MSEC:
			_expected.remove_at(i)
		else:
			i += 1


static func _keep(unit: int, q: int) -> void:
	if q == 0:
		_turns.erase(unit)
		if _cfg.has_section_key(_section, str(unit)):
			_cfg.erase_section_key(_section, str(unit))
	else:
		_turns[unit] = q
		_cfg.set_value(_section, str(unit), q)
	_cfg.save(PATH)


## The building is gone from the game: its turn goes with it.
static func forget(sid: String, unit: int) -> void:
	if unit <= 0:
		return
	_use(sid)
	if not _turns.has(unit):
		return
	_turns.erase(unit)
	if _cfg.has_section_key(_section, str(unit)):
		_cfg.erase_section_key(_section, str(unit))
	_cfg.save(PATH)


static func _use(sid: String) -> void:
	var section := sid if sid != "" else "unnamed"
	if _cfg == null:
		_cfg = ConfigFile.new()
		_cfg.load(PATH)  # none yet: empty
		_section = ""
	if section == _section:
		return
	_section = section
	_turns = {}
	if _cfg.has_section(section):
		for key in _cfg.get_section_keys(section):
			var q := int(_cfg.get_value(section, key, 0))
			if q > 0 and q < 4:
				_turns[int(key)] = q
