extends RefCounted
## An inserter hand's swing between two samples of it, as Factorio moves it: the hand turns about its
## base at `rotation_speed` turns a tick and its reach changes at `extension_speed` tiles a tick, both
## at once, each at a constant speed until it is there, and the last step may be up to twice as long
## (a half turn takes ceil(0.5 / speed - 1) ticks: 35 for a basic inserter, 12 for a fast one, the
## counts the game shows). The hand only ever stops at its two ends, the pickup and the drop point
## (waiting for an item or for room), and the held item changes hands there. So from two samples of
## the hand (tick, angle, reach, held item) and the two end poses, where it was in between follows:
## a straight leg, a wait at an end then the leg (or the leg then the wait), or a visit to an end
## between them when the item changed. Near a belt the hand chases the item it takes and takes it
## short of the nominal pickup point, so when the samples say it couldn't have reached the end and
## come back in time, it turns round as far along the way as the time allows instead.
##
## A plan is keyframes [tick, angle, reach, item] with the hand moving straight between them (the
## angle unwrapped, so a plain lerp follows the sweep); `at` gives the pose at any tick of it.
## Pure functions: inserter_arms.gd uses them, tests/inserter_swing_test.gd checks them.

## A hand this close (tiles) to an end pose is at that end.
const END_NEAR := 0.35
## A hand that moved less than this (tiles) between two samples stood still.
const STILL := 0.02
## A turn longer than this (radians) is nearly a half circle either way: the sweep's side decides.
const AMBIGUOUS := 2.88  # 165 degrees
## A sample further than this (radians) from both end angles is on the sweep's side.
const SIDE_CLEAR := 0.44  # 25 degrees
## The base game's hand speeds by prototype name, when the bridge's `eprops` didn't say:
## [rotation, turns a tick; extension, tiles a tick] (data/base and space-age entities.lua).
const SPEEDS := {
	"burner-inserter": [0.013, 0.035], "inserter": [0.014, 0.035], "long-handed-inserter": [0.02, 0.05],
	"fast-inserter": [0.04, 0.1], "bulk-inserter": [0.04, 0.1], "stack-inserter": [0.04, 0.1],
}
const DEFAULT_SPEEDS := [0.014, 0.035]
## How much longer than the samples' gap the way to an end and back may take at the hand's speeds
## and still count as having reached it (the sampled point is the item as drawn, lifted mid-swing,
## so a turn about the base runs faster than the rotation speed): 1.6 fits; 1 is strict (tests).
static var reach_slack := 1.6
## Quality's inserter_speed_multiplier (1 + 0.3 x level; legendary is level 5).
const QUALITY_SPEED := {"uncommon": 1.3, "rare": 1.6, "epic": 1.9, "legendary": 2.5}


## The hand speeds of an inserter: `x` its prototype's `eprops` overlay (rs, es when the bridge sent
## them), `proto_name` for the table, `quality` its quality's name. [turns a tick, tiles a tick].
static func speeds(x: Dictionary, proto_name: String, quality: String) -> Array:
	var out: Array
	if x.has("rs") and x.has("es") and float(x["rs"]) > 0.0 and float(x["es"]) > 0.0:
		out = [float(x["rs"]), float(x["es"])]
	else:
		out = (SPEEDS.get(proto_name, DEFAULT_SPEEDS) as Array).duplicate()
	var q: float = QUALITY_SPEED.get(quality, 1.0)
	return [out[0] * q, out[1] * q]


## Ticks the hand takes to turn `d_angle` radians and change its reach by `d_reach` tiles, at `omega`
## turns a tick and `v` tiles a tick: both at once, the slower decides. A part that ends at its
## target (`complete_rot`, `complete_ext`) snaps the last step when it is within one of it, so that
## step may be up to twice the speed: ceil(way / speed - 1), as the game's cycle counts say; a part
## that ends short of its target takes ceil(way / speed). 0 for no way, else at least 1.
static func travel_ticks(d_angle: float, d_reach: float, omega: float, v: float, complete_rot := true, complete_ext := true) -> int:
	return maxi(_part_ticks(absf(d_angle), omega * TAU, complete_rot), _part_ticks(absf(d_reach), v, complete_ext))


## Ticks one part (a turn or a stretch of `way`) takes at `speed` a tick; any way at all takes a tick.
static func _part_ticks(way: float, speed: float, complete: bool) -> int:
	if way <= 1e-9 or speed <= 0.0:
		return 0
	return maxi(1, ceili(way / speed - (1.0 if complete else 0.0) - 1e-6))


## Where one part is `j` ticks into its way from `from` to `to` at `speed` a tick: a step a tick,
## there once it is (the snap takes it the rest of the way at its last step).
static func _part_at(from: float, to: float, speed: float, j: float) -> float:
	var d := to - from
	return from + signf(d) * minf(absf(d), j * speed)


## Keyframes of one leg from (k0: a0, r0) to (k1: a1, r1), the hand holding `item` (the first keyframe,
## k0's, is the caller's; `end_item`, when given, is what it holds from k1). `complete`: the leg ends at an end pose, so its turn snaps its last step
## (a keyframe the tick before, as far as the steps got); else the turn is a step a tick to k1. The
## stretch always ends at its target within the leg (a fast inserter stretches its 0.2 tile in a tick
## of its 12-tick turn), so it gets a keyframe where it is done and the turn goes on alone.
static func leg(k0: float, a0: float, r0: float, k1: float, a1: float, r1: float, item: int, omega: float, v: float, complete: bool, end_item := -1) -> Array:
	var span := k1 - k0
	var w := omega * TAU
	var out := []
	if span > 1.0:
		var t_ext := _part_ticks(absf(r1 - r0), v, true)
		var t_rot := _part_ticks(absf(a1 - a0), w, true) if complete else int(span)
		var marks := []
		if t_ext > 0 and t_ext < span:
			marks.append(t_ext)
		if complete and t_rot >= 2 and t_rot - 1 < span and not marks.has(t_rot - 1):
			marks.append(t_rot - 1)
		marks.sort()
		for j in marks:
			var a := a1 if complete and j >= t_rot else (_part_at(a0, a1, w, j) if complete else lerpf(a0, a1, j / span))
			var r := r1 if j >= t_ext else _part_at(r0, r1, v, j)
			out.append([k0 + j, a, r, item])
	out.append([k1, a1, r1, item if end_item < 0 else end_item])
	return out


static func hand_pos(angle: float, reach: float) -> Vector2:
	return Vector2(cos(angle), sin(angle)) * reach


## Whether the pose is within `tol` tiles of the end pose `e` ([angle, reach]; [] unknown): END_NEAR,
## the end's zone (a hand chasing belt items parks anywhere in it); STILL, parked at the point itself.
static func near(angle: float, reach: float, e: Array, tol := END_NEAR) -> bool:
	return not e.is_empty() and hand_pos(angle, reach).distance_to(hand_pos(e[0], e[1])) < tol


## The signed turn from `from` to `to` (radians): the short way, unless that is longer than
## `ambiguous` (nearly a half circle), when the way whose middle is nearer `side` (the angle of the
## sweep's side; NAN unknown) is taken.
static func delta(from: float, to: float, side: float, ambiguous := AMBIGUOUS) -> float:
	var d := wrapf(to - from, -PI, PI)
	if absf(d) > ambiguous and not is_nan(side):
		var other := d - signf(d) * TAU if d != 0.0 else TAU
		var mid_short := wrapf(from + d * 0.5 - side, -PI, PI)
		var mid_other := wrapf(from + other * 0.5 - side, -PI, PI)
		if absf(mid_other) < absf(mid_short):
			return other
	return d


## Whether a sample at this angle is clear of both end angles: on the sweep's side.
static func on_side(angle: float, pick: Array, drop: Array) -> bool:
	if pick.is_empty() or drop.is_empty():
		return false
	return absf(wrapf(angle - pick[0], -PI, PI)) > SIDE_CLEAR and absf(wrapf(angle - drop[0], -PI, PI)) > SIDE_CLEAR


## Keyframes [tick, angle, reach, item] from sample A (tick `ka`, angle `aa`, reach `ra`, item `ia`)
## to sample B, given the end poses `pick` and `drop` ([angle, reach], [] unknown), the speeds
## (`omega` turns a tick, `v` tiles a tick) and the sweep's `side` (an angle on it, NAN unknown).
## `belt_pick`: it takes from a belt, where the hand chases items about the pickup point and takes
## them where they are. `last_item`: what the hand held last, for a carry the samples missed. The
## angles are unwrapped from `aa` (a plain lerp between keyframes follows the hand's way round).
static func plan(ka: float, aa: float, ra: float, ia: int, kb: float, ab: float, rb: float, ib: int,
		pick: Array, drop: Array, omega: float, v: float, side: float, belt_pick := false, last_item := 0) -> Array:
	var dt := kb - ka
	if dt <= 0.0:
		return [[ka, aa, ra, ib]]
	var moved := hand_pos(aa, ra).distance_to(hand_pos(ab, rb))
	var changed := ia != ib
	var ab_u := aa + delta(aa, ab, side)  # B's angle, unwrapped from A's
	var out := [[ka, aa, ra, ia]]
	if moved < STILL:
		# Stood still: waiting at an end. An item that changed hands did so the tick of sample B: the
		# hand leaves the tick after it takes or drops (a hand that had left would have moved).
		out.append([kb, ab_u, rb, ib])
		return out
	if changed:
		# The hand took (ib != 0) or dropped (ib == 0) between the samples: it visited that end. Taking
		# from a belt, a sample in the pickup's zone is where it did so (an item chased and taken where
		# it was); chests, machines and drops are at the point itself.
		var e: Array = pick if ib != 0 else drop
		var other: Array = drop if ib != 0 else pick
		if e.is_empty():
			out.append([ka + dt * 0.5, lerpf(aa, ab_u, 0.5), lerpf(ra, rb, 0.5), ib])
			out.append([kb, ab_u, rb, ib])
			return out
		if belt_pick and ib != 0 and not pick.is_empty() and not drop.is_empty():
			# Taking from a belt: the hand went for the item, took it where it met it (short of the
			# nominal point, on either lane) and turned for the drop at once. On its way there and
			# back it turns a step a tick, so the tick it turned follows from the angles alone; the
			# reach it took at, from B's reach back along the way to the drop's.
			var w := omega * TAU
			var dirn := signf(delta(pick[0], drop[0], side))
			var tg := roundf((ka + kb) * 0.5 - dirn * (ab_u - aa) / (2.0 * w))
			var to_nominal := absf(delta(aa, pick[0], side))
			if tg >= ka and tg <= kb and (tg - ka) * w <= to_nominal + 0.5 * w:
				var ag := aa - dirn * w * (tg - ka)
				var back := (kb - tg) * v
				var rg := clampf(pick[1], drop[1] - back - v, drop[1]) if absf(rb - drop[1]) < 1e-4 else rb - signf(drop[1] - rb) * back
				if absf(rg - pick[1]) <= 0.6:
					var parked := near(ab, rb, drop, STILL)
					if tg > ka:
						out.append_array(leg(ka, aa, ra, tg, ag, rg, ia, omega, v, false, ib))
					else:
						out[0][3] = ib
					if kb > tg:
						out.append_array(leg(tg, ag, rg, kb, ab_u, rb, ib, omega, v, parked))
					return out
		var d1 := delta(aa, e[0], side)
		var ae_u := aa + d1
		var d2 := delta(e[0], ab, side)
		var b_parked := near(ab, rb, other, STILL)
		var t1 := travel_ticks(d1, e[1] - ra, omega, v)
		var t2 := travel_ticks(d2, rb - e[1], omega, v, b_parked, b_parked or (not other.is_empty() and absf(rb - other[1]) < 1e-4))
		if t1 + t2 <= dt:
			var ta := ka + t1
			var tl := kb - t2
			# The item changes hands when the hand leaves the end: it waited there for the item or for
			# room, and a hand that needn't wait takes or drops as it arrives (ta == tl: one keyframe).
			if t1 > 0:
				out.append_array(leg(ka, aa, ra, ta, ae_u, e[1], ia, omega, v, true, ia if tl > ta else ib))
			if tl > ta:
				out.append([tl, ae_u, e[1], ib])
			if t2 > 0:
				out.append_array(leg(tl, ae_u, e[1], kb, ae_u + d2, rb, ib, omega, v, b_parked))
			return out
		# Too far to reach the end and come back in time at its speeds. The hand's sampled point is
		# the held item as the game draws it, lifted in the middle of a swing, so a leg's turn about
		# the base runs up to a third faster than the rotation speed: when the way there and back
		# would fit in half again as long, it did reach the end, both legs quicker in the same ratio.
		var tm := ka + dt * (float(t1) / float(t1 + t2)) if t1 + t2 > 0 else ka + dt * 0.5
		if t1 + t2 <= dt * reach_slack + 1.0:
			out.append_array(leg(ka, aa, ra, tm, ae_u, e[1], ia, omega, v, false, ib))
			out.append_array(leg(tm, ae_u, e[1], kb, ae_u + d2, rb, ib, omega, v, false))
			return out
		# Else it turned round short of the end. Taking from a belt, it took the item where it met it
		# on its way: the latest tick on the way to the end from which the hand still reaches B in
		# time. Else (a slower hand, an end off its nominal point) as far along the way as the time
		# allows, in the same ratio.
		if belt_pick and ib != 0:
			var j := int(dt) - 1
			while j >= 1:
				var aj := _part_at(aa, ae_u, omega * TAU, j)
				var rj := _part_at(ra, e[1], v, j)
				if travel_ticks(delta(wrapf(aj, -PI, PI), ab, side), rb - rj, omega, v, b_parked, b_parked) <= dt - j:
					break
				j -= 1
			tm = ka + maxi(j, 1)
		var way := tm - ka
		var am := _part_at(aa, ae_u, omega * TAU, way)
		var rm := _part_at(ra, e[1], v, way)
		out.append_array(leg(ka, aa, ra, tm, am, rm, ib, omega, v, false))
		out.append_array(leg(tm, am, rm, kb, am + delta(wrapf(am, -PI, PI), ab, side), rb, ib, omega, v, b_parked))
		return out
	# The same item state at both ends of a half turn: an empty hand at the pickup, then at the drop,
	# carried something in between (a hand this fast has a whole leg between samples); a full one
	# at the drop, then at the pickup, dropped and took again. The item changes hands as it leaves A
	# and as it arrives at B.
	if near(aa, ra, pick) and near(ab, rb, drop) and ia == 0 or near(aa, ra, drop) and near(ab, rb, pick) and ia != 0:
		var t_leg := travel_ticks(ab_u - aa, rb - ra, omega, v)
		var tl := maxf(ka, kb - t_leg)
		var carried := last_item if ia == 0 else 0
		if tl > ka:
			out.append([tl, aa, ra, carried])
		else:
			out[0][3] = carried
		out.append_array(leg(tl, aa, ra, kb, ab_u, rb, carried, omega, v, true))
		out.append([kb, ab_u, rb, ib])
		return out
	# One leg, or a wait at an end and the leg: the way takes `t_ab` ticks of the `dt`. The leg is
	# bound for the end the held item says (the drop with one, else the pickup).
	var bound: Array = drop if ib != 0 else pick
	var a_zone := near(aa, ra, pick) or near(aa, ra, drop)
	var b_zone := near(ab, rb, pick) or near(ab, rb, drop)
	var b_parked := near(ab, rb, bound, STILL)
	var t_ab := travel_ticks(ab_u - aa, rb - ra, omega, v, b_parked, b_parked or (not bound.is_empty() and absf(rb - bound[1]) < 1e-4))
	if t_ab >= dt - 0.5:
		out.append_array(leg(ka, aa, ra, kb, ab_u, rb, ib, omega, v, b_parked))
		return out
	var w := dt - t_ab
	if a_zone and not b_zone:
		# Waited at its end (for an item, for room), then left.
		out.append([ka + w, aa, ra, ia])
		out.append_array(leg(ka + w, aa, ra, kb, ab_u, rb, ib, omega, v, b_parked))
		return out
	if b_parked:
		# Arrived at the end it was bound for and waits there.
		out.append_array(leg(ka, aa, ra, ka + t_ab, ab_u, rb, ib, omega, v, true))
		out.append([kb, ab_u, rb, ib])
		return out
	# Slower than its speeds say (low power; chasing an item about the pickup): as sampled.
	out.append_array(leg(ka, aa, ra, kb, ab_u, rb, ib, omega, v, false))
	return out


## The pose [angle, reach, item] a plan gives at tick `t`: straight between its keyframes, held at
## its ends; the item is the last keyframe's at or before `t`.
static func at(keys: Array, t: float) -> Array:
	var first: Array = keys[0]
	if t <= first[0]:
		return [first[1], first[2], first[3]]
	for i in range(1, keys.size()):
		var k1: Array = keys[i]
		if t <= k1[0]:
			var k0: Array = keys[i - 1]
			var u: float = (t - k0[0]) / (k1[0] - k0[0]) if k1[0] > k0[0] else 1.0
			return [lerpf(k0[1], k1[1], u), lerpf(k0[2], k1[2], u), k1[3] if t >= k1[0] else k0[3]]
	var last: Array = keys[keys.size() - 1]
	return [last[1], last[2], last[3]]


## Event kinds (the bridge's `ie`, docs/PROTOCOL.md): the hand took (count rose), dropped (count
## fell), its status changed, its position was read (a resync, or a probe mid-swing), it is gone.
enum Ev { PICKED = 1, DROPPED = 2, STATUS = 3, SYNC = 4, GONE = 5 }
## Status codes (`ie` STATUS and SYNC records): working, waiting for items, for room, for more
## items (a stack inserter's hand filling), low power, no power or fuel, frozen, disabled, waiting
## for something else, other. A hand under one of SLOW doesn't move as its speeds say: it is drawn
## from its positions (the samples) instead.
enum Code { WORKING = 0, SOURCE = 1, SPACE = 2, MORE = 3, LOW = 4, NO_POWER = 5, FROZEN = 6, DISABLED = 7, WAIT = 8, OTHER = 9 }
const SLOW := {Code.LOW: true, Code.NO_POWER: true, Code.FROZEN: true, Code.DISABLED: true}


## Keyframes [tick, angle, reach, item] from event `e0` to event `e1` (or on past `e0` when `e1` is
## empty), each event [tick, kind, count, item, angle, reach, status code] with its hand's pose about
## the base (angle NAN: not known; the end it is bound for stands in). The hand holding something is
## bound for the drop, empty for the pickup, at its speeds; it arrives and waits there until the next
## event, and when the next event is that end's (a drop holding, a pick empty) its pose is the end:
## the exact point the item changed hands (a belt item taken where it was, a drop on the far lane).
## An empty hand bound for a belt pickup goes to the nominal point, waits, and reaches for the item
## it takes over the last ticks (the game's hand chases it). A hand taking several (bulk, stack) or
## dropping one by one stays about where it is between those events. A hand at the end it is bound
## for whose status says it waits (for items, for room, for more items, for a train...) holds there
## until the next event.
## A position read mid-way (a sync, a status) is reached straight. Later than the speeds allow (a
## prediction out), the leg ends at the event all the same. The item is the event's from its tick.
## With the sweep's `side` known, any turn longer than a quarter circle goes over it (a belt item
## taken off the axis makes the half circle a little shorter one way, and the game's hand doesn't
## take that way for it: the owner's save).
static func plan_events(e0: Array, e1: Array, pick: Array, drop: Array, omega: float, v: float, side: float) -> Array:
	var k0: float = e0[0]
	var kind0: int = e0[1]
	var c0: int = e0[2]
	var item0: int = e0[3] if c0 > 0 else 0
	var holding := c0 > 0
	var bound: Array = drop if holding else pick
	var a0: float = e0[4]
	var r0: float = e0[5]
	var code0: int = e0[6] if e0.size() > 6 else Code.WORKING
	var amb := AMBIGUOUS if is_nan(side) else PI * 0.5
	if is_nan(a0):
		if bound.is_empty():
			return [[k0, 0.0, 1.0, item0]]
		a0 = bound[0]
		r0 = bound[1]
	var out := [[k0, a0, r0, item0]]
	if code0 != Code.WORKING and not SLOW.has(code0) and near(a0, r0, bound, 0.7):
		# Waiting at the end it is bound for (the status says: its destination full, no item yet):
		# where it is, until the next event.
		if not e1.is_empty():
			out.append([e1[0], a0, r0, item0])
		return out
	if e1.is_empty():
		# Nothing said since: on to the end it is bound for, and waiting there.
		if bound.is_empty() or near(a0, r0, bound):
			return out
		var d := delta(a0, bound[0], side, amb)
		out.append_array(leg(k0, a0, r0, k0 + travel_ticks(d, bound[1] - r0, omega, v), a0 + d, bound[1], item0, omega, v, true))
		return out
	var k1: float = e1[0]
	var kind1: int = e1[1]
	var c1: int = e1[2]
	var a1: float = e1[4]
	var r1: float = e1[5]
	if k1 <= k0:
		return out
	var known1 := not is_nan(a1)
	var arrival := holding and kind1 == Ev.DROPPED or not holding and kind1 == Ev.PICKED
	if holding and kind1 == Ev.PICKED and c1 > c0 or holding and kind0 == Ev.DROPPED and kind1 == Ev.DROPPED:
		# Collecting more at the pickup, or dropping one by one at the drop: about where it is.
		out.append([k1, a0 + (delta(a0, a1, side, amb) if known1 else 0.0), r1 if known1 else r0, item0])
		return out
	var target: Array
	if arrival and known1:
		target = [a1, r1]
	elif not bound.is_empty():
		target = bound
	elif known1:
		target = [a1, r1]
	else:
		out.append([k1, a0, r0, item0])
		return out
	if not holding and arrival and known1 and not pick.is_empty() and not near(a1, r1, pick, STILL) and near(a1, r1, pick, 1.0):
		# A belt pickup: to the nominal point first, then to the item where it takes it.
		var d1 := delta(a0, pick[0], side, amb)
		var t1 := travel_ticks(d1, pick[1] - r0, omega, v)
		var ap := a0 + d1
		var d2 := delta(pick[0], a1, side, amb)
		var tc := travel_ticks(d2, r1 - pick[1], omega, v, false, false)
		if k0 + t1 + tc <= k1:
			if t1 > 0:
				out.append_array(leg(k0, a0, r0, k0 + t1, ap, pick[1], item0, omega, v, true))
			if k1 - tc > k0 + t1:
				out.append([k1 - tc, ap, pick[1], item0])
			out.append_array(leg(k1 - tc, ap, pick[1], k1, ap + d2, r1, item0, omega, v, false))
			return out
	if not arrival and known1 and not near(a1, r1, target):
		# A position read on the way: straight to it.
		out.append_array(leg(k0, a0, r0, k1, a0 + delta(a0, a1, side, amb), r1, item0, omega, v, false))
		return out
	var d := delta(a0, target[0], side, amb)
	var t := travel_ticks(d, target[1] - r0, omega, v)
	if t == 0:
		out.append([k1, a0, r0, item0])
	elif k0 + t < k1:
		out.append_array(leg(k0, a0, r0, k0 + t, a0 + d, target[1], item0, omega, v, true))
		out.append([k1, a0 + d, target[1], item0])
	else:
		out.append_array(leg(k0, a0, r0, k1, a0 + d, target[1], item0, omega, v, true))
	return out


## Where the hand is `ticks` after its newest sample (angle `an`, reach `rn`, holding `item`), when
## no sample says: on its way to the end it is bound for (the drop holding something, else the
## pickup) at its speeds, then waiting there. A hand that stood still over its last two samples
## (`still`) stays. [angle, reach, item].
static func extrapolate(an: float, rn: float, item: int, still: bool, pick: Array, drop: Array,
		omega: float, v: float, side: float, ticks: float) -> Array:
	var e: Array = drop if item != 0 else pick
	if still or e.is_empty() or ticks <= 0.0 or near(an, rn, e):
		return [an, rn, item]
	var d := delta(an, e[0], side)
	return [_part_at(an, an + d, omega * TAU, ticks), _part_at(rn, e[1], v, ticks), item]
