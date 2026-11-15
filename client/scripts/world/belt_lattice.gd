extends RefCounted
## --belt-draw-lattice: lanes the game has packed are drawn packed (owner's concession). Items on a belt
## sit 0.25 tile apart, so a lane full of one kind drawn as a row of that item every 0.25 tile, at any
## phase, has each of the game's items within 0.125 tile of one drawn: such a lane needs no simulated
## positions or ids, only "full, kind X". (tools: the lattice job's rescore of the every-tick capture at
## -62,-26: 97% of the game's items were on lanes full of one kind, and 96% of what the simulation
## missed was on them; docs/BELT-SIM-PLAN.md.)
##
## Which lanes: those the bridge's last read of the lane (`sl`) found full of one kind, while its drift
## checks (`pc`) after say it is still full (full: as many items as whole gaps fit in its length, every gap
## at most 66). A lane read with gaps or two kinds, or checked short, is drawn from the simulation again.
## Underground lines under the ground, loaders and other lanes keep the simulation's items.
##
## How: each such lane in view gets a lattice: one record a slot, every 64 (1/256 tile) from the
## simulation's front item on the lane (its phase), sliding at that item's speed: the record's texel 3
## holds the lattice's period (ticks per gap) and the shader takes the drawn clock modulo it, so a
## moving lattice costs nothing until its speed changes (the simulation's front item standing or moving at
## two checks in a row: a stop-and-go lane is drawn as it was) or its phase drifts DRIFT off the
## simulation's. A speed change keeps the lattice where it is drawn, so it never jumps; any phase draws a
## full lane within 0.125 tile of the game's items, so the phase is only made again for a big drift.
## The simulation's items on those lanes stay simulated, but the shader hides every item record whose
## place falls in a cell of the lanes' mask (CELLS a tile, MASK cells a side, wrapping): a lane's
## centre line marks its cells, so an item gliding off a lattice lane onto a loose one shows again.
## The lattice has its own records (f3d_belt_lattice) and its own MultiMeshes (item_cards.gd with
## record_tex 1), the same for the GDScript and the C++ records paths: it is made in GDScript from the
## messages, the lane meta and BeltSim.lane_fronts (the C++ simulation's when loaded).
##
## Stacks: a lane's slots are piles as high as the stacks its last read (`sl`) found most often (a stack
## inserter's bus is stacks of 4 throughout): each slot has STACK records, the slot's own and a copy per
## step above it, the copies pointing at the slot's record as belt_items.gd's piles do (texel 3: the slot
## from the copy, its step k, the kind's pile step), so they slide with the slot and the mask never hides
## them; each copy turns PILE_TURN more than the one under it, cards and blocks too.
##
## Turns (K14, owner: "items change their orientation as they move on the belts"): a slot slides one gap
## and wraps back, the slot ahead taking its item on, so a turn kept per slot changed every item's turn
## each quarter tile. Each drawn item is someone instead (`who`): a lane's identity function, who the item
## at line position q is on tick t, is ln.who + (q + v (t - t0) - r0) / 64, so slot k starts at
## who + k and the shader adds the periods slid (texel 2: x who the slot's item was on its record's
## clock, y the run's seed; texel 3 z 2) and hashes both into the turn (ItemCards.lattice_turn, the same
## range and pile rule as every item's turn_for). A lane written again (a new speed or phase, its piles)
## keeps who its items are: each new slot takes the nearest old item's (_set_motion). A new lane takes
## its neighbour's, the drawn lane its items go on into or come from (so an item keeps its turn from belt
## to belt), else the map's along its exit's direction (_identify). CPU work only when a lane is written.
## --belt-draw-lattice-turns=slot: a turn per slot, as before (texel 2 its cosine and sine, texel 3 z 1).

const BeltRecords := preload("res://scripts/world/belt_records.gd")
const BeltSim := preload("res://scripts/world/belt_sim.gd")
const ItemCards := preload("res://scripts/world/item_cards.gd")

const GAP := 64
const CELLS := 4
const MASK := 2048
## A drawn lattice whose phase is this far (1/256) off the simulation's front item, or whose speed
## differs, is made again.
const DRIFT := 24
## Checks in a row a new speed must be seen at before the lattice takes it.
const SPEED_CHECKS := 2
## Records hold this much below their item's lift, as the items' do (belt_items.gd LAYER_STEP).
const LAYER_STEP := 0.006
const LAYERS := 4
## Lanes longer than this (1/256) are never drawn as a lattice (a belt's lanes are at most 2 tiles; a
## message with another length is malformed: its slots and mask cells would run to millions).
const MAX_LENGTH := 1024
## Lanes are drawn when their middle is within the camera's view grown by VIEW_KEEP (tiles); that ground
## is planned again when the view leaves it.
const VIEW_KEEP := 12.0
## A drawn lattice's phase is checked against the simulation's every SLICES updates (a slice of the lanes
## each), and at once when the bridge reads or checks the lane.
const SLICES := 2
## As belt_items.gd's: a stack is at most this many, each copy above turned PILE_TURN more.
const MAX_STACK := 4
const PILE_TURN := 0.45
## Who a lattice's items are, and its runs' seeds, are kept modulo this (a float32 holds them exactly; the
## shader hashes only these bits: ItemCards.lattice_turn).
const IDS := 1 << 20

## --belt-draw-lattice=off: every lane drawn from the simulation (as before).
static var on := true
## On (the default; --belt-draw-lattice=sim: off): a straight lane's (and an underground's visible
## half's) lattice has the map's phase, a function of where its exit is and the tick alone (items at
## tau = v * t mod 64 along its way), so the lanes of a run agree whenever each was written and wherever
## the drawn clock is; curves and splitters keep the simulation's front item's phase. Live at -62,-26
## (2 runs each): 95.7 / 95.2% visible, 2.4 / 2.5% phantoms against the simulation's phase's 94.5 / 91.9%,
## 3.5 / 3.6% (its errors were at lane ends, neighbours' phases disagreeing).
static var world := true
## --belt-draw-lattice-world=all (the default; straight: as before): with `world`, a moving curve's or
## splitter's lattice takes the map's phase too, not the simulation's front item's. Any phase draws a
## full lane within 0.125 tile of the game's items, but a splitter's inputs overlap its outputs (the 51
## buffer) and a curve's last slot reaches past its entry, so where two lanes' lattices meet their
## phases must agree for every game item to have a slot of its own; the simulation's front on a
## balancer's lanes is often a tick or two off the game's (32-64 at turbo speed), which left one game
## item in three on splitter lanes at -62,-26 without a slot within 0.15 tile (section L: 10% of the
## items on splitter lanes missed, 7% of the slots phantoms).
static var world_all := true
## --belt-draw-lattice-standing=obs (the default; world: as before): a standing lattice (the simulation's
## front on the lane standing, or none there) takes its phase from the bridge's last read or check of the
## lane (its front item's position: `sl`, `pc`), not the map's (straight lanes) nor the simulation's front
## (others). A standing lane's items are exactly where the game last showed them; the map's phase was up
## to 0.125 tile off (a run backed up at phase 32 sat at the check's limit), and a standing lattice with a
## high phase had one slot too few for the lane's items.
static var standing_obs := true
## --belt-draw-lattice-pile=off: every slot one item, whatever the lane's stacks (as the first cut: a bus
## of stacks of 4 drawn flat).
static var piles := true
## (unison) On (the default): every drawn lane's speed is checked against the simulation's every job,
## and a new speed is taken at once, so the lanes of a run that starts or stops moving all change in the
## same job the simulation's own records do (the map's phase then keeps their lattices in step). Off
## (--belt-draw-lattice-unison=off, as before): a slice of the lanes a job (SLICES) and a new speed only
## at SPEED_CHECKS checks in a row, so neighbouring lanes changed speed jobs apart: at each lane boundary
## the sliding lane's slots opened and closed a gap of up to 0.25 tile against the standing one (the
## owner's "shimmer of small gaps" as a backed-up line starts moving), and at the run's ends the
## simulation's items moved away from the standing lattice for two jobs.
static var unison := true
## (settle) On (the default; --belt-draw-lattice-settle=off: as before): a standing lattice stays where it
## is while its lane closes a hole. An inserter's take from a backed-up line moves every item behind it one
## gap on and they stand again: a row of one kind a whole gap on is the same picture, but each lane's lattice
## took the new speed at once, at the map's phase (up to 0.125 tile from where it stood), slid for an update
## or two, stopped wherever that left it and was set again at the lane's next read or check: the whole line
## behind the hand jumped an eighth of a tile twice at every take (the owner, K19: "they all of a sudden jump
## around"). Now a standing lane only takes a new speed once the simulation has had it moving for more
## than two gaps' time (16 ticks on a yellow belt: a line that really flows), and a standing lane's phase is
## the simulation's standing front item's (the bridge's last read or check only where the simulation has no
## item there): a read made mid-way through the closing gave a phase part of a gap out until the next one.
## A lane that comes to be drawn while it moves waits as long before it is (it is drawn from the simulation
## meanwhile): made at once it slid at the map's phase for the rest of the closing, then stood and jumped.
## And the hole a take leaves in a standing lane (hole()) closes once the drawn clock is a gap's time past
## the take, the line having closed up: it stayed open for as long as the lane stood and stayed full.
static var settle := true
## (settle) A standing lane takes a new speed after this many gaps' time of it.
const SETTLE_GAPS := 2
## (settle) A standing lane's hole closes this many ticks after the take when the lane's speed isn't known
## (a yellow belt's gap); at its speed when the simulation has had it moving since.
const HOLE_TICKS := 8
## (creep) --belt-draw-lattice-creep=on (off by default: as before; flow, below: by the net flow): a standing lane the simulation keeps
## moving in steps slides at the speed it moves at on average. On a creeping lane (an inserter's pickup
## belt, a merge, a line behind one: its items move up a gap and stand, again and again) the front item
## waits at the exit while the items behind it close up, so its speed (the lattice's) was 0 at nearly every
## update, and with settle a standing lane takes a speed only after two gaps' time of steady motion: the
## whole lane stood for seconds while the game's items moved on (the owner: "items on belts sometimes hold
## in place for like 10 seconds or groups of items"; live at -62,-26 with consumers restarting, 23% of the
## items in view on lanes drawn standing while the game moved them). Each lane keeps a running share of
## the time the simulation has most of its items moving (BeltSim.lane_fronts speed_of 1, FLOW_ONE the whole,
## CREEP_TAU ticks); over CREEP_ON it slides on from where it is drawn (no jump) at that share of the belt's
## speed, and goes back to settle's rules below CREEP_OFF (standing on the simulation's front) or once the
## simulation has had it moving steadily CREEP_RUN_GAPS gaps' time (the belt's own speed). A single take's
## closing (a gap on, standing again: K19's case) moves it for a few ticks only, far below CREEP_ON.
## By the share alone, live at -62,-26 (consumers restarting) it took the lanes drawn standing while the game's
## moved from 23.2% of the items in view to 2.7%, but the simulation moves many lanes the game holds (into
## splitters, at reads), and those now slid: lanes drawn sliding while the game's stood 4.2% -> 16.5%,
## visible 97.1 -> 96.4%. It wanted a test that the lane's items really flow through it: creep_flow below
## (--belt-draw-lattice-creep=flow; on: by the share, as this first cut). Off by default (as before creep).
static var creep := false
const FLOW_ONE := 1024
const CREEP_TAU := 120
const CREEP_ON := 256
const CREEP_OFF := 102
const CREEP_RUN_GAPS := 4
## (creep_flow) --belt-draw-lattice-creep=flow (off by default; on: by the share above): a lane creeps by the net distance its
## items go on past its exit, not by the time they move. The simulation's front item on the lane
## (BeltSim.lane_fronts speed_of 2) changing to one the lane hasn't had in front is a gap on; to one it had (of
## its last FLOW_HIST fronts) a read putting the items back: a gap back for each front since. Its running rate
## (1/256 a tick, in FLOW_ONE, over CREEP_TAU) at CREEP_FLOW_ON or more has a standing lane slide on from where
## it is drawn at that rate (at least 1/256 a tick), below CREEP_FLOW_OFF on to the simulation's standing
## front's phase and stand. Its new motion starts at the drawn clock's tick, where it is drawn then (set at the
## simulation's tick, the lattice jumped by the change of speed times the drawn clock's lag). A lane the
## simulation has none on stands where it is drawn (creeping: at once; at the simulation's speed: after
## NONE_TICKS): it went on as it was for good. And a lane at the simulation's speed for FLOW_GATE_TICKS whose
## net rate is under FLOW_GATE (about a gap in 16 ticks) stands, and takes the simulation's speed again only
## with that rate: the simulation runs on lanes the game holds (at -62,-26 the lines into a balancer let go
## and read back again and again), the same fronts coming back with each read. Offline (the restart
## capture): lanes drawn standing while the game's moved 3.2% (settle alone 19.1%), sliding while the game's
## stood 3.2% (4.7%), no frozen span of 5 s or more (133).
static var creep_flow := true
const FLOW_HIST := 16
const CREEP_FLOW_ON := 300
const CREEP_FLOW_OFF := 100
const NONE_TICKS := 30
const FLOW_GATE := 1000
const FLOW_GATE_TICKS := 120
## --belt-draw-lattice-turns=slot: each slot keeps a turn of its own (as before K14), so an item seen
## sliding along takes the next slot's turn every quarter tile. On (the default): a turn per item.
static var item_turns := true

class Lane:
	var item := 0
	var kind_key := 0
	var slots := PackedInt32Array()
	var r0 := 0  # its phase: the front slot's line position on tick t0
	var t0 := 0
	var v := 0
	var pend_v := -1  # a new speed seen at pend_n checks in a row
	var pend_n := 0
	var pend_t := 0  # (settle) the tick pend_v was first seen at
	var hole_at := -1  # (settle) the tick of the newest hole cut in it while it stands (-1: none open)
	var hole_v := 0  # (settle) the speed the simulation has had the lane at since
	var cells := PackedInt32Array()
	var stack := 1  # records a slot: ln.slots[k * stack + j] is slot k's copy j (0: its own record)
	var who := 0  # who the item at line position r0 is on tick t0 (modulo IDS)
	var run := 0  # its run's seed (modulo IDS)
	var next := 0  # the lane its items go on into when it was drawn (BeltSim.next_of), 0 none
	var flow_q := 0  # (creep) the running share of the time most of its items move, of FLOW_ONE
	var flow_t := -1  # (creep) the tick of its last share's update
	var run_t := -1  # (creep) the tick most of its items started moving, -1 while they stand
	var creeping := false  # (creep) sliding at its share of the belt's speed
	var fu := PackedInt32Array()  # (creep_flow) its recent front items' ids (low 31 bits), oldest first
	var none_t := -1  # (creep_flow) the tick the simulation was first seen with none on it, -1 while it has
	var gated := false  # (creep_flow) stood for want of net flow: takes the simulation's speed again only with it


class LKind:
	var base := -1
	var cap := 0
	var top := 0
	var free: Array[int] = []
	var told := Vector3i(-1, -1, -1)


var info := {}  # lane key -> [full (bool), item id (-1: none or mixed), stack (the read's most common), the front item's position at the last read or check (-1: none)]
var drawn := {}  # lane key -> Lane
var kinds := {}  # kind key -> LKind
var records := BeltRecords.new()
var mask: Image = null
var mask_n := PackedByteArray()  # lanes marking each cell
var mask_dirty := false
var lanes_n := 0  # lanes drawn after the last update
var slots_n := 0
var want := {}  # lane key -> item: lanes to draw (full of one kind, in the planned ground)
var undrawn := {}  # lane keys wanted but not drawn yet (their look not known yet)
var dirty := {}  # lane keys read, checked or dropped since the last update
var mids := {}  # lane key -> Vector2: its middle (tiles)
var planned := Rect2()
var planned_all := false
var planned_any := false
var round_no := 0
var planned_cap := -2
## (settle) The drawn clock's tick (belt_items.gd sets it before update()): a standing lane's hole closes by it.
var drawn_tick := -1
var moving_since := {}  # (settle) lane key -> the tick it was first wanted while moving, not drawn yet
var feeds := {}  # lane key -> the drawn lane whose items go on into it (its `next` when drawn)
## The drawn clock when this update's records are first drawn (belt_items.gd Job.fold_tick; -1: the update's
## tick). The drawn clock runs behind the simulation, so a lane that starts or stops is drawn jumping by its
## speed times that lag: who its items are is matched as both lattices are drawn then (matched at the
## simulation's tick, a stop handed each slot the item behind it, a jump of over half a gap seen).
var shown := -1.0


## A lane read in full (`sl`): items as [uid, item id, pos, stack] four a lane item, front first.
func note_read(key: int, length: int, items: PackedInt64Array) -> void:
	var n := items.size() / 4
	if n == 0:
		info[key] = [false, -1, 1, -1]
		dirty[key] = true
		return
	dirty[key] = true
	var item := int(items[1])
	var front := int(items[2])
	var full := n >= maxi(1, length / GAP)
	var counts := PackedInt32Array()
	counts.resize(MAX_STACK + 1)
	for j in n:
		counts[clampi(int(items[j * 4 + 3]), 1, MAX_STACK)] += 1
		if j == 0:
			continue
		if int(items[j * 4 + 1]) != item:
			info[key] = [false, -1, 1, front]
			return
		if int(items[j * 4 + 2]) - int(items[j * 4 - 2]) > GAP + 2:
			full = false
	var stack := 1
	for c in range(2, MAX_STACK + 1):
		if counts[c] > counts[stack]:
			stack = c
	info[key] = [full, item, stack, front]


## A lane's drift check (`pc`): count, smallest and largest position.
func note_check(key: int, length: int, count: int, front: int, back: int) -> void:
	var e: Array = info.get(key, [false, -1, 1, -1])
	e[0] = count >= maxi(1, length / GAP) and count <= length / GAP + 2 and back - front <= (GAP + 2) * (count - 1)
	if e.size() < 4:
		e.append(-1)
	e[3] = front if count > 0 else -1
	info[key] = e
	dirty[key] = true


## (standing_obs) The front item's position at the bridge's last read or check of the lane, -1 none.
func _obs_front(key: int) -> int:
	var e: Array = info.get(key, [])
	return int(e[3]) if e.size() > 3 else -1


func drop(key: int) -> void:
	info.erase(key)
	mids.erase(key)
	moving_since.erase(key)
	dirty[key] = true


## Whether any lane is drawn as a lattice now (belt_items.gd: the update runs while any is, the switch off too).
func has_drawn() -> bool:
	return not drawn.is_empty()


## The update after a job's simulation: lanes in or out of the lattice, phases made again. Returns
## {written: [[kind key, base, n, cap], ...], pages, mask (Image or null), unknown: [kind keys], added and
## removed: the lanes it began and stopped drawing (PackedInt64Array; belt_items.gd's records park and count
## the items they hide)}; with `dump`, dump_ids / dump_recs / dump_gone as belt_items.gd's --belt-draw-dump
## writes them.
func update(job_state, sim, tick: int, view: Rect2, view_all: bool, known: Dictionary, model_cap: int, full: bool,
		dump: bool) -> Dictionary:
	var lanes: Dictionary = job_state.lanes
	var res := {"written": [], "unknown": [], "dump_ids": PackedInt64Array(), "dump_recs": PackedFloat32Array(),
		"dump_gone": PackedInt64Array(), "mask": null, "dump_on": dump, "removed_keys": {}, "added_keys": {}}
	records.base = job_state.records.base
	# Which lanes to draw: all again when the planned ground or the look changed, else only those the
	# bridge said something about.
	var replan := full or view_all != planned_all or not planned_any or (not view_all and not planned.encloses(view)) 		or model_cap != planned_cap
	var look_at: Array
	if replan:
		planned_cap = model_cap
		planned = view.grow(VIEW_KEEP)
		planned_all = view_all
		planned_any = true
		want.clear()
		undrawn.clear()
		look_at = info.keys()
		for key: int in drawn:
			if not info.has(key):
				look_at.append(key)
	else:
		look_at = dirty.keys()
	# (A lane's stacks change only with a read: a drawn lane checked for its phase alone keeps its own.)
	var heard := dirty
	dirty = {}
	var check := {}  # lanes to draw or check now
	for key: int in look_at:
		var item := _wanted(job_state, key, lanes)
		if item < 0:
			want.erase(key)
			undrawn.erase(key)
		else:
			want[key] = item
			check[key] = true
			if not drawn.has(key):
				undrawn[key] = true
	var unknown := {}
	for key: int in (drawn.keys() if replan else look_at):
		if not drawn.has(key):
			continue
		var ln: Lane = drawn[key]
		if not want.has(key) or want[key] != ln.item or ln.kind_key != _kind_key(want[key], model_cap):
			_remove(key, res)
			if want.has(key):
				undrawn[key] = true
	# A slice of the drawn lanes has its phase checked against the simulation's each update.
	round_no += 1
	var slice := round_no % SLICES
	for key: int in drawn:
		if unison or posmod(key >> 3, SLICES) == slice:
			check[key] = true
	for key: int in undrawn:
		check[key] = true
	var keys := PackedInt64Array()
	for key: int in check:
		if want.has(key):
			keys.append(key)
	var fronts: PackedInt32Array = sim.lane_fronts(keys) if not keys.is_empty() else PackedInt32Array()
	# (creep) The speed most of each lane's items move at.
	var lane_v: PackedInt32Array = sim.lane_fronts(keys, 2 if creep_flow else 1) if creep and not keys.is_empty() 		else PackedInt32Array()
	var base: float = records.base
	for q in keys.size():
		var key := keys[q]
		var item: int = want[key]
		var kk := _kind_key(item, model_cap)
		var look: Array = known.get(kk, [])
		if look.is_empty():
			unknown[kk] = true
			continue
		var m: PackedInt32Array = lanes[key]
		var f := fronts[q * 3]
		var v := fronts[q * 3 + 1]
		var has := fronts[q * 3 + 2] > 0
		var ln: Lane = drawn.get(key)
		var wl := world and (m[0] == BeltSim.STRAIGHT or m[0] == BeltSim.UG_VISIBLE or world_all and (m[0] == BeltSim.CURVE
			or m[0] == BeltSim.SPLIT_IN or m[0] == BeltSim.SPLIT_OUT))
		# (standing_obs: the game's front on the lane at its last read or check, -1 none.)
		var obs := _obs_front(key) if standing_obs else -1
		var st := _stack_of(key) if ln == null or replan or heard.has(key) else ln.stack
		if settle and ln != null and ln.hole_at >= 0:
			# (The hole a take left: closed once the drawn clock is a gap's time past it.)
			if has and v > 0:
				ln.hole_v = v
			if ln.v > 0:
				ln.hole_at = -1  # (a moving lane's holes end with their slots' periods)
			elif drawn_tick >= ln.hole_at + (ceili(float(GAP) / float(ln.hole_v)) if ln.hole_v > 0 else HOLE_TICKS):
				ln.hole_at = -1
				_write_lane(job_state, key, ln, m, look, base, res, ln.stack)
		# (A lane whose stacks changed is made again with its new piles, its phase as a new lane's.)
		if ln != null and ln.stack == st:
			if creep and creep_flow:
				# (creep_flow) A moving lane the simulation has had none on for NONE_TICKS (at once, creeping)
				# stands where it is drawn: it went on as it was for good.
				if has:
					ln.none_t = -1
				elif ln.v > 0:
					if ln.none_t < 0:
						ln.none_t = tick
					if tick - ln.none_t >= NONE_TICKS or (not has and ln.creeping):
						var td1 := _t_draw(tick)
						_creep_stop(ln, _phase_at(ln, td1), td1)
						_write_lane(job_state, key, ln, m, look, base, res, st)
						continue
			if not has:
				# (The simulation has none there: the lattice goes on as it was; a standing one is set to a
				# new observation of the lane.)
				if not (obs >= 0 and ln.v == 0 and heard.has(key) and posmod(obs, GAP) != ln.r0):
					continue
			else:
				var pred := posmod(ln.r0 - ln.v * (tick - ln.t0), GAP)
				if creep and q * 3 + 2 < lane_v.size():
					if (_creep_flow(ln, lane_v[q * 3 + 1], lane_v[q * 3 + 2], m[2], tick, pred, f) if creep_flow
							else _creep(ln, lane_v[q * 3 + 1], m[2], tick, pred, f)):
						_write_lane(job_state, key, ln, m, look, base, res, st)
						continue
					if ln.creeping:
						continue  # (sliding at its share: the simulation's stops and starts aren't taken)
					if creep_flow and ln.v > 0 and tick - ln.t0 >= FLOW_GATE_TICKS and ln.flow_q < FLOW_GATE:
						# (creep_flow) At the simulation's speed this long, its items hardly went on past its exit
						# (fronts it had coming back with reads): the simulation runs it where the game's stands.
						var td3 := _t_draw(tick)
						_set_motion(ln, _phase_at(ln, td3), 0, td3)
						ln.pend_v = -1
						ln.pend_n = 0
						ln.gated = true
						_write_lane(job_state, key, ln, m, look, base, res, st)
						continue
				if v != ln.v:
					if v == ln.pend_v:
						ln.pend_n += 1
					else:
						ln.pend_v = v
						ln.pend_n = 1
						ln.pend_t = tick
					if ln.pend_n < (1 if unison else SPEED_CHECKS):
						continue
					if settle and ln.v == 0 and (tick - ln.pend_t) * v <= SETTLE_GAPS * GAP:
						continue  # (a line closing a hole: a gap on it stands again, the same picture)
					if ln.gated and ln.flow_q >= FLOW_GATE:
						ln.gated = false
					if ln.v == 0 and ln.gated:
						continue  # (creep_flow: stood for want of net flow; moves again with it)
					# (Its new speed from where it is drawn now; the map's phase at it, world. Stopping, it
					# keeps where it is drawn: the game's standing phase comes with the lane's next read or
					# check, obs; settle: it stands on the simulation's standing front at once.)
					ln.pend_n = 0
					ln.pend_v = -1
					_set_motion(ln, posmod(_world_phase(m) - v * tick, GAP) if wl and v > 0 else (posmod(f, GAP) if settle and v == 0 else pred),
						v, tick)
					_write_lane(job_state, key, ln, m, look, base, res, st)
					continue
				ln.pend_n = 0
				ln.pend_v = -1
				if settle and ln.v == 0:
					obs = f  # (the simulation's front stands on the lane: its phase, not a read's mid-way)
				if ln.v == 0 and obs >= 0:
					if posmod(obs, GAP) == ln.r0:
						continue  # (standing at the game's phase)
				elif wl:
					continue  # (the map's phase: nothing drifts)
				else:
					var off := absi(pred - posmod(f, GAP))
					if mini(off, GAP - off) <= DRIFT:
						continue
		var fresh := ln == null
		if fresh:
			if settle:
				# (Moving: drawn only once it has moved for longer than a line closing a hole does.)
				if has and v > 0:
					var since: int = moving_since.get(key, -1)
					if since < 0:
						moving_since[key] = tick
						continue
					if (tick - since) * v <= SETTLE_GAPS * GAP:
						continue
				moving_since.erase(key)
			ln = Lane.new()
			ln.item = item
			ln.kind_key = kk
			drawn[key] = ln
			undrawn.erase(key)
			_mark(job_state, key, ln, 1)
			res["added_keys"][key] = true
		var nv := 0
		var nr0 := 0
		if wl:
			nv = v if has else 0
			nr0 = posmod(_world_phase(m) - nv * tick, GAP)
		elif has:
			nr0 = posmod(f, GAP)
			nv = v
		else:
			nr0 = _world_phase(m)
		if settle and has and v == 0:
			obs = f
		if nv == 0 and obs >= 0:
			nr0 = posmod(obs, GAP)  # (standing: where the game last showed the lane's items)
		if fresh:
			ln.r0 = nr0
			ln.v = nv
			ln.t0 = tick
			_identify(job_state, sim, key, ln, m, tick)
		else:
			_set_motion(ln, nr0, nv, tick)
		_write_lane(job_state, key, ln, m, look, base, res, st)
	for kk in kinds:
		var kd: LKind = kinds[kk]
		var told := Vector3i(kd.base, kd.top, kd.cap)
		if full or told != kd.told:
			kd.told = told
			res["written"].append([kk, kd.base, kd.top, kd.cap])
	res["unknown"] = unknown.keys()
	res["pages"] = records.take_pages()
	if mask_dirty:
		mask_dirty = false
		res["mask"] = mask
	lanes_n = drawn.size()
	slots_n = 0
	for kk in kinds:
		slots_n += (kinds[kk] as LKind).top - (kinds[kk] as LKind).free.size()
	# (A lane removed and drawn again in the same update, its kind changed, neither.)
	var removed_keys: Dictionary = res["removed_keys"]
	var del := PackedInt64Array()
	for key: int in removed_keys:
		if not drawn.has(key):
			del.append(key)
	var add := PackedInt64Array()
	for key: int in res["added_keys"]:
		if not removed_keys.has(key) and drawn.has(key):
			add.append(key)
	res["removed"] = del
	res["added"] = add
	res.erase("removed_keys")
	res.erase("added_keys")
	return res


## How high a lane's piles are drawn: its last read's most common stack (1 with --belt-draw-lattice-pile=off).
func _stack_of(key: int) -> int:
	if not piles:
		return 1
	var e: Array = info.get(key, [])
	return clampi(int(e[2]), 1, MAX_STACK) if e.size() > 2 else 1


## The item a lane is drawn as a lattice of, or -1: full of one kind, of a kind drawn so, in the planned
## ground.
func _wanted(job_state, key: int, lanes: Dictionary) -> int:
	if not on:
		return -1
	var e: Array = info.get(key, [])
	if e.is_empty() or not e[0] or int(e[1]) < 0:
		return -1
	var m: PackedInt32Array = lanes.get(key, PackedInt32Array())
	if m.is_empty() or not _drawn_kind(m[0]) or m[1] <= 0 or m[1] > MAX_LENGTH:
		return -1
	if not planned_all:
		var mid: Vector2
		if mids.has(key):
			mid = mids[key]
		else:
			var p := _point(job_state, key, m[1] * 0.5)
			mid = Vector2(p.x, p.z)
			mids[key] = mid
		if not planned.has_point(mid):
			return -1
	return int(e[1])


static func _drawn_kind(kind: int) -> bool:
	return kind == BeltSim.STRAIGHT or kind == BeltSim.CURVE or kind == BeltSim.UG_VISIBLE or kind == BeltSim.SPLIT_IN \
		or kind == BeltSim.SPLIT_OUT


## Its kind key as belt_items.gd's: the item, or its icon past an Items in 3D cap.
static func _kind_key(item: int, model_cap: int) -> int:
	return item if model_cap < 0 else ItemCards.icon_key(item)


## A lane the simulation has no item on: a lattice fixed to the map along its exit's direction, so the
## lanes of a straight run agree.
static func _world_phase(m: PackedInt32Array) -> int:
	return posmod(_world_tau(m), GAP)


## Where a lane's exit is along the way its items leave (1/256 tile; the next lane's exit is a belt further).
static func _world_tau(m: PackedInt32Array) -> int:
	var dx := m[3] - m[5]
	var dy := m[4] - m[6]
	if absi(dx) >= absi(dy):
		return m[3] if dx > 0 else -m[3]
	return m[4] if dy > 0 else -m[4]


## A run's seed from the map: its lane's place across the way its items leave, and that way, so the
## lanes of one run share it and the lanes beside it (the belt's other lane, the next belt) don't.
static func _world_run(m: PackedInt32Array) -> int:
	var dx := m[3] - m[5]
	var dy := m[4] - m[6]
	if absi(dx) >= absi(dy):
		return posmod(m[4] * 4 + (0 if dx > 0 else 1), IDS)
	return posmod(m[3] * 4 + (2 if dy > 0 else 3), IDS)


## a / b rounded down (integers).
static func _fdiv(a: int, b: int) -> int:
	return (a - posmod(a, b)) / b


## A drawn lane's new motion from `tick` (its phase r0 and speed v): who its items are carries over, each
## new slot taking the nearest old item's as both are drawn when the update is (the old lattice's identity
## function at the slot's place, rounded), so a lane that starts, stops or has its phase made again keeps
## its items' turns.
## (creep) The lane's running share of the time most of its items move (lv: their speed now, step the
## belt's), and whether it creeps: starts sliding at its share of the belt's speed from where it is drawn
## (pred), changes that speed by more than a quarter, or stops creeping: below CREEP_OFF with its items
## standing it slides on until its phase meets the simulation's standing front (f) and stands there (no
## jump); moving steadily, back to the usual rules (which take the simulation's speed). True when its
## motion was set and it is to be written again.
func _creep(ln: Lane, lv: int, step: int, tick: int, pred: int, f: int) -> bool:
	if ln.flow_t >= 0 and tick > ln.flow_t:
		var dt := tick - ln.flow_t
		ln.flow_q += ((FLOW_ONE if lv > 0 else 0) - ln.flow_q) * dt / (dt + CREEP_TAU)
	ln.flow_t = tick
	if lv <= 0:
		ln.run_t = -1
	elif ln.run_t < 0:
		ln.run_t = tick
	var cv := maxi(1, (ln.flow_q * maxi(1, step) + FLOW_ONE / 2) / FLOW_ONE)
	if ln.creeping:
		if ln.run_t >= 0 and (tick - ln.run_t) * lv > CREEP_RUN_GAPS * GAP:
			ln.creeping = false
			ln.pend_v = -1
			ln.pend_n = 0
			return false
		if ln.flow_q < CREEP_OFF:
			if lv > 0:
				return false  # (its items moving now: it stops once they stand)
			if posmod(pred - f, GAP) > ln.v:
				return false  # (on to the standing front's phase)
			ln.creeping = false
			ln.pend_v = -1
			ln.pend_n = 0
			_set_motion(ln, posmod(f, GAP), 0, tick)
			return true
		if absi(cv - ln.v) * 4 > ln.v:
			_set_motion(ln, pred, cv, tick)
			return true
		return false
	if ln.v == 0 and ln.flow_q >= CREEP_ON and not (ln.run_t >= 0 and (tick - ln.run_t) * lv > SETTLE_GAPS * GAP):
		ln.creeping = true
		_set_motion(ln, pred, cv, tick)
		return true
	return false


## (creep_flow) As _creep, by the net distance its items went on past its exit (u: the simulation's front
## item on it now, lv the speed most of its items move at, step the belt's).
func _creep_flow(ln: Lane, lv: int, u: int, step: int, tick: int, _pred: int, f: int) -> bool:
	var dd := 0
	var n := ln.fu.size()
	if n == 0 or ln.fu[n - 1] != u:
		var back := -1
		for j in range(n - 2, -1, -1):
			if ln.fu[j] == u:
				back = j
				break
		if back >= 0:
			dd = -GAP * (n - 1 - back)  # (a front it had: a read put the items back)
			ln.fu.resize(back + 1)
		else:
			if n > 0:
				dd = GAP
			ln.fu.append(u)
			if ln.fu.size() > FLOW_HIST:
				ln.fu.remove_at(0)
	if ln.flow_t >= 0 and tick > ln.flow_t:
		var dt := tick - ln.flow_t
		ln.flow_q = maxi(0, ln.flow_q + _fdiv(dd * FLOW_ONE - ln.flow_q * dt, dt + CREEP_TAU))
	elif ln.flow_t < 0 or tick == ln.flow_t:
		ln.flow_q = maxi(0, ln.flow_q + _fdiv(dd * FLOW_ONE, CREEP_TAU))
	ln.flow_t = tick
	if lv <= 0:
		ln.run_t = -1
	elif ln.run_t < 0:
		ln.run_t = tick
	var cv := clampi(_fdiv(ln.flow_q + FLOW_ONE / 2, FLOW_ONE), 1, maxi(1, step))
	# (Its new motion from the drawn clock's tick, where it is drawn then: set at the simulation's tick, the
	# lattice was drawn jumping by the change of speed times the drawn clock's lag behind it.)
	var td := _t_draw(tick)
	var pd := _phase_at(ln, td)
	if ln.creeping:
		if ln.run_t >= 0 and (tick - ln.run_t) * lv > CREEP_RUN_GAPS * GAP:
			ln.creeping = false
			ln.pend_v = -1
			ln.pend_n = 0
			return false
		if ln.flow_q < CREEP_FLOW_OFF:
			if lv > 0:
				return false  # (its items moving now: it stops once they stand)
			if posmod(pd - f, GAP) > ln.v:
				return false  # (on to the standing front's phase)
			ln.creeping = false
			ln.pend_v = -1
			ln.pend_n = 0
			_set_motion(ln, posmod(f, GAP), 0, td)
			return true
		if absi(cv - ln.v) * 4 > ln.v:
			_set_motion(ln, pd, cv, td)
			return true
		return false
	if ln.v == 0 and ln.flow_q >= CREEP_FLOW_ON and not (ln.run_t >= 0 and (tick - ln.run_t) * lv > SETTLE_GAPS * GAP):
		ln.creeping = true
		_set_motion(ln, pd, cv, td)
		return true
	return false


## (creep_flow) The tick a creeping lane's new motion starts from: the drawn clock's (not before its last).
func _t_draw(tick: int) -> int:
	return drawn_tick if creep_flow and drawn_tick >= 0 and drawn_tick <= tick else tick


## A drawn lane's phase on tick t.
static func _phase_at(ln: Lane, t: int) -> int:
	return posmod(ln.r0 - ln.v * (t - ln.t0), GAP)


## (creep) A lane no longer creeping, standing at phase r0 from `tick`, its share forgotten.
func _creep_stop(ln: Lane, r0: int, tick: int) -> void:
	ln.creeping = false
	ln.pend_v = -1
	ln.pend_n = 0
	ln.flow_q = 0
	ln.flow_t = -1
	ln.run_t = -1
	ln.fu.clear()
	_set_motion(ln, r0, 0, tick)


func _set_motion(ln: Lane, r0: int, v: int, tick: int) -> void:
	ln.who = posmod(ln.who + _fdiv(r0 + ln.v * (tick - ln.t0) - ln.r0 + _lag(ln.v - v, tick) + GAP / 2, GAP), IDS)
	ln.r0 = r0
	ln.v = v
	ln.t0 = tick


## How much further (1/256) a lane at speed `dv` more than another goes between the update's tick and when it
## is drawn (`shown`), rounded: what the matching of who items are adds for the drawn clock's lag.
func _lag(dv: int, tick: int) -> int:
	return roundi(float(dv) * (shown - float(tick))) if shown >= 0.0 and dv != 0 else 0


## Who a new lane's items are (its r0, v and t0 set): the drawn lane they go on into (`next`) or the drawn
## lane they come from, its identity function carried across their meeting so an item crossing keeps its
## turn; else the map's along the exit's direction (items at the map's phase are who they were wherever
## a lane of their run was written). Notes the lane as feeding its next.
func _identify(job_state, sim, key: int, ln: Lane, m: PackedInt32Array, tick: int) -> void:
	ln.next = int(sim.next_of(key)) if sim != null else 0
	var down: Lane = drawn.get(ln.next) if ln.next != 0 and ln.next != key else null
	var dm: PackedInt32Array = job_state.lanes.get(ln.next, PackedInt32Array()) if down != null else PackedInt32Array()
	var up_key: int = feeds.get(key, 0)
	var up: Lane = drawn.get(up_key) if up_key != 0 and up_key != key else null
	if down != null and dm.size() > 1:
		# (An item at this lane's q is at the next lane's q + its length.)
		ln.who = posmod(down.who + _fdiv(dm[1] + ln.r0 + down.v * (tick - down.t0) - down.r0 + _lag(down.v - ln.v, tick)
			+ GAP / 2, GAP), IDS)
		ln.run = down.run
	elif up != null:
		# (An item at the feeding lane's q is at this lane's q + this lane's length.)
		ln.who = posmod(up.who + _fdiv(up.v * (tick - up.t0) - up.r0 - m[1] + ln.r0 + _lag(up.v - ln.v, tick) + GAP / 2, GAP), IDS)
		ln.run = up.run
	else:
		ln.who = posmod(_fdiv(ln.r0 - _world_tau(m) + ln.v * tick + GAP / 2, GAP), IDS)
		ln.run = _world_run(m)
	if ln.next != 0:
		feeds[ln.next] = key


func _remove(key: int, res: Dictionary) -> void:
	var ln: Lane = drawn[key]
	drawn.erase(key)
	if ln.next != 0 and feeds.get(ln.next, 0) == key:
		feeds.erase(ln.next)
	if res.has("removed_keys"):
		res["removed_keys"][key] = true
	var kd: LKind = kinds.get(ln.kind_key)
	for i in ln.slots.size():
		if kd != null:
			records.hide(kd.base + ln.slots[i])
			kd.free.append(ln.slots[i])
		if i % ln.stack == 0:
			res["dump_gone"].append(_uid(key, i / ln.stack))
	_unmark(ln)


static func _uid(key: int, k: int) -> int:
	return -(key * 8 + k + 1)


## The lane's slots: one record each, every GAP from its phase; sliding a gap a period, or standing.
## A moving lane's slot k cycles within its own gap of the lane, [64k, 64k + 64), so a lane's lattice
## never runs past its ends onto the next lane's (whose phase can differ): ceil(length / 64) slots, the
## last one's gap reaching past a curve's entry. A standing lane's slots stand on its phase.
## With stacks of `stack`, each slot is a pile: its record and stack - 1 copies pointing at it (written
## when placed: they follow the slot's record wherever it is written again).
func _write_lane(job_state, key: int, ln: Lane, m: PackedInt32Array, look: Array, base: float, res: Dictionary,
		stack := 1) -> void:
	var length := m[1]
	if length <= 0 or length > MAX_LENGTH:
		return
	var moving := ln.v > 0
	var n := 0
	if moving:
		n = maxi(1, ceili(float(length) / GAP))
	else:
		var q := ln.r0
		while q < length:
			n += 1
			q += GAP
	var kd: LKind = kinds.get(ln.kind_key)
	if kd == null:
		kd = LKind.new()
		kinds[ln.kind_key] = kd
	if stack != ln.stack:
		# (Its piles' height changed: every slot placed again.)
		while not ln.slots.is_empty():
			_drop_slot(key, ln, kd, res)
		ln.stack = stack
	var st := ln.stack
	while ln.slots.size() > n * st:
		_drop_slot(key, ln, kd, res)
	var placed := ln.slots.size()
	while ln.slots.size() < n * st:
		var s: int
		if not kd.free.is_empty():
			s = kd.free.pop_back()
		else:
			s = kd.top
			kd.top += 1
			if kd.top > kd.cap or kd.base < 0:
				var cap := BeltRecords.MIN_RUN
				while cap < kd.top:
					cap *= 2
				var nb := records.alloc(cap)
				if kd.base >= 0:
					records.copy(kd.base, nb, kd.cap)
					records.release(kd.base, kd.cap)
				for i in range(kd.cap, cap):
					records.hide(nb + i)
				kd.base = nb
				kd.cap = cap
		ln.slots.append(s)
	var lift: Vector3 = look[0]
	var pile_step := float(look[2]) if look.size() > 2 else 0.07
	var period := float(GAP) / float(ln.v) if moving else 0.0
	var ends := _ends(job_state, key, length)
	# (Its clock from where slot k is at 64k + r0 on tick t0: the shader's fract() starts at (64 - r0) / 64.)
	var t_start := float(ln.t0) - base
	if moving:
		t_start -= float(GAP - ln.r0) / float(GAP) * period
	# (Taken out while written: written through a second reference, the whole array was copied each lane.)
	var d := records.data
	records.data = PackedFloat32Array()
	for k in n:
		var top := float(GAP * (k + 1)) if moving else float(ln.r0 + GAP * k)
		var p := _along(job_state, key, top, length, ends)
		var to := _along(job_state, key, float(GAP * k), length, ends) if moving else p
		var uid := _uid(key, k)
		# Turned as every item is, icon cards too: by who its item is (the shader adds the periods slid and
		# hashes it with the run, ItemCards.lattice_turn), or (slot turns) by the slot (ItemCards.turn_for).
		var c := float(posmod(ln.who + k, IDS)) if item_turns else cos(ItemCards.turn_for(uid))
		var s := float(ln.run) if item_turns else sin(ItemCards.turn_for(uid))
		var r := kd.base + ln.slots[k * st]
		var o := r * BeltRecords.FLOATS
		d[o] = p.x
		d[o + 1] = p.y
		d[o + 2] = p.z
		d[o + 3] = t_start
		if period > 0.0:
			d[o + 4] = to.x - p.x
			d[o + 5] = 0.0
			d[o + 6] = to.z - p.z
		else:
			d[o + 4] = 0.0
			d[o + 5] = 0.0
			d[o + 6] = 0.0
		d[o + 7] = t_start
		d[o + 8] = c
		d[o + 9] = s
		d[o + 10] = lift.y + LAYER_STEP * (posmod(uid, LAYERS))
		d[o + 11] = 0.0 if p.w >= 0.5 else BeltRecords.HIDDEN
		d[o + 12] = 0.0
		d[o + 13] = 0.0
		d[o + 14] = 2.0 if item_turns else 1.0  # a lattice slot (not masked); 2: texel 2 says who its item is
		d[o + 15] = period
		records.dirty[r / records.per_page] = true
		# Its pile's copies, when placed: PILE_TURN more each than the slot's turn, k pile steps up, read from
		# the slot's record by the shader (slot turns: their own, texel 2).
		for j in range(1, st):
			var i := k * st + j
			if i < placed:
				continue
			var rc := kd.base + ln.slots[i]
			var oc := rc * BeltRecords.FLOATS
			for q in BeltRecords.FLOATS:
				d[oc + q] = 0.0
			if not item_turns:
				var ca := ItemCards.turn_for(uid, j)
				d[oc + 8] = cos(ca)
				d[oc + 9] = sin(ca)
			d[oc + 12] = float(r - rc)
			d[oc + 13] = float(j)
			d[oc + 14] = pile_step
			records.dirty[rc / records.per_page] = true
		if bool(res["dump_on"]):
			res["dump_ids"].append_array(PackedInt64Array([uid, ln.item, st, key, ln.r0 + GAP * k, ln.t0, ln.v, 0]))
			res["dump_recs"].append_array(d.slice(o, o + BeltRecords.FLOATS))
	records.data = d


## (--inserter-handoff) A hand took the item at line position `pos` of lane `key` on tick `at`: a drawn
## lane's lattice gets the hole it leaves (each slot's own record, texel 3 x: hidden from that tick to the
## end of its period, the shader). A moving lane's slot k cycles within its own gap, so the hole is slot k
## from the take to its wrap, then slot k - 1 for a period, and so on to the lane's exit; a standing lane's
## stays at slot k. Until the lane is written again (a new phase or speed) or given up (the bridge's read
## after the take finds it not full: drawn from the simulation, which took the item off on the same tick).
## Returns {dump_ids, dump_recs} of the slots written, with `dump` (belt_items.gd --belt-draw-dump).
func hole(key: int, at: int, pos: int, dump: bool) -> Dictionary:
	var res := {"dump_ids": PackedInt64Array(), "dump_recs": PackedFloat32Array()}
	var ln: Lane = drawn.get(key)
	if ln == null or records.base < 0.0:
		return res
	var kd: LKind = kinds.get(ln.kind_key)
	if kd == null or kd.base < 0:
		return res
	var n := ln.slots.size() / ln.stack
	if n <= 0:
		return res
	var base := records.base
	var d := records.data
	records.data = PackedFloat32Array()
	if ln.v <= 0:
		var k := roundi(float(pos - ln.r0) / float(GAP))
		if k >= 0 and k < n:
			_hole_slot(key, ln, kd, d, k, float(at) - base, res, dump)
			ln.hole_at = maxi(ln.hole_at, at)
			ln.hole_v = 0
	else:
		var period := float(GAP) / float(ln.v)
		var ts := float(ln.t0) - float(GAP - ln.r0) / float(GAP) * period
		var q := (float(at) - ts) / period
		var idx := floorf(q)
		var k := roundi((float(pos) - float(GAP) * (1.0 - (q - idx))) / float(GAP))
		for j in range(mini(k, n - 1), -1, -1):
			var h := float(at) if j == k else ts + (idx + float(k - j)) * period + 0.01
			_hole_slot(key, ln, kd, d, j, h - base, res, dump)
	records.data = d
	return res


func _hole_slot(key: int, ln: Lane, kd: LKind, d: PackedFloat32Array, k: int, h: float, res: Dictionary, dump: bool) -> void:
	var r := kd.base + ln.slots[k * ln.stack]
	var o := r * BeltRecords.FLOATS
	d[o + 12] = h
	records.dirty[r / records.per_page] = true
	if dump:
		res["dump_ids"].append_array(PackedInt64Array([_uid(key, k), ln.item, ln.stack, key, ln.r0 + GAP * k, ln.t0, ln.v, 0]))
		res["dump_recs"].append_array(d.slice(o, o + BeltRecords.FLOATS))


## The lane's last record let go (hidden, its slot free); a slot's own record's going is dumped.
func _drop_slot(key: int, ln: Lane, kd: LKind, res: Dictionary) -> void:
	var i := ln.slots.size() - 1
	var s := ln.slots[i]
	records.hide(kd.base + s)
	kd.free.append(s)
	if i % ln.stack == 0:
		res["dump_gone"].append(_uid(key, i / ln.stack))
	ln.slots.resize(i)


## A lane's exit and entry and the way items go there: [exit, direction there, entry, direction there].
static func _ends(job_state, key: int, length: int) -> Array:
	var exit := _point(job_state, key, 0.0)
	var ahead := _point(job_state, key, minf(32.0, float(length)))
	var entry := _point(job_state, key, float(length))
	var behind := _point(job_state, key, maxf(0.0, float(length) - 32.0))
	return [exit, Vector2(exit.x - ahead.x, exit.z - ahead.z).normalized(), entry,
		Vector2(behind.x - entry.x, behind.z - entry.z).normalized()]


## _point, carried on straight past either end.
static func _along(job_state, key: int, pos: float, length: int, ends: Array) -> Vector4:
	if pos < 0.0:
		var e: Vector4 = ends[0]
		var dv: Vector2 = ends[1]
		return Vector4(e.x - dv.x * pos / 256.0, e.y, e.z - dv.y * pos / 256.0, e.w)
	if pos > float(length):
		var e: Vector4 = ends[2]
		var dv: Vector2 = ends[3]
		var past := (pos - float(length)) / 256.0
		return Vector4(e.x - dv.x * past, e.y, e.z - dv.y * past, e.w)
	return _point(job_state, key, pos)


## Where line position `pos` of lane `key` is: belt_items.gd's Job._point.
static func _point(job_state, key: int, pos: float) -> Vector4:
	var m: PackedInt32Array = job_state.lanes.get(key, PackedInt32Array())
	if m.is_empty():
		return Vector4(0.0, job_state.height, 0.0, 0.0)
	var f := clampf(pos / float(maxi(m[1], 1)), 0.0, 1.0)
	var x: float
	var y: float
	if m[0] == BeltSim.CURVE and job_state.arcs.has(key) and not (job_state.arcs[key] as PackedFloat64Array).is_empty():
		var arc: PackedFloat64Array = job_state.arcs[key]
		var a := arc[3] + arc[4] * f
		x = arc[0] + cos(a) * arc[2]
		y = arc[1] + sin(a) * arc[2]
	else:
		x = lerpf(float(m[3]), float(m[7]), f)
		y = lerpf(float(m[4]), float(m[8]), f)
	return Vector4(x / 256.0, job_state.height, y / 256.0, 0.0 if m[0] == BeltSim.UG_HIDDEN else 1.0)


## The mask's cells along a lane's centre line (sampled every 1/32 tile).
func _mark(job_state, key: int, ln: Lane, _add: int) -> void:
	if mask == null:
		mask = Image.create(MASK, MASK, false, Image.FORMAT_R8)
		mask_n = PackedByteArray()
		mask_n.resize(MASK * MASK)
	var m: PackedInt32Array = job_state.lanes[key]
	var length := clampi(m[1], 0, MAX_LENGTH)
	var seen := {}
	var steps := maxi(1, length / 8)
	for j in steps + 1:
		var p := _point(job_state, key, float(length) * j / steps)
		var cx := posmod(floori(p.x * CELLS), MASK)
		var cz := posmod(floori(p.z * CELLS), MASK)
		var c := cz * MASK + cx
		if seen.has(c):
			continue
		seen[c] = true
		ln.cells.append(c)
		if mask_n[c] < 255:
			mask_n[c] += 1
		if mask_n[c] == 1:
			mask.set_pixel(cx, cz, Color(1.0, 0.0, 0.0))
			mask_dirty = true


func _unmark(ln: Lane) -> void:
	for c in ln.cells:
		if mask_n[c] > 0:
			mask_n[c] -= 1
			if mask_n[c] == 0:
				mask.set_pixel(c % MASK, c / MASK, Color(0.0, 0.0, 0.0))
				mask_dirty = true
	ln.cells = PackedInt32Array()


## Every lane given up (the lattice switched off, a reset): records hidden, the mask cleared.
func clear(res_gone: PackedInt64Array) -> void:
	var res := {"dump_gone": res_gone}
	for key: int in drawn.keys():
		_remove(key, res)
	feeds.clear()
