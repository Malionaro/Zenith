extends Node3D
## Inserter arms near the camera. The mod sends each inserter's hand position and held item a
## few times a second (`ih`, every `p` game ticks, each update stamped with its tick `k`); the
## inserter's base is the static entity with the same unit number.
##
## Two clocks (--inserter-arms-clock=belt|wall, read_flags):
## - belt (the default): arms are drawn at the game tick the belt items are drawn at
##   (belt_items.gd drawn_tick: some way behind the newest update, so there are samples on both sides
##   of the drawn moment), or when no belts are drawn at the arms' own game clock two updates behind
##   (game_clock.gd). Each arm keeps its last seconds of samples by tick, and between the two round
##   the drawn tick the hand is played as Factorio moves it (inserter_swing.gd): straight in angle
##   and reach at the prototype's speeds (eprops `rs`/`es` times its quality, else a table), out to
##   the pickup and drop points (eprops `ip`/`id` turned by the inserter's direction) and back, waiting
##   only there, the item changing hands as it leaves; a belt pickup is solved for where and when the
##   hand met the item. So a fast inserter's whole 12-tick swing shows, reaching both ends, and the
##   hand closes on a belt item the tick the belt loses it. Past the newest sample (the drawn tick
##   caught up) the hand goes on to the end it is bound for and waits.
## - wall: as before. Each arm swings (angle and reach around its base) from where it is drawn to
##   the new hand position over the time until the next update (measured on the wall clock from the
##   update's arrival), so the hand follows an arc rather than cutting across, and the drawn arm then
##   follows that path with a little smoothing, so updates arriving early or late don't make it stop
##   and start. About 10 ticks behind the game, and 6-tick samples of a 12-tick swing never reach the
##   ends; kept to compare (tools/inserter_check.py).
##
## The arm is two pieces of Wube's printable inserter (tools/models/wube_recipes.py,
## `inserter-arm-<family>-*`): the upper arm, rising from the shoulder on the base to an elbow,
## and the hand, reaching down from the elbow to the wrist over the belt (two-bone IK, solved per
## frame), open, or closed while it holds an item. Each inserter has its family's pieces (basic,
## long, bulk, stack) in its own colour (ARM_TINTS, picked from its sprites), stretched along
## their length to its reach. Without those models: a placeholder turntable, two boxes and a
## hand with two fingers. Everything is instanced: one MultiMesh per part (and per prototype).
##
## Events (--inserter-events=on|off, on; the hello asks for `ie` with the belt clock): instead of
## samples the mod sends what each hand did as it happened (inserters.lua: picked {tick, count, item,
## where}, dropped {tick, remaining, where}, a status change, a position now and then and once or
## twice mid-swing, gone), each a few times over the next ticks so a lost datagram loses none. From
## the last event at or before the drawn tick the swing follows (inserter_swing.gd plan_events): a
## hand that took goes to the drop at its speeds and waits there until it dropped, one that dropped
## goes back and reaches for the item it takes next where it takes it. So the pickup and drop ticks
## are the game's own (not solved from samples 6 ticks apart), a bulk hand shows its first item at
## the grab, and the sweep's side comes from the mid-swing positions. A hand without power, frozen or
## disabled (the status says) is drawn from its positions as samples. Without events (an older mod,
## the menu's recorded stream, `wall`) the samples alone, as before.
##
## A modeller's inserter rigged as an arm (model_rig.gd: joints Base, Rotation, Lower Arm, Upper Arm,
## Pincer1, Pincer2) replaces Wube's pieces for its prototype: its turntable yaws to the hand, its
## lower and upper arm come from the same two-bone IK with the rig's own joints and lengths, and its
## pincers turn about their joints to close while the hand holds an item. Its own materials, no tint.
##
## --inserter-arms-trace=<file>: a line per frame with each drawn hand (unit, x, y in tiles, held
## item), the game tick the arms stand for, the belts' drawn tick and the frame's arm cost, for
## tools/inserter_check.py against the bridge's /f3d-ih trace.

const ProtoDB := preload("res://scripts/world/protos.gd")
const Visuals := preload("res://scripts/world/visuals.gd")
const ItemCards := preload("res://scripts/world/item_cards.gd")
const Swing := preload("res://scripts/world/inserter_swing.gd")
const GameClock := preload("res://scripts/world/game_clock.gd")
const BeltSimConst := preload("res://scripts/world/belt_sim.gd")
## (rest arms) Plain vertex-coloured boxes on the hills: the loose items' shader (no record: belt_base -1).
const RestShader := preload("res://shaders/item.gdshader")

## An arm missing from this many updates in a row (the inserter left the radius, or was mined) is
## dropped. Every update is the full list, so this counts updates (`k` changes), not ticks.
const MISSING_FRAMES := 2
## (belt clock) Samples older than this many ticks before the newest are forgotten: the drawn tick
## is at most --belt-draw-margin (120) plus a gap behind.
const RING_TICKS := 300
## The placeholder base is Visuals.HEIGHTS["inserter"] tall; the arm stands on it.
const SHOULDER_HEIGHT := 0.5
const HAND_HEIGHT := 0.36  # wrist height: the hand's fingers reach down to the items
const UPPER_ARM := 0.62
const FOREARM := 0.62
const ARM_THICKNESS := 0.065
const TURNTABLE := Vector3(0.3, 0.08, 0.3)
const SHOULDER := Vector3(0.14, 0.14, 0.16)
const HAND_SIZE := Vector3(0.14, 0.05, 0.2)
const FINGER_SIZE := Vector3(0.025, 0.12, 0.05)
const ITEM_DROP := 0.14  # how far below the wrist the held item hangs
## (wall clock) Smoothing of the drawn arm towards the interpolated path, per second.
const FOLLOW_RATE := 30.0
const STEEL := Color(0.52, 0.52, 0.5)
const ModelLibrary := preload("res://scripts/world/model_library.gd")
const ModelRig := preload("res://scripts/world/model_rig.gd")
## A rig's grip (between its pincers) goes where the held item is drawn.
const GRIP_HEIGHT := HAND_HEIGHT - ITEM_DROP
## (--inserter-grip) The grip rides this far above where belt items are drawn when that is higher (a modeller's
## belts are taller: Vasillo's tops are at 0.25, Zenith's 0.2), so the hand closes on a belt item where it is.
const GRIP_ABOVE_BELT := 0.03
## How far a rig's arm may straighten before it is stretched to reach (a modeller's arm shorter than
## the inserter's reach); stretched, the arm is longer than modelled.
const RIG_REACH := 0.98
## Pincers close and open in this much of a second.
const CLOSE_TIME := 0.12
## Inserter prototype -> arm family (inserter-arm-<family>-*.glb); anything else is basic.
const ARM_FAMILIES := {"long-handed-inserter": "long", "bulk-inserter": "bulk", "stack-inserter": "stack"}
## Arm paint per prototype: [upper arm, hand], from its sprites (hand-base.png, hand-open.png)
## as tools/models/part_colors.py turns a sprite's colour into an albedo (the densest colour of
## the paint, divided by the light Factorio painted in from above, exposure and saturation). The
## upper arm is darker than the hand in every tier. The stack inserter's upper arm is worn steel
## round a yellow inset (their mean), its hand's paint the bright yellow of its forearms.
const ARM_TINTS := {
	"burner-inserter": [Color("56514e"), Color("5d453b")], "inserter": [Color("9a5206"), Color("cb7000")],
	"long-handed-inserter": [Color("93221f"), Color("d2431f")], "fast-inserter": [Color("0a6597"), Color("5581bc")],
	"bulk-inserter": [Color("487c01"), Color("628728")], "stack-inserter": [Color("816347"), Color("be8f00")],
}
const ARM_EDGE_WEAR := 0.12
## Per family: upper arm (shoulder to elbow) and hand (elbow to wrist) as modelled, in tiles,
## and how much both are stretched so the hand reaches the inserter's drop position.
const ARM_LENGTHS := {
	"basic": [0.792, 0.604, 1.0], "long": [1.152, 0.964, 1.07],
	"bulk": [0.792, 0.504, 1.05], "stack": [0.792, 0.584, 1.02],
}
## The Wube base's top, where the arm's tab plugs in.
const MODEL_SHOULDER := 0.38
enum ArmPiece { UPPER, OPEN, CLOSED }
const DARK_STEEL := Color(0.3, 0.3, 0.3)
## The belt-like types a pickup point on one makes a belt pickup (inserter_swing.gd belt_pick).
const BELT_TYPES := ["transport-belt", "underground-belt", "linked-belt", "splitter", "lane-splitter", "loader", "loader-1x1"]

## Part meshes in draw order; each is a unit-ish box (or cylinder) scaled per instance.
enum Part { TURNTABLE, SHOULDER, UPPER, FOREARM, HAND, FINGERS }

## --inserter-arms-clock=belt (the default) | wall: see the top.
static var belt_clock := true
## --inserter-events=off (the default) | items | on: `on` asks the mod for `ie` (with the belt clock)
## and draws the swing from the events; `items` asks for both (hello `ie` 2) and draws the swing from
## the samples as before, the held item alone following the events (exact picks and drops; the
## sampled positions follow the game's lifted item mid-swing, which the events can't); `off`: samples.
static var events := false
static var events_items := false
## --inserter-handoff=on (the default) | off: the belt items an inserter takes leave the drawn belt as its
## hand closes on them, and those it puts appear where and when it lets go. The hello asks for `ie` (with
## `items` when --inserter-events is off: the pose from the samples, the held item from the events) and
## for the items' ids (`ho`: inserters.lua's placed records); belt_items.gd hands each pick from a belt
## and each put to its simulation on the event's tick (BeltSim.take_at, put_at: the item nearest the
## hand taken off the lane then, its record hidden from that tick; the put item on its lane then), and
## the arms here steer the hand onto the item's drawn place over the last STEER_IN ticks before the
## grab (and the drop's place before it lets go), easing back over STEER_OUT ticks after.
static var handoff := true
## --inserter-grip=on (the default) | off: the item a hand carries is drawn in its grip: its middle between a
## rig's pincers (half way along them), which close onto its sides (ModelRig.HELD_HALF) instead of meeting
## through it, or between the fingers of Wube's claw, whose middle the arm now reaches the hand's place with
## (the wrist reached it, the claw ending 0.15-0.3 tiles past); a model turned with the hand; the grip no lower
## than the belt items drawn (GRIP_ABOVE_BELT). Off, as before: the item's base at the grip (a rig) or ITEM_DROP
## below the wrist, the pincers closed till they met, so a rig's closed pincers hid the item (owner, K8).
static var held_grip := true
## --inserter-rest-arms=on (the default) | off: an inserter the bridge sends no hand for draws its arm at rest,
## the hand empty at its pickup (Factorio's idle hand waits there). The bridge sends hands only within its
## detail radius of the focus (`f3d-detail-radius`, 24 tiles by default) and no model carries an arm, so past
## that every inserter stood without one (owner, K12). Cheap: three plain boxes in the arm's paint (ARM_TINTS),
## riding the hills (item.gdshader), every resting arm in one MultiMesh without shadows; worked out per chunk
## when its entities change (for at most REST_USEC of a frame) or one of its inserters' live arms comes or goes
## (at once), put together at most every REST_REFRESH seconds (at once for a live arm), never per frame. Off:
## as before.
static var rest_arms := true
const REST_USEC := 300
const REST_REFRESH := 0.25
const REST_UPPER := 0.07  # the boxes' thickness: upper arm, forearm
const REST_FORE := 0.055
const REST_HAND := Vector3(0.12, 0.05, 0.16)
## (rest arms) Wube's claw's middle along the hand before its model is read (the basic hand's: 1.24).
const CLAW_DEFAULT := 1.24
## The `ie` kinds (inserter_swing.gd Ev) belt_items.gd reads, and placed (the hello's `ho`: an item an
## inserter put on a belt, [6, unit, tick, lane, line position, uid, item, stack, belt]), for belt_items.gd.
const EV_PICKED := 1
const EV_GONE := 5
const EV_PLACED := 6
## (handoff) Ticks before a grab or drop the hand is steered onto the item's drawn place, and after it
## eased back to its own swing.
const STEER_IN := 4.0
const STEER_OUT := 3.0
## An arm nothing was heard of (an event or a sample) for this many ticks is dropped: the mod
## sends every hand's position at least every 300.
const STALE_TICKS := 1200
## How many plans between samples are made ahead each frame (spreading the ~35 an update's tick
## would otherwise cost in one frame): at least this many, else a quarter of what waits.
const PREPLAN_MIN := 4
## (events) An arm keeps at least this many cycles of events, however old (the mod probes the
## sweep's side once in 8 legs: 4 cycles).
const KEEP_CYCLES := 6


class Arm:
	var base := Vector2.ZERO  # tiles
	var proto_name := ""
	var color := Color.WHITE
	var item_id := 0  # what the hand is drawn holding
	var angle := 0.0  # where it is drawn
	var reach := 0.0
	var placed := Transform3D.IDENTITY  # the base model's transform (ModelLibrary.placed)
	var close := 0.0  # a rig's pincers: 0 open, 1 closed on an item
	# (wall clock) The update interpolation: from the pose the path had when the update came to the
	# new sample, and where the path is now.
	var from_angle := 0.0
	var to_angle := 0.0
	var from_reach := 0.0
	var to_reach := 0.0
	var path_angle := 0.0
	var path_reach := 0.0
	# (belt clock) Samples by game tick, oldest first (the last RING_TICKS), and the swing model's
	# knowledge of this inserter: its end poses [angle, reach] ([] unknown), speeds, the sweep's side
	# (NAN unknown), whether it takes from a belt, the last item it held; the plan between the two
	# samples round the drawn tick, by its first sample's tick.
	var ticks := PackedFloat64Array()
	var angles := PackedFloat32Array()
	var reaches := PackedFloat32Array()
	var items := PackedInt32Array()
	# Per sample: the angle of the nearest sample at or before it holding something clear of the
	# ends, and of any sample clear of the ends (NAN none): the sweep's side for a plan from it.
	var side_out := PackedFloat32Array()
	var side_any := PackedFloat32Array()
	var pick: Array = []
	var drop: Array = []
	var ends_tried := false
	var belt_pick := false
	var omega := 0.014
	var v := 0.035
	var side := NAN
	var last_item := 0
	var plan_ka := -1.0
	var plan: Array = []
	var plan_still_until := -1.0  # the plan's end when it stands still (most arms, most of the time)
	var plans := {}  # plans made ahead (preplan), by their first sample's tick
	var bound := false  # its record (base, prototype) known
	var last_heard := -1.0  # the newest event's or sample's tick
	# (events) By tick, oldest first: kind (Swing.Ev), count, item, c (PICKED/DROPPED: how many
	# ticks before it may have happened; STATUS/SYNC: the status code), the hand's position (tiles,
	# absolute; NAN unknown), the belt (unit) the item came from or went to (0: none), and the
	# status code as of the event. The plan from the event at or before the drawn tick (eplan), for
	# event index eplan_i; eplan_open: made without a next event (on past it).
	var ev_ticks := PackedFloat64Array()
	var ev_kind := PackedInt32Array()
	var ev_count := PackedInt32Array()
	var ev_item := PackedInt32Array()
	var ev_c := PackedInt32Array()
	var ev_x := PackedFloat32Array()
	var ev_y := PackedFloat32Array()
	var ev_belt := PackedInt32Array()
	var ev_code := PackedInt32Array()
	var ev_start := PackedByteArray()  # 1: a pick with the hand empty before it (a cycle's start)
	var cycles := 0  # cycle starts kept
	var eplan: Array = []
	var eplan_i := -1
	var eplan_open := false
	var eplan_still_until := -1.0
	## (handoff) Where the hand meets a belt item: [tick, uid (0: none), x, z (tiles, where the item is
	## then), taken (true) or put], oldest first.
	var meets: Array = []

	## An event, kept by tick (the mod sends each a few times: the same tick, kind and count is one).
	func add_event(k: float, kind: int, count: int, item: int, c: int, x: float, y: float, belt: int) -> bool:
		var n := ev_ticks.size()
		var i := n
		while i > 0 and ev_ticks[i - 1] >= k:
			if ev_ticks[i - 1] == k and ev_kind[i - 1] == kind and ev_count[i - 1] == count:
				return false
			i -= 1
		var code := ev_code[i - 1] if i > 0 else 0
		if kind == Swing.Ev.STATUS or kind == Swing.Ev.SYNC:
			code = c
		ev_ticks.insert(i, k)
		ev_kind.insert(i, kind)
		ev_count.insert(i, count)
		ev_item.insert(i, item)
		ev_c.insert(i, c)
		ev_x.insert(i, x)
		ev_y.insert(i, y)
		ev_belt.insert(i, belt)
		ev_code.insert(i, code)
		var starts := 1 if kind == Swing.Ev.PICKED and (i == 0 or ev_count[i - 1] == 0) else 0
		ev_start.insert(i, starts)
		cycles += starts
		if i < n:
			# (Out of order: the codes after it follow from it when they were inherited.)
			for j in range(i + 1, n + 1):
				if ev_kind[j] != Swing.Ev.STATUS and ev_kind[j] != Swing.Ev.SYNC:
					ev_code[j] = ev_code[j - 1]
		if eplan_i >= i:
			eplan_i = -1  # (the plan's events moved, or a new one came within it)
		elif eplan_open:
			eplan_i = -1
		if item != 0 and count > 0:
			last_item = item
		last_heard = maxf(last_heard, k)
		# (Old events go, but the last KEEP_CYCLES cycles stay however old: the sweep's side of a cycle
		# follows from a probe within the last few, inserter_arms.gd _event_side.)
		while ev_ticks.size() > 2 and ev_ticks[0] < k - RING_TICKS and cycles > KEEP_CYCLES:
			cycles -= ev_start[0]
			ev_start.remove_at(0)
			ev_ticks.remove_at(0)
			ev_kind.remove_at(0)
			ev_count.remove_at(0)
			ev_item.remove_at(0)
			ev_c.remove_at(0)
			ev_x.remove_at(0)
			ev_y.remove_at(0)
			ev_belt.remove_at(0)
			ev_code.remove_at(0)
			eplan_i -= 1
		return true

	func add_sample(k: float, a: float, r: float, item: int, clear_of_ends: bool) -> void:
		last_heard = maxf(last_heard, k)
		var n := ticks.size()
		if n > 0 and k <= ticks[n - 1]:
			return
		ticks.append(k)
		angles.append(a)
		reaches.append(r)
		items.append(item)
		side_out.append(a if clear_of_ends and item != 0 else (side_out[n - 1] if n > 0 else NAN))
		side_any.append(a if clear_of_ends else (side_any[n - 1] if n > 0 else NAN))
		if item != 0:
			last_item = item
		while ticks.size() > 1 and ticks[0] < k - RING_TICKS:
			plans.erase(ticks[0])
			ticks.remove_at(0)
			angles.remove_at(0)
			reaches.remove_at(0)
			items.remove_at(0)
			side_out.remove_at(0)
			side_any.remove_at(0)


var protos: ProtoDB:
	set(value):
		protos = value
		_cards.protos = value
## The world mirror, for each inserter's position and prototype.
var world: Node3D
## The belt item layer (belt_items.gd), whose drawn tick the arms follow (belt clock); null without.
var belts: Node3D
## The build cursor's prototype properties (ui_model.gd eprops: proto id -> {"x": {"ip", "id", "rs",
## "es", ...}}), for the end poses and speeds; the Dictionary itself, filled as the handshake comes.
var eprops := {}

var _cards := ItemCards.new()
var _arms := {}  # unit -> Arm
var _missing := {}
var _seen := {}
var _frame_tick := -1
var _prev_frame_tick := -1
var _frame_msec := 0
var _frame_length := 0.1
var _period := 6.0  # the updates' `p`, ticks between them
var _clock := GameClock.new()  # (belt clock) the arms' own game clock, for when no belts are drawn
var _drawn := -1.0  # (belt clock) the game tick the arms are drawn at
var _parts: Array[MultiMeshInstance3D] = []
## Prototype name -> [MultiMeshInstance3D per ArmPiece], or null when its models are missing.
var _model_parts := {}
## Prototype name -> its model's arm rig (ModelLibrary.rig_for) with "mmis" (a MultiMeshInstance3D per
## ModelRig.Part, null for a part it lacks), or {} without one.
var _rigs := {}
## Prototypes whose rig had to be stretched to reach (said once).
var _stretched := {}
var _trace: FileAccess
var _frames := 0
var _preplan: Array = []  # arms whose newest pair of samples has no plan yet (planned a few a frame)
var _newest_event := -1.0  # the newest `ie` message's tick
var _swept := -1.0  # (events) when stale arms were last dropped
var _events_heard := false  # an `ie` has come: the events say which arms there are
var steered := 0  # (handoff, probes) hands steered onto a belt item, frames x arms
## (--inserter-arms-trace with --inserter-handoff) Each meeting as it comes: {"meet": [inserter, tick, uid,
## x, z, why]} (tools/inserter_check.py).
var trace_meets := true


static func read_flags(args: PackedStringArray) -> void:
	for a in args:
		if a.begins_with("--inserter-arms-clock="):
			belt_clock = a.substr(22) != "wall"
		elif a.begins_with("--inserter-events="):
			var v := a.substr(18)
			events = v == "on" or v == "items"
			events_items = v == "items"
		elif a.begins_with("--inserter-handoff="):
			handoff = a.substr(19) != "off"
		elif a.begins_with("--inserter-grip="):
			held_grip = a.substr(16) != "off"
		elif a.begins_with("--inserter-rest-arms="):
			rest_arms = a.substr(21) != "off"
	if handoff and not events:
		# (The hand-off needs the events: the pose stays the samples', the held item follows the events.)
		events = true
		events_items = true


static func flags_text() -> String:
	return "arms clock %s, events %s, handoff %s, grip %s, rest arms %s" % ["belt" if belt_clock else "wall", "off" if not wants_events() else ("items" if events_items else "on"),
		"on" if wants_handoff() else "off", "on" if held_grip else "off", "on" if rest_arms else "off"]


## Whether the hello should ask for the items inserters put on belts (`ho`), for the hand-off.
static func wants_handoff() -> bool:
	return handoff and wants_events()


## Whether the hello should ask the mod for `ie` (events) instead of `ih` (samples).
static func wants_events() -> bool:
	return events and belt_clock


## What the hello says: 0 samples, 1 events, 2 both (the item from the events, the pose from samples).
static func hello_ie() -> int:
	if not wants_events():
		return 0
	return 2 if events_items else 1


func _ready() -> void:
	read_flags(OS.get_cmdline_user_args())
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--inserter-arms-trace="):
			_trace = FileAccess.open(a.substr(22), FileAccess.WRITE)
	_cards.name = "HeldItems"
	add_child(_cards)
	for p in Part.size():
		var mesh: Mesh
		if p == Part.TURNTABLE or p == Part.SHOULDER:
			var cyl := CylinderMesh.new()
			cyl.top_radius = 0.5
			cyl.bottom_radius = 0.5
			cyl.height = 1.0
			cyl.radial_segments = 12
			cyl.rings = 1
			mesh = cyl
		else:
			var box := BoxMesh.new()
			box.size = Vector3.ONE
			mesh = box
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.use_colors = true
		mm.mesh = mesh
		var mmi := MultiMeshInstance3D.new()
		mmi.multimesh = mm
		mmi.material_override = Visuals.instance_material()
		add_child(mmi)
		_parts.append(mmi)


func reset() -> void:
	_cards.reset()
	_arms.clear()
	_missing.clear()
	_seen.clear()
	_frame_tick = -1
	_prev_frame_tick = -1
	_clock = GameClock.new()
	_drawn = -1.0
	_preplan.clear()
	_newest_event = -1.0
	_swept = -1.0
	_events_heard = false
	_rest.clear()
	_rest_now.clear()
	_rest_live.clear()
	_rest_put = true
	if world != null:
		for c in world.chunks:
			_rest_dirty[c] = true


func count() -> int:
	return _arms.size()


## The game tick the arms are drawn at (belt clock), -1 before the first update.
func drawn_tick() -> float:
	return _drawn


## One part of an update: {t: "ih", k: tick, p: ticks between updates, part, parts, l: [unit, hand x,
## hand y, item id, ...]}
func handle(msg: Dictionary) -> void:
	var k := int(msg.get("k", 0))
	var p := float(msg.get("p", 0))
	if p > 0.0:
		_period = p
	if k != _frame_tick:
		_end_frame()
		if _frame_tick >= 0 and k > _frame_tick:
			# Averaged, so one late packet doesn't change how fast every arm moves. Up to a second:
			# a slowed-down mod (`rate` 3) sends hands every 12 ticks, or 24 with a long interval.
			var length := clampf((k - _frame_tick) / 60.0, 1.0 / 60.0, 1.0)
			_frame_length = lerpf(_frame_length, length, 0.5)
		_prev_frame_tick = _frame_tick if _frame_tick >= 0 else k
		_frame_tick = k
		_frame_msec = Time.get_ticks_msec()
		_clock.heard(float(k), p)
	var list = msg.get("l")
	if not (list is Array):
		return
	# z = 1: every number is the difference from the hand before it (see belt_items.gd).
	var deltas := int(msg.get("z", 0)) == 1
	var v := [0, 0, 0, 0]
	var i := 0
	while i + 3 < list.size():
		for j in 4:
			v[j] = v[j] + int(list[i + j]) if deltas else int(list[i + j])
		_update(v[0], Vector2(v[1], v[2]) / 256.0, v[3], k)
		i += 4


func _update(unit: int, hand: Vector2, item_id: int, k: int) -> void:
	var rec = world.entities.get(unit) if world != null else null
	if rec == null:
		return  # its chunk isn't loaded
	_seen[unit] = true
	var rel: Vector2 = hand - rec.pos
	var arm: Arm = _arms.get(unit)
	if arm == null:
		arm = Arm.new()
		arm.angle = rel.angle()
		arm.reach = rel.length()
		arm.path_angle = arm.angle
		arm.path_reach = arm.reach
		_arms[unit] = arm
	_bind(arm, rec)
	if belt_clock:
		if _add_sample(arm, float(k), rel, item_id) and arm.ticks.size() >= 2 and not _preplan.has(arm):
			_preplan.append(arm)
		return
	arm.item_id = item_id
	arm.from_angle = arm.path_angle
	arm.from_reach = arm.path_reach
	arm.to_angle = rel.angle()
	arm.to_reach = rel.length()


## The arm's record: its base, prototype (colour, model, family), end poses and speeds. Each update
## (the record can change: rotated, upgraded), or when its record first comes (events).
func _bind(arm: Arm, rec) -> void:
	var proto: ProtoDB.EntityProto = protos.entity(rec.proto_id) if protos != null else null
	arm.color = proto.color if proto != null else Color.GOLDENROD
	arm.proto_name = proto.name if proto != null else ""
	arm.base = rec.pos
	if proto != null:
		arm.placed = ModelLibrary.placed(proto.name, proto.type, rec.dir, rec.extra, Vector3(rec.pos.x, 0.0, rec.pos.y))
	arm.bound = true
	if belt_clock and not arm.ends_tried:
		_learn_ends(arm, rec, proto)


## A sample (the hand `rel` to its base at tick `k`) into the arm's ring; true when it was new.
func _add_sample(arm: Arm, k: float, rel: Vector2, item_id: int) -> bool:
	var n := arm.ticks.size()
	if n > 0 and k <= arm.ticks[n - 1]:
		return false
	var a := rel.angle()
	var clear := Swing.on_side(a, arm.pick, arm.drop)
	arm.add_sample(k, a, rel.length(), item_id, clear)
	if clear:
		arm.side = a
	return true


## One `ie` message: {t: "ie", k: tick, n: the ticks its events cover (each event is sent in every
## message of the next n ticks), p: ticks between messages, l: [kind, unit, tick, a, b, c, hand x,
## hand y (1/256), belt, ...] flat (docs/PROTOCOL.md): picked (a count, b item, c ticks it may be
## late by), dropped (a remaining, b item, c), status (a count, b item, c the code), sync (the
## same, a position read), gone.
func handle_events(msg: Dictionary) -> void:
	var k := float(msg.get("k", 0))
	var list = msg.get("l")
	if not (list is Array):
		return
	_events_heard = true
	if k > _newest_event:
		_newest_event = k
		_clock.heard(k, float(msg.get("p", 2)))
	var deltas := int(msg.get("z", 0)) == 1
	var v := [0, 0, 0, 0, 0, 0, 0, 0, 0]
	var i := 0
	while i + 8 < list.size():
		for j in 9:
			v[j] = v[j] + int(list[i + j]) if deltas else int(list[i + j])
		i += 9
		var unit: int = v[1]
		var kind: int = v[0]
		if kind == EV_PLACED:
			continue  # (for belt_items.gd)
		if kind == Swing.Ev.GONE:
			_arms.erase(unit)
			_missing.erase(unit)
			continue
		var arm: Arm = _arms.get(unit)
		if arm == null:
			arm = Arm.new()
			_arms[unit] = arm
		var rec = world.entities.get(unit) if world != null else null
		if rec != null and not arm.bound:
			_bind(arm, rec)
		var x: float = v[6] / 256.0
		var y: float = v[7] / 256.0
		if not arm.add_event(float(v[2]), kind, v[3], v[4], v[5], x, y, v[8]):
			continue
		if kind == Swing.Ev.SYNC and arm.bound:
			# (Its position: a sample too, the fallback when the status says it doesn't move as its
			# speeds say, and the sweep's side when it was read mid-swing.)
			_add_sample(arm, float(v[2]), Vector2(x, y) - arm.base, v[4] if v[3] > 0 else 0)
		if v[5] == 0 and (kind == Swing.Ev.PICKED or kind == Swing.Ev.DROPPED) and arm.bound:
			_backdate(arm, float(v[2]))
	if _newest_event - _swept >= 60.0:
		_swept = _newest_event
		for unit in _arms.keys():
			var arm: Arm = _arms[unit]
			if arm.last_heard >= 0.0 and arm.last_heard < _newest_event - STALE_TICKS:
				_arms.erase(unit)


## An exact take or drop at tick `k` dates the uncertain one before it (a hand woken from a long
## wait: the mod says how many ticks before its check it may have happened): the leg between them
## takes what the speeds say, so the earlier one was that long before, within what the mod allowed.
func _backdate(arm: Arm, k: float) -> void:
	var i := arm.ev_ticks.bsearch(k, true)
	while i < arm.ev_ticks.size() and arm.ev_ticks[i] == k and arm.ev_kind[i] != Swing.Ev.PICKED and arm.ev_kind[i] != Swing.Ev.DROPPED:
		i += 1
	if i >= arm.ev_ticks.size() or arm.ev_ticks[i] != k:
		return
	var j := i - 1
	while j >= 0 and arm.ev_kind[j] != Swing.Ev.PICKED and arm.ev_kind[j] != Swing.Ev.DROPPED:
		j -= 1
	if j < 0 or arm.ev_c[j] <= 0 or is_nan(arm.ev_x[j]) or is_nan(arm.ev_x[i]):
		return
	var from := Vector2(arm.ev_x[j], arm.ev_y[j]) - arm.base
	var to := Vector2(arm.ev_x[i], arm.ev_y[i]) - arm.base
	var t := Swing.travel_ticks(Swing.delta(from.angle(), to.angle(), arm.side), to.length() - from.length(), arm.omega, arm.v)
	var kj := arm.ev_ticks[j]
	var moved := clampf(k - t, kj - arm.ev_c[j], kj)
	arm.ev_c[j] = 0
	if moved < kj and (j == 0 or arm.ev_ticks[j - 1] < moved):
		arm.ev_ticks[j] = moved
		arm.eplan_i = -1


## The inserter's end poses, speeds and whether it takes from a belt, from its prototype's eprops
## (ip/id turned by its direction: the vectors are for one facing north; rs/es at normal quality)
## and the world round it. Tried again each update until the eprops have come.
func _learn_ends(arm: Arm, rec, proto: ProtoDB.EntityProto) -> void:
	var x: Dictionary = (eprops.get(rec.proto_id, {}) as Dictionary).get("x", {})
	if proto == null or not x.has("ip") or not x.has("id"):
		return
	arm.ends_tried = true
	var pick_rel := _turn(_vec(x["ip"]), rec.dir)
	var drop_rel := _turn(_vec(x["id"]), rec.dir)
	arm.pick = [pick_rel.angle(), pick_rel.length()]
	arm.drop = [drop_rel.angle(), drop_rel.length()]
	var speeds := Swing.speeds(x, proto.name, str(rec.extra.get("q", "normal")))
	arm.omega = speeds[0]
	arm.v = speeds[1]
	arm.belt_pick = _belt_at(rec.pos + pick_rel)


static func _vec(v) -> Vector2:
	return Vector2(float(v[0]), float(v[1])) if v is Array and v.size() >= 2 else Vector2.ZERO


## A north-facing vector turned to a 16-way direction (as cursor_overlay.gd turn).
static func _turn(v: Vector2, dir: int) -> Vector2:
	return v.rotated(float(dir) / 16.0 * TAU)


## Whether a belt (transport belt, underground, splitter, loader) stands at this position.
func _belt_at(pos: Vector2) -> bool:
	if world == null or protos == null:
		return false
	var cv = world.chunks.get(Vector2i(floori(pos.x / 32.0), floori(pos.y / 32.0)))  # (world.gd chunk_of)
	if cv == null:
		return false
	for key in cv.entities:
		var r = cv.entities[key]
		var p: ProtoDB.EntityProto = protos.entity(r.proto_id)
		if p == null or not BELT_TYPES.has(p.type):
			continue
		if r.pos.distance_to(pos) < (1.0 if p.type == "splitter" or p.type == "lane-splitter" else 0.6):
			return true
	return false


func _end_frame() -> void:
	if _frame_tick < 0:
		return
	for unit in _arms.keys():
		if _seen.has(unit) or (_arms[unit] as Arm).ev_ticks.size() > 0:
			_missing.erase(unit)  # (an arm with events goes when the events say: gone, or stale)
		else:
			var n: int = _missing.get(unit, 0) + 1
			if n >= MISSING_FRAMES:
				_arms.erase(unit)
				_missing.erase(unit)
			else:
				_missing[unit] = n
	_seen.clear()


## (belt clock) The arm's pose at game tick `t`: from its events when it has them for that tick (and
## its status then says it moves as its speeds say), else between the two samples round it as the
## swing model says, held before its first sample, played on past its newest.
func _pose_at(arm: Arm, t: float) -> void:
	if not events_items and _pose_events(arm, t):
		return
	var n := arm.ticks.size()
	if n == 0:
		return
	if t < arm.plan_still_until and t >= arm.plan_ka:
		if events_items:
			_item_from_events(arm, t)
		return  # standing: the pose set when the plan was made holds
	var pose: Array
	if t <= arm.ticks[0]:
		pose = [arm.angles[0], arm.reaches[0], arm.items[0]]
	else:
		var i := arm.ticks.bsearch(t, true)  # the first sample at or after t
		var a := i if i < n and arm.ticks[i] == t else i - 1
		if a >= n - 1:
			var still := n >= 2 and Swing.hand_pos(arm.angles[n - 2], arm.reaches[n - 2]).distance_to(
				Swing.hand_pos(arm.angles[n - 1], arm.reaches[n - 1])) < Swing.STILL
			pose = Swing.extrapolate(arm.angles[n - 1], arm.reaches[n - 1], arm.items[n - 1], still, arm.pick, arm.drop,
				arm.omega, arm.v, arm.side, t - arm.ticks[n - 1])
		else:
			if arm.plan_ka != arm.ticks[a] or arm.plan.is_empty():
				arm.plan = arm.plans.get(arm.ticks[a], []) as Array
				if arm.plan.is_empty():
					arm.plan = _plan_pair(arm, a)
				arm.plan_ka = arm.ticks[a]
				var k0: Array = arm.plan[0]
				var kn: Array = arm.plan[arm.plan.size() - 1]
				arm.plan_still_until = kn[0] if arm.plan.size() == 2 and k0[1] == kn[1] and k0[2] == kn[2] and k0[3] == kn[3] else -1.0
			pose = Swing.at(arm.plan, t)
	arm.angle = wrapf(pose[0], -PI, PI)
	arm.reach = pose[1]
	arm.item_id = pose[2]
	if events_items:
		_item_from_events(arm, t)


## (--inserter-events=items) The held item at `t` from the events: what the last event at or before
## `t` says the hand holds, unless the next pick or drop is an uncertain one (the mod saw it `c` ticks
## after its check) that may already have happened by `t`: then the samples' own guess stands.
func _item_from_events(arm: Arm, t: float) -> void:
	var n := arm.ev_ticks.size()
	if n == 0 or t < arm.ev_ticks[0]:
		return
	var i := arm.ev_ticks.bsearch(t, false) - 1
	if arm.ev_kind[i] == Swing.Ev.GONE:
		return
	var j := i + 1
	while j < n and arm.ev_kind[j] != Swing.Ev.PICKED and arm.ev_kind[j] != Swing.Ev.DROPPED:
		j += 1
	if j < n and arm.ev_c[j] > 0 and t >= arm.ev_ticks[j] - arm.ev_c[j]:
		return
	arm.item_id = arm.ev_item[i] if arm.ev_count[i] > 0 else 0


## The plan between samples `a` and `a + 1` (made when the drawn tick reaches them, or ahead by
## preplan: the inputs are all there once both samples are).
func _plan_pair(arm: Arm, a: int) -> Array:
	var side := _side_at(arm, a)
	var plan := Swing.plan(arm.ticks[a], arm.angles[a], arm.reaches[a], arm.items[a],
		arm.ticks[a + 1], arm.angles[a + 1], arm.reaches[a + 1], arm.items[a + 1],
		arm.pick, arm.drop, arm.omega, arm.v, side, arm.belt_pick, arm.last_item)
	if is_nan(side) and is_nan(arm.side) and plan.size() >= 2:
		# Which side the arm sweeps over isn't known until a sample lands on it: the first
		# half-circle turn's own choice stands until then, so the legs agree.
		var first: Array = plan[0]
		var last: Array = plan[plan.size() - 1]
		if absf(last[1] - first[1]) > Swing.AMBIGUOUS:
			arm.side = wrapf((first[1] + last[1]) * 0.5, -PI, PI)
	return plan


## (events) The pose at `t` from the arm's events: true when they say. False before its first event,
## or when its status as of the last event says it doesn't move as its speeds say (low power, no
## power, frozen, disabled): then the samples (every SYNC is one) draw it.
func _pose_events(arm: Arm, t: float) -> bool:
	var n := arm.ev_ticks.size()
	if n == 0 or t < arm.ev_ticks[0] or not arm.bound:
		return false
	var i := arm.ev_ticks.bsearch(t, false) - 1  # the last event at or before t
	if Swing.SLOW.has(arm.ev_code[i]):
		return false
	# The plan runs between anchors: picks and drops, status changes, positions read at an end (a
	# sync mid-way only says which side the hand sweeps over: the game's position then is the item
	# as drawn, lifted, not where the arm is).
	while i > 0 and not _anchor(arm, i):
		i -= 1
	if arm.eplan_i == i and not arm.eplan.is_empty() and not (arm.eplan_open and i < n - 1):
		if t < arm.eplan_still_until:
			return true  # standing
	else:
		var j := i + 1
		while j < n and not _anchor(arm, j):
			j += 1
		var e0 := _event_pose(arm, i)
		var e1: Array = _event_pose(arm, j) if j < n else []
		arm.eplan = Swing.plan_events(e0, e1, arm.pick, arm.drop, arm.omega, arm.v, _event_side(arm, i))
		arm.eplan_i = i
		arm.eplan_open = e1.is_empty()
		var k0: Array = arm.eplan[0]
		var kn: Array = arm.eplan[arm.eplan.size() - 1]
		arm.eplan_still_until = kn[0] if arm.eplan.size() == 2 and k0[1] == kn[1] and k0[2] == kn[2] and k0[3] == kn[3] else -1.0
	var pose := Swing.at(arm.eplan, t)
	arm.angle = wrapf(pose[0], -PI, PI)
	arm.reach = pose[1]
	arm.item_id = pose[2]
	return true


## (events) The side the hand sweeps over in the cycle event `i` belongs to (an angle on it; NAN
## unknown). A cycle runs from a pick with the hand empty before it to the next; out and back go
## over the same side. A cycle's side comes from a position the mod read mid-swing in it (a sync
## marked as a probe, before or after `i`: at an end the game's position is the lifted item, so only
## those count), else from the cycle before or after: a hand taking from a belt sweeps the same side
## again (107 of 110 cycles in the owner's save), one taking from a chest or machine (a half circle
## either way) the other side (184 of 187), so the neighbour's side mirrored about the axis; with
## none known, what the samples taught (Arm.side).
func _event_side(arm: Arm, i: int) -> float:
	var n := arm.ev_ticks.size()
	var cycle_of := PackedInt32Array()
	var anchors := PackedFloat32Array()  # per cycle: a probe's angle, NAN
	var pre := NAN  # a probe before the first pick
	var last_count := 0
	var c := -1
	for j in n:
		var kind := arm.ev_kind[j]
		if kind == Swing.Ev.PICKED and last_count == 0:
			c += 1
			anchors.append(NAN)
		cycle_of.append(c)
		if kind == Swing.Ev.SYNC and arm.ev_belt[j] == 1 and not is_nan(arm.ev_x[j]) and (c < 0 and is_nan(pre) or c >= 0 and is_nan(anchors[c])):
			var a := (Vector2(arm.ev_x[j], arm.ev_y[j]) - arm.base).angle()
			if Swing.on_side(a, arm.pick, arm.drop):
				if c < 0:
					pre = a
				else:
					anchors[c] = a
		if kind != Swing.Ev.GONE:
			last_count = arm.ev_count[j]
	var m := anchors.size()
	if m == 0:
		return pre if not is_nan(pre) else arm.side
	var sides := PackedFloat32Array()
	sides.resize(m)
	var prev := pre
	for k in m:
		var sd := anchors[k]
		if is_nan(sd) and not is_nan(prev):
			sd = _next_side(arm, prev)
		sides[k] = sd
		prev = sd
	var nxt := NAN
	for k in range(m - 1, -1, -1):
		if is_nan(sides[k]) and not is_nan(nxt):
			sides[k] = _next_side(arm, nxt)  # (the mirror is its own inverse)
		nxt = sides[k]
	var ci := cycle_of[i]
	var out: float
	if ci < 0:
		out = pre if not is_nan(pre) else (_next_side(arm, sides[0]) if not is_nan(sides[0]) else NAN)
	else:
		out = sides[ci]
	return out if not is_nan(out) else arm.side


## The side the cycle after (or before) one over side `s` sweeps: the same for a hand taking from a
## belt, the other side (mirrored about the axis) for one taking from a chest or machine.
func _next_side(arm: Arm, s: float) -> float:
	if arm.belt_pick or arm.pick.is_empty():
		return s
	return wrapf(2.0 * arm.pick[0] - s, -PI, PI)


## Whether event `j` is one the plan runs between: a pick or a drop, the first event, one whose
## count differs from the event before's (a change the checks missed), or a position (a sync, a
## status) read at an end. Not one read mid-way (the sweep's side only).
func _anchor(arm: Arm, j: int) -> bool:
	var kind := arm.ev_kind[j]
	if kind == Swing.Ev.PICKED or kind == Swing.Ev.DROPPED:
		return true
	if kind == Swing.Ev.GONE:
		return false
	if j == 0 or arm.ev_count[j] != arm.ev_count[j - 1]:
		return true
	if kind == Swing.Ev.SYNC and arm.ev_belt[j] == 2:
		return true  # (on its way, later than its pick or drop said: the leg starts from here)
	if is_nan(arm.ev_x[j]):
		return false
	# (A status change or a position mid-way is no anchor: the game's position there is the lifted
	# item, and a hand that waits does so at an end.)
	var rel := Vector2(arm.ev_x[j], arm.ev_y[j]) - arm.base
	return Swing.near(rel.angle(), rel.length(), arm.pick, PICK_ZONE) or Swing.near(rel.angle(), rel.length(), arm.drop, DROP_ZONE)


## A pick's position further than this (tiles) from the nominal pickup point, or a drop's further
## than DROP_ZONE from the drop point, is the item as the game draws it, lifted (a fast inserter's
## hand is drawn raised as it arrives): the nominal point stands in. A belt item is taken anywhere
## in its tile, within PICK_ZONE.
const PICK_ZONE := 0.7
const DROP_ZONE := 0.5


## Event `i` as plan_events takes it: [tick, kind, count, item, angle, reach, status code] about the
## base, a pick's or drop's position far from its end replaced by the end (see PICK_ZONE).
func _event_pose(arm: Arm, i: int) -> Array:
	var a := NAN
	var r := 0.0
	if not is_nan(arm.ev_x[i]):
		var rel := Vector2(arm.ev_x[i], arm.ev_y[i]) - arm.base
		a = rel.angle()
		r = rel.length()
		var kind := arm.ev_kind[i]
		if kind == Swing.Ev.PICKED and not arm.pick.is_empty() and not Swing.near(a, r, arm.pick, PICK_ZONE):
			a = arm.pick[0]
			r = arm.pick[1]
		elif kind == Swing.Ev.DROPPED and not arm.drop.is_empty() and not Swing.near(a, r, arm.drop, DROP_ZONE):
			a = arm.drop[0]
			r = arm.drop[1]
	return [arm.ev_ticks[i], arm.ev_kind[i], arm.ev_count[i], arm.ev_item[i], a, r, arm.ev_code[i]]


## Plans made ahead: a few arms a frame of those whose newest pair of samples isn't planned yet.
func _preplan_some() -> void:
	var n := mini(_preplan.size(), maxi(PREPLAN_MIN, _preplan.size() / 4))
	for _i in n:
		var arm: Arm = _preplan.pop_front()
		var m := arm.ticks.size()
		if m < 2 or not arm.ends_tried:
			continue
		var ka := arm.ticks[m - 2]
		if not arm.plans.has(ka):
			arm.plans[ka] = _plan_pair(arm, m - 2)


## The side the arm sweeps over for the plan from sample `a`: the game's hand swings out to the drop
## and back to the pickup over the same side within a cycle, and the next cycle's side is the same or
## the other (seen in the owner's save: both, by inserter), so the nearest sample at or before `a`
## that was holding something clear of the ends says (Arm.side_out); failing one, any sample clear
## of the ends, else what the arm learnt (NAN until a half-circle turn chose).
func _side_at(arm: Arm, a: int) -> float:
	if not is_nan(arm.side_out[a]):
		return arm.side_out[a]
	return arm.side_any[a] if not is_nan(arm.side_any[a]) else arm.side


func _process(delta: float) -> void:
	var usec := Time.get_ticks_usec()
	var t := clampf((Time.get_ticks_msec() - _frame_msec) / (_frame_length * 1000.0), 0.0, 1.0)
	var follow := 1.0 - exp(-delta * FOLLOW_RATE)
	var own := _clock.advance(delta)
	if belt_clock:
		# The belts' drawn tick, when belts are drawn; else the arms' own clock, two updates behind.
		var belt_tick: float = belts.drawn_tick() if belts != null and belts.has_method("drawn_tick") else -1.0
		_drawn = belt_tick if belt_tick >= 0.0 else own
		if not _preplan.is_empty():
			_preplan_some()
		if handoff and belts != null and belts.has_method("take_hands"):
			_take_meets(belts.take_hands())
	var lists := []
	for p in Part.size():
		lists.append([])
	var colors: Array[Color] = []
	var held := {}  # item id -> Array of positions
	var held_yaws := {}  # item id -> Array of turns
	var model_lists := {}  # proto name -> [Array of Transform3D per ArmPiece]
	var rig_lists := {}  # proto name -> [Array of Transform3D per ModelRig.Part]
	var live := {}  # unit -> its chunk: the arms drawn live this frame (rest arms leave them out)
	for unit in _arms:
		if world != null and not world.entities.has(unit):
			continue  # mined since the last update, or its chunk not here yet (events)
		var arm: Arm = _arms[unit]
		if not arm.bound:
			if world == null:
				continue
			_bind(arm, world.entities[unit])
		if belt_clock:
			if _drawn >= 0.0:
				_pose_at(arm, _drawn)
				if not arm.meets.is_empty():
					_steer(arm, _drawn)
		else:
			arm.path_angle = lerp_angle(arm.from_angle, arm.to_angle, t)
			arm.path_reach = lerpf(arm.from_reach, arm.to_reach, t)
			arm.angle = lerp_angle(arm.angle, arm.path_angle, follow)
			arm.reach = lerpf(arm.reach, arm.path_reach, follow)
		var wrist: Vector3
		_gripped = false
		var rig = _rig_for(arm.proto_name)
		if rig == null:
			continue  # its model is still being read: neither base nor arm is drawn yet
		if not (rig as Dictionary).is_empty():
			if not rig_lists.has(arm.proto_name):
				rig_lists[arm.proto_name] = [[], [], [], [], []]
			arm.close = move_toward(arm.close, 1.0 if arm.item_id > 0 else 0.0, delta / CLOSE_TIME)
			wrist = _draw_rig_arm(arm, rig, rig_lists[arm.proto_name])
		elif _pieces_for(arm.proto_name) != null:
			if not model_lists.has(arm.proto_name):
				model_lists[arm.proto_name] = [[], [], []]
			wrist = _draw_model_arm(arm, model_lists[arm.proto_name])
		else:
			wrist = _draw_arm(arm, lists)
			colors.append(arm.color)
		if world != null:
			live[unit] = world.entities[unit].chunk
		if arm.item_id > 0:
			if not held.has(arm.item_id):
				held[arm.item_id] = []
				held_yaws[arm.item_id] = []
			held[arm.item_id].append(held_at(arm, wrist))
			# (--inserter-grip) A model sits square in the grip, turned with the hand; an icon card keeps its
			# slight turn (an icon turned with the hand would stand on its head on the way back).
			held_yaws[arm.item_id].append(-arm.angle if _gripped and _cards.turns(arm.item_id) else ItemCards.turn_for(unit))
	for p in _parts.size():
		var mm := _parts[p].multimesh
		var xforms: Array = lists[p]
		var per_arm := 2 if p == Part.FINGERS else 1
		if mm.instance_count < xforms.size():
			mm.instance_count = maxi(xforms.size(), mm.instance_count * 2)
		mm.visible_instance_count = xforms.size()
		for i in xforms.size():
			mm.set_instance_transform(i, xforms[i])
			mm.set_instance_color(i, _part_color(p, colors[i if per_arm == 1 else i >> 1]))
	for proto_name in _model_parts:
		var pieces = _model_parts[proto_name]
		if pieces == null:
			continue
		var per_piece: Array = model_lists.get(proto_name, [[], [], []])
		for p in ArmPiece.size():
			var mm: MultiMesh = pieces[p].multimesh
			var xforms: Array = per_piece[p]
			if mm.instance_count < xforms.size():
				mm.instance_count = maxi(xforms.size(), mm.instance_count * 2)
			mm.visible_instance_count = xforms.size()
			for i in xforms.size():
				mm.set_instance_transform(i, xforms[i])
	for proto_name in _rigs:
		var mmis: Array = (_rigs[proto_name] as Dictionary).get("mmis", [])
		var per_part: Array = rig_lists.get(proto_name, [[], [], [], [], []])
		for p in mmis.size():
			if mmis[p] == null:
				continue
			var mm: MultiMesh = (mmis[p] as MultiMeshInstance3D).multimesh
			var xforms: Array = per_part[p]
			if mm.instance_count < xforms.size():
				mm.instance_count = maxi(xforms.size(), mm.instance_count * 2)
			mm.visible_instance_count = xforms.size()
			for i in xforms.size():
				mm.set_instance_transform(i, xforms[i])
	_cards.draw(held, held_yaws)
	_update_rest(live, delta)
	_frames += 1
	if _trace != null and not _arms.is_empty():
		_write_trace(Time.get_ticks_usec() - usec, t)


## (rest arms) Every resting arm's box in one MultiMesh (16 floats an instance: the transform's rows, the
## colour); per chunk its arms' instances; the chunks to work out again (entities changed: a few a frame; a live
## arm came or went: at once), the arms drawn live last frame (unit -> chunk), and what was last put together.
## A chunk whose inserter waits for its model is tried again on the next frames.
var _rest_mmi: MultiMeshInstance3D = null
var _rest := {}  # chunk -> PackedFloat32Array
var _rest_dirty := {}  # chunk -> true
var _rest_now := {}  # chunk -> true
var _rest_live := {}  # unit -> chunk
var _rest_put := false
var _rest_wait := 0.0
var _rest_eprops := -1
var _rest_hooked := false
var _is_inserter := {}  # proto id -> bool
var rest_buffer := PackedFloat32Array()  # (tests) the instances last put together
var rest_count := 0  # (tests, probes) resting arms drawn


## (rest arms) After the live arms are drawn: the chunks whose inserters changed, or whose live arms came or
## went, worked out again, and the boxes put together when any did.
func _update_rest(live: Dictionary, delta: float) -> void:
	if not rest_arms or world == null:
		if _rest_mmi != null and _rest_mmi.visible:
			_rest_mmi.visible = false
		return
	if not _rest_hooked and world.has_signal("entities_changed"):
		_rest_hooked = true
		world.entities_changed.connect(func(c: Vector2i) -> void: _rest_dirty[c] = true)
		for c in world.chunks:
			_rest_dirty[c] = true
	if _rest_mmi == null:
		var box := BoxMesh.new()
		box.size = Vector3.ONE
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.use_colors = true
		mm.mesh = box
		var mat := ShaderMaterial.new()
		mat.shader = RestShader
		mat.set_shader_parameter("roughness", 0.6)
		_rest_mmi = MultiMeshInstance3D.new()
		_rest_mmi.name = "RestingArms"
		_rest_mmi.multimesh = mm
		_rest_mmi.material_override = mat
		_rest_mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_child(_rest_mmi)
	_rest_mmi.visible = true
	for u in live:
		if not _rest_live.has(u):
			_rest_now[live[u]] = true
	for u in _rest_live:
		if not live.has(u):
			_rest_now[_rest_live[u]] = true
	_rest_live = live
	if eprops.size() != _rest_eprops:
		_rest_eprops = eprops.size()
		for c in world.chunks:
			_rest_dirty[c] = true
	var at_once := not _rest_now.is_empty()
	for c: Vector2i in _rest_now.keys():
		if _rest_chunk(c):
			_rest_now.erase(c)
			_rest_dirty.erase(c)
	var t0 := Time.get_ticks_usec()
	for c: Vector2i in _rest_dirty.keys():
		if _rest_chunk(c):
			_rest_dirty.erase(c)
		if Time.get_ticks_usec() - t0 > REST_USEC:
			break
	_rest_wait -= delta
	if _rest_put and (at_once or _rest_wait <= 0.0):
		_rest_put = false
		_rest_wait = REST_REFRESH
		var all := PackedFloat32Array()
		for c in _rest:
			all.append_array(_rest[c])
		var count := all.size() / 16
		var mm := _rest_mmi.multimesh
		if mm.instance_count < count or mm.instance_count > maxi(64, count * 4):
			mm.visible_instance_count = 0
			mm.instance_count = maxi(64, count + count / 2)
		all.resize(mm.instance_count * 16)  # (the rest scaled to nothing, and not drawn)
		rest_buffer = all
		mm.buffer = all
		mm.visible_instance_count = count
		rest_count = count / 3


## (rest arms) Chunk c's resting arms worked out again: every inserter in it not drawn live. False when one
## waits for its model (to be tried again).
func _rest_chunk(c: Vector2i) -> bool:
	var cv = world.chunks.get(c)
	_rest_put = true
	if cv == null:
		_rest.erase(c)
		return true
	var buf := PackedFloat32Array()
	var done := true
	for rec in cv.entities.values():
		var ins = _is_inserter.get(rec.proto_id)
		var proto: ProtoDB.EntityProto = protos.entity(rec.proto_id) if protos != null else null
		if ins == null:
			ins = proto != null and proto.type == "inserter"
			_is_inserter[rec.proto_id] = ins
		if not ins or _rest_live.has(rec.unit):
			continue
		var rig = _rig_for(proto.name)
		if rig == null:
			done = false  # (its model is still being read)
			continue
		_rest_arm(buf, rec, proto, rig)
	if buf.is_empty():
		_rest.erase(c)
	else:
		_rest[c] = buf
	return done


## (rest arms) One inserter's arm at rest into `buf`: from its shoulder (a rig's, or the base's top) through the
## elbow the IK gives to its grip over the pickup point (eprops `ip`, turned by its direction).
func _rest_arm(buf: PackedFloat32Array, rec, proto: ProtoDB.EntityProto, rig: Dictionary) -> void:
	var x: Dictionary = (eprops.get(rec.proto_id, {}) as Dictionary).get("x", {})
	var pick := _vec(x["ip"]) if x.has("ip") else Vector2(0.0, -2.0 if ARM_FAMILIES.get(proto.name, "") == "long" else -1.0)
	pick = _turn(pick, rec.dir)
	var turn := Basis(Vector3.UP, -pick.angle())
	var out := turn * Vector3.RIGHT
	var grip_at := Vector3(rec.pos.x, _grip_height(), rec.pos.y) + out * pick.length()
	var shoulder: Vector3
	var upper: float
	var fore: float
	if not rig.is_empty():
		var placed := ModelLibrary.placed(proto.name, proto.type, rec.dir, rec.extra, Vector3(rec.pos.x, 0.0, rec.pos.y))
		shoulder = placed * (rig["shoulder"] as Vector3)
		upper = float(rig["lengths"][0])
		fore = float(rig["lengths"][1])
	else:
		var lengths: Array = ARM_LENGTHS[ARM_FAMILIES.get(proto.name, "basic")]
		shoulder = Vector3(rec.pos.x, MODEL_SHOULDER, rec.pos.y)
		upper = float(lengths[0]) * float(lengths[2])
		fore = float(lengths[1]) * float(lengths[2]) * float(_claw.get(proto.name, CLAW_DEFAULT))
	var elbow := _elbow(shoulder, grip_at, out, upper, fore)
	var tints: Array = ARM_TINTS.get(proto.name, [proto.color.darkened(0.2), proto.color])
	_rest_box(buf, _segment(shoulder, elbow, turn, REST_UPPER), tints[0])
	_rest_box(buf, _segment(elbow, grip_at, turn, REST_FORE), tints[1])
	_rest_box(buf, Transform3D(turn * Basis.from_scale(REST_HAND), grip_at + Vector3(0.0, REST_HAND.y * 0.5, 0.0)), tints[1])


static func _rest_box(buf: PackedFloat32Array, t: Transform3D, c: Color) -> void:
	var b := t.basis
	var lin := c.srgb_to_linear()
	buf.append_array([b.x.x, b.y.x, b.z.x, t.origin.x, b.x.y, b.y.y, b.z.y, t.origin.y, b.x.z, b.y.z, b.z.z, t.origin.z,
		lin.r, lin.g, lin.b, 1.0])


## (handoff) The simulation's takes and puts (belt_items.gd take_hands: [why, inserter, tick, uid, x, z]):
## each taken or put item a meeting for its inserter's hand.
func _take_meets(list: Array) -> void:
	for h: Array in list:
		var why := int(h[0])
		if why != BeltSimConst.HAND_TAKEN and why != BeltSimConst.HAND_PUT:
			continue
		var arm: Arm = _arms.get(int(h[1]))
		if arm == null or is_nan(float(h[4])):
			continue
		var m := [float(h[2]), int(h[3]), float(h[4]), float(h[5]), why == BeltSimConst.HAND_TAKEN]
		var i := arm.meets.size()
		while i > 0 and float(arm.meets[i - 1][0]) > m[0]:
			i -= 1
		arm.meets.insert(i, m)
		while arm.meets.size() > 8:
			arm.meets.pop_front()
		if trace_meets and _trace != null:
			_trace.store_line('{"meet":[%d,%d,%d,%.3f,%.3f,%d]}' % [int(h[1]), int(h[2]), int(h[3]), float(h[4]), float(h[5]), why])


## (handoff) The hand at `t` steered onto the item it meets within STEER_IN ticks (its drawn place while
## it is on the belt, else where the simulation had it then), and eased back over STEER_OUT ticks after.
func _steer(arm: Arm, t: float) -> void:
	while not arm.meets.is_empty() and float(arm.meets[0][0]) < t - STEER_OUT - 60.0:
		arm.meets.pop_front()
	var best: Array = []
	var w := 0.0
	for m: Array in arm.meets:
		var mt: float = m[0]
		var wm := 0.0
		if t <= mt and t >= mt - STEER_IN:
			wm = 1.0 - (mt - t) / STEER_IN
		elif t > mt and t < mt + STEER_OUT:
			wm = 1.0 - (t - mt) / STEER_OUT
		if wm > w:
			w = wm
			best = m
	if best.is_empty() or w <= 0.0:
		return
	var target := Vector2(best[2], best[3])
	if bool(best[4]) and t < float(best[0]) and int(best[1]) != 0 and belts.has_method("position_of"):
		# (Still on the belt: where it is drawn now.)
		var at = belts.position_of(int(best[1]))
		if at is Vector3:
			target = Vector2((at as Vector3).x, (at as Vector3).z)
	w = w * w * (3.0 - 2.0 * w)
	var hand := Swing.hand_pos(arm.angle, arm.reach).lerp(target - arm.base, w)
	arm.angle = hand.angle()
	arm.reach = hand.length()
	steered += 1


## (--inserter-arms-trace) This frame: {"f": frame, "ms": wall msec, "T": the game tick the arms stand
## for (belt clock: the drawn tick; wall clock: where the update interpolation is between the last two
## updates' ticks), "B": the belts' drawn tick or -1, "us": the arms' cost this frame, "a": [unit, hand
## x, hand y (tiles), held item, ...]}.
func _write_trace(usec: int, t: float) -> void:
	var stands: float
	if belt_clock:
		stands = _drawn
	else:
		stands = lerpf(float(_prev_frame_tick), float(_frame_tick), t) if _frame_tick >= 0 else -1.0
	var belt_tick: float = belts.drawn_tick() if belts != null and belts.has_method("drawn_tick") else -1.0
	var parts := PackedStringArray()
	for unit in _arms:
		var arm: Arm = _arms[unit]
		var hand := arm.base + Swing.hand_pos(arm.angle, arm.reach)
		parts.append("%d,%.3f,%.3f,%d" % [unit, hand.x, hand.y, arm.item_id])
	_trace.store_line('{"f":%d,"ms":%d,"T":%.2f,"B":%.2f,"us":%d,"a":[%s]}' % [
		_frames, Time.get_ticks_msec(), stands, belt_tick, usec, ",".join(parts)])


## The arm rig of an inserter prototype's model with its MultiMeshes, made once its model is read;
## {} when the model has none (Wube's pieces then), null while the model is still being read.
func _rig_for(proto_name: String):
	if _rigs.has(proto_name):
		return _rigs[proto_name]
	if proto_name == "" or not ModelLibrary.rig_name(proto_name):
		_rigs[proto_name] = {}
		return _rigs[proto_name]
	if not ModelLibrary.ready(proto_name):
		return null
	ModelLibrary.mesh_for(proto_name)
	var rig := ModelLibrary.rig_for(proto_name)
	if rig.is_empty():
		_rigs[proto_name] = {}
		return _rigs[proto_name]
	var entry := rig.duplicate()
	var mmis: Array = []
	var meshes: Array = rig["meshes"]
	for p in ModelRig.Part.size():
		if meshes[p] == null:
			mmis.append(null)
			continue
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.mesh = meshes[p]
		var mmi := MultiMeshInstance3D.new()
		mmi.multimesh = mm
		mmi.name = "%s_rig_%d" % [proto_name, p]
		add_child(mmi)
		mmis.append(mmi)
	entry["mmis"] = mmis
	_rigs[proto_name] = entry
	return entry


## (--inserter-grip) Set by the arm drawn last: its grip, where a held item's middle goes (a rig's between its
## pincers, Wube's claw's middle), when it has one.
var _gripped := false
var _grip_at := Vector3.ZERO
## (--inserter-grip) Prototype -> how far along Wube's hand piece its claw's middle is, in hand lengths (the
## wrist at 1; the claw reaches on past it), from the closed hand's model.
var _claw := {}


## The grip's height: GRIP_HEIGHT, or with --inserter-grip GRIP_ABOVE_BELT over the belt items drawn when
## that is higher.
func _grip_height() -> float:
	if not held_grip or belts == null or not belts.has_method("item_height"):
		return GRIP_HEIGHT
	return maxf(GRIP_HEIGHT, float(belts.item_height()) + GRIP_ABOVE_BELT)


## Where a held item's base goes (ItemCards.draw adds the kind's lift): its middle in the grip of the arm just
## drawn (--inserter-grip), else ITEM_DROP below its wrist, as before.
func held_at(arm: Arm, wrist: Vector3) -> Vector3:
	if _gripped:
		_cards.prepare(arm.item_id)  # (its look known, its height with it, from its first frame)
		return _grip_at - Vector3(0.0, _cards.pile_step(arm.item_id) * 0.5, 0.0)
	return wrist - Vector3(0.0, ITEM_DROP, 0.0)


## Adds one arm's rig part transforms to `lists` (indexed by ModelRig.Part); returns where the held
## item hangs from (as the other arms' wrists). Each part's mesh is relative to its joint in the rest
## pose, so a part is drawn turned from its rest direction to where the IK puts it, about its joint.
func _draw_rig_arm(arm: Arm, rig: Dictionary, lists: Array) -> Vector3:
	var turn := Basis(Vector3.UP, -arm.angle)
	var out := turn * Vector3.RIGHT
	var across := turn * Vector3.BACK
	var hinge: Vector3 = rig["hinge"]
	var pivot_rest: Vector3 = rig["pivot"]
	var shoulder_rest: Vector3 = rig["shoulder"]
	var elbow_rest: Vector3 = rig["elbow"]
	var grip_rest: Vector3 = rig["grip"]
	var lengths: Array = rig["lengths"]
	var heads: Array = rig["heads"]
	# The turntable yaws about its joint, where the base model has it, to face the hand.
	var table := aim(Vector3.UP, hinge, Vector3.UP, across)
	var pivot := arm.placed * pivot_rest
	var shoulder := pivot + table * (shoulder_rest - pivot_rest)
	var grip := Vector3(arm.base.x, _grip_height(), arm.base.y) + out * arm.reach
	var upper: float = lengths[0]
	var fore: float = lengths[1]
	var stretch := 1.0
	var need := shoulder.distance_to(grip)
	if need > (upper + fore) * RIG_REACH:
		stretch = need / ((upper + fore) * RIG_REACH)
		if not _stretched.has(arm.proto_name):
			_stretched[arm.proto_name] = true
			print("[inserters] %s: the model's arm (%.3f) is shorter than the hand's reach (%.3f): stretched to reach" % [
				arm.proto_name, upper + fore, need])
	var elbow := _elbow(shoulder, grip, out, upper * stretch, fore * stretch)
	var lower_dir := elbow_rest - shoulder_rest
	var upper_dir := grip_rest - elbow_rest
	var lower_turn := aim(lower_dir, hinge, elbow - shoulder, across) * along(lower_dir, stretch)
	var upper_turn := aim(upper_dir, hinge, grip - elbow, across) * along(upper_dir, stretch)
	if heads[ModelRig.Part.TURNTABLE] != null:
		lists[ModelRig.Part.TURNTABLE].append(Transform3D(table, pivot))
	lists[ModelRig.Part.LOWER].append(Transform3D(lower_turn, shoulder))
	lists[ModelRig.Part.UPPER].append(Transform3D(upper_turn, elbow))
	var axes: Array = rig["axes"]
	# (--inserter-grip) Closed onto the held item's sides, not till they meet through it.
	var angles: Array = rig.get("grip_angles", rig["angles"]) if held_grip else rig["angles"]
	for p in [ModelRig.Part.PINCER_A, ModelRig.Part.PINCER_B]:
		if heads[p] == null or angles[p] == null:
			continue
		var head: Vector3 = heads[p]
		var shut := Basis(axes[p] as Vector3, float(angles[p]) * arm.close)
		lists[p].append(Transform3D(upper_turn * shut, elbow + upper_turn * (head - elbow_rest)))
	_gripped = held_grip
	_grip_at = grip
	return grip + Vector3(0.0, ITEM_DROP, 0.0)


## The turn taking a part whose bone points along `rest_dir`, bending about `rest_hinge`, to point
## along `dir` bending about `hinge` (both frames: bone, hinge made square to it, and their cross).
static func aim(rest_dir: Vector3, rest_hinge: Vector3, dir: Vector3, hinge: Vector3) -> Basis:
	return _frame(dir, hinge) * _frame(rest_dir, rest_hinge).inverse()


static func _frame(dir: Vector3, hinge: Vector3) -> Basis:
	var y := dir.normalized()
	var z := (hinge - y * hinge.dot(y)).normalized()
	return Basis(y.cross(z), y, z)


## A stretch by `s` along `dir` (and none across it).
static func along(dir: Vector3, s: float) -> Basis:
	if is_equal_approx(s, 1.0):
		return Basis.IDENTITY
	var d := dir.normalized()
	var k := s - 1.0
	return Basis(Vector3.RIGHT + d * (d.x * k), Vector3.UP + d * (d.y * k), Vector3.BACK + d * (d.z * k))


## The arm pieces of an inserter prototype, made on first use; null without the models.
func _pieces_for(proto_name: String):
	if _model_parts.has(proto_name):
		return _model_parts[proto_name]
	var family: String = ARM_FAMILIES.get(proto_name, "basic")
	# Made on worker threads (reading one here cost 2-4 ms a piece): the plain arm stands in until then.
	var waiting := false
	for piece in ["upper", "hand-open", "hand-closed"]:
		if not ModelLibrary.ready("inserter-arm-%s-%s" % [family, piece]):
			waiting = true
	if waiting:
		return null
	var out := []
	for piece in ["upper", "hand-open", "hand-closed"]:
		var mesh := ModelLibrary.mesh_for("inserter-arm-%s-%s" % [family, piece])
		if not (mesh is ArrayMesh):
			for mmi in out:
				mmi.queue_free()
			out.clear()
			break
		if piece == "hand-closed":
			# (The piece points north from the elbow, the wrist at its modelled length; the claw beyond.)
			var hand_length: float = (ARM_LENGTHS[family] as Array)[1]
			_claw[proto_name] = maxf(1.0, (hand_length - mesh.get_aabb().position.z) * 0.5 / hand_length)
		if ARM_TINTS.has(proto_name):
			mesh = ModelLibrary._tinted(mesh as ArrayMesh, ARM_TINTS[proto_name][0 if piece == "upper" else 1])
			# The arm pieces are thin: nearly every face is a bevel or rim to the weathering, which
			# chipped them all to bare steel. The sprites' arms are painted with a little wear.
			ModelLibrary.set_named(mesh as ArrayMesh, ModelLibrary.TIER_MATERIAL, "edge_wear", ARM_EDGE_WEAR)
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.mesh = mesh
		var mmi := MultiMeshInstance3D.new()
		mmi.multimesh = mm
		mmi.name = "%s_%s" % [proto_name, piece]
		add_child(mmi)
		out.append(mmi)
	_model_parts[proto_name] = out if not out.is_empty() else null
	return _model_parts[proto_name]


## Adds one arm's piece transforms (Wube's models) to `lists` (indexed by ArmPiece); returns
## the wrist position.
func _draw_model_arm(arm: Arm, lists: Array) -> Vector3:
	var lengths: Array = ARM_LENGTHS[ARM_FAMILIES.get(arm.proto_name, "basic")]
	var stretch: float = lengths[2]
	var upper: float = lengths[0] * stretch
	var fore: float = lengths[1] * stretch
	var turn := Basis(Vector3.UP, -arm.angle)
	var out := turn * Vector3.RIGHT
	var shoulder := Vector3(arm.base.x, MODEL_SHOULDER, arm.base.y)
	var wrist := Vector3(arm.base.x, HAND_HEIGHT, arm.base.y) + out * arm.reach
	var elbow: Vector3
	if held_grip:
		# (--inserter-grip) The claw's middle reaches the hand's place at the grip's height, as a rig's grip does:
		# the IK to it with the hand as long as that, the wrist on the way.
		var claw: float = _claw.get(arm.proto_name, 1.0)
		var g := Vector3(arm.base.x, _grip_height(), arm.base.y) + out * arm.reach
		elbow = _elbow(shoulder, g, out, upper, fore * claw)
		wrist = elbow + (g - elbow) / claw
		_gripped = true
		_grip_at = g
	else:
		elbow = _elbow(shoulder, wrist, out, upper, fore)
		_gripped = false
	lists[ArmPiece.UPPER].append(_piece(shoulder, elbow, turn, lengths[0]))
	var hand := ArmPiece.CLOSED if arm.item_id > 0 else ArmPiece.OPEN
	lists[hand].append(_piece(elbow, wrist, turn, lengths[1]))
	return wrist


## A model piece (joint at its origin, pointing north, lying flat) from joint a to joint b,
## stretched from its modelled `length`.
func _piece(a: Vector3, b: Vector3, turn: Basis, length: float) -> Transform3D:
	var along := b - a
	var d := maxf(along.length(), 0.01)
	var z := -along / d
	var x := turn * Vector3.BACK
	var y := z.cross(x).normalized()
	if y.y < 0.0:
		y = -y
	x = y.cross(z).normalized()
	# The piece lies on y = 0 with its joints about half its thickness up.
	return Transform3D(Basis(x, y, z * (d / length)), a - y * 0.05)


## Adds one arm's part transforms to `lists` (indexed by Part); returns the wrist position.
func _draw_arm(arm: Arm, lists: Array) -> Vector3:
	_gripped = false  # (the placeholder's item hangs ITEM_DROP below its wrist, as before)
	var base_top := Visuals.HEIGHTS.get("inserter", 0.3) as float
	# Factorio's angle is clockwise from east on screen (y points south); Godot's yaw is
	# counter-clockwise seen from above, so the arm turns by -angle.
	var turn := Basis(Vector3.UP, -arm.angle)
	var out := turn * Vector3.RIGHT  # horizontal, towards the hand
	var shoulder := Vector3(arm.base.x, SHOULDER_HEIGHT, arm.base.y)
	var wrist := Vector3(arm.base.x, HAND_HEIGHT, arm.base.y) + out * arm.reach
	var elbow := _elbow(shoulder, wrist, out, UPPER_ARM, FOREARM)

	var table_y := base_top + TURNTABLE.y * 0.5
	lists[Part.TURNTABLE].append(Transform3D(turn * Basis.from_scale(TURNTABLE), Vector3(arm.base.x, table_y, arm.base.y)))
	var post := Vector3(SHOULDER.x, SHOULDER_HEIGHT - base_top, SHOULDER.z)
	lists[Part.SHOULDER].append(Transform3D(turn * Basis.from_scale(post), Vector3(arm.base.x, (base_top + SHOULDER_HEIGHT) * 0.5 + 0.02, arm.base.y)))
	lists[Part.UPPER].append(_segment(shoulder, elbow, turn, ARM_THICKNESS * 1.3))
	lists[Part.FOREARM].append(_segment(elbow, wrist, turn, ARM_THICKNESS))
	# The hand stays level, across the arm; two fingers hang from its sides.
	var hand_at := wrist + Vector3(0.0, HAND_SIZE.y * 0.5, 0.0)
	lists[Part.HAND].append(Transform3D(turn * Basis.from_scale(HAND_SIZE), hand_at))
	var across := turn * Vector3.BACK
	for side: float in [-1.0, 1.0]:
		var finger: Vector3 = wrist + across * (side * (HAND_SIZE.z * 0.5 - FINGER_SIZE.z * 0.5)) - Vector3(0.0, FINGER_SIZE.y * 0.5, 0.0)
		lists[Part.FINGERS].append(Transform3D(turn * Basis.from_scale(FINGER_SIZE), finger))
	return wrist


## Where the elbow goes: two-bone IK in the arm's vertical plane, bending upwards.
func _elbow(shoulder: Vector3, wrist: Vector3, out: Vector3, upper: float, fore: float) -> Vector3:
	var to_wrist := wrist - shoulder
	var d := clampf(to_wrist.length(), 0.05, upper + fore - 0.001)
	var horizontal := Vector2(to_wrist.x, to_wrist.z).dot(Vector2(out.x, out.z))
	var dir_angle := atan2(to_wrist.y, horizontal)  # of the shoulder-wrist line, from level
	var cos_a := (upper * upper + d * d - fore * fore) / (2.0 * upper * d)
	var lift := dir_angle + acos(clampf(cos_a, -1.0, 1.0))
	return shoulder + out * (cos(lift) * upper) + Vector3.UP * (sin(lift) * upper)


## A box from a to b, `thickness` square, turned with the arm.
func _segment(a: Vector3, b: Vector3, turn: Basis, thickness: float) -> Transform3D:
	var along := b - a
	var length := maxf(along.length(), 0.01)
	var x := along / length
	var z := turn * Vector3.BACK
	var y := z.cross(x).normalized()
	z = x.cross(y)
	var basis := Basis(x * length, y * thickness, z * thickness)
	return Transform3D(basis, (a + b) * 0.5)


func _part_color(part: int, color: Color) -> Color:
	match part:
		Part.TURNTABLE:
			return color.darkened(0.2)
		Part.UPPER:
			return color.darkened(0.1)
		Part.HAND:
			return color.darkened(0.35)
		Part.FINGERS, Part.SHOULDER:
			return DARK_STEEL
	return STEEL
