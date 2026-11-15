extends SceneTree
## The inserter swing model (scripts/world/inserter_swing.gd) against a hand moved as Factorio
## moves it: a half turn in ceil(0.5 / speed - 1) ticks, the item changing hands at the ends. A
## game hand is made tick by tick (chest to chest, with waits at either end, with a belt item taken
## short of the pickup point), sampled every `p` ticks at every phase, as the bridge's `ih` samples
## it, and the plans between the samples are read back at every tick: how far they are from the
## game's hand, when the item appears and vanishes against when it did, and whether the drawn swing
## reaches both ends. Fast, offline, no scene:
##
##   godot --headless --path client -s res://tests/inserter_swing_test.gd [-- --verbose]

const Swing := preload("res://scripts/world/inserter_swing.gd")

var failures := 0
var verbose := false


func check(cond: bool, what: String) -> void:
	if cond:
		print("PASS ", what)
	else:
		failures += 1
		print("FAIL ", what)


## A game hand, tick by tick: [angle, reach, item] from tick 0. It starts at the pickup, waits
## `hold_pick` ticks, takes `item` (the tick it leaves), swings to the drop, waits `hold_drop` ticks
## holding it, drops it (the tick it leaves) and swings back. `pick`/`drop`: [angle, reach]. `grab_reach`,
## when given: the pickup leg really ends there (a belt item taken short of the nominal point).
func game_hand(omega: float, v: float, pick: Array, drop: Array, hold_pick: int, hold_drop: int, item: int,
		ticks: int, grab_reach := -1.0) -> Array:
	var out := []
	var angle: float = pick[0]
	var reach: float = pick[1]
	var held := 0
	var wait := hold_pick
	var target: Array = []
	var w := omega * TAU
	var t := 0
	while t < ticks:
		if target.is_empty():
			# At an end, waiting: the item changes hands the tick it leaves.
			if wait > 0:
				out.append([angle, reach, held])
				wait -= 1
				t += 1
				continue
			if held == 0:
				held = item
				out.append([angle, reach, held])
				target = drop
			else:
				held = 0
				out.append([angle, reach, held])
				target = [pick[0], grab_reach if grab_reach > 0.0 else pick[1]]
				wait = hold_pick
			t += 1
			continue
		# A tick of the way: each part a step, snapping when within a step of the target. The ends are a
		# half circle apart: the arm sweeps over one side (here the east, angles about 0), out and back.
		var d := wrapf(target[0] - angle, -PI, PI)
		if absf(d) > PI - 1e-6:
			d = PI if held != 0 else -PI
		if absf(d) > 0.0:
			angle += signf(d) * minf(absf(d), w)
			if absf(wrapf(target[0] - angle, -PI, PI)) <= w + 1e-9:
				angle = target[0]
		var dr: float = target[1] - reach
		if absf(dr) > 0.0:
			reach += signf(dr) * minf(absf(dr), v)
			if absf(target[1] - reach) <= v + 1e-9:
				reach = target[1]
		var arrived := is_equal_approx(angle, target[0]) and is_equal_approx(reach, target[1])
		if arrived:
			# Arrived: the transfer is this tick (chest), or the wait starts (the item still in hand).
			if held != 0:
				if hold_drop > 0:
					wait = hold_drop
					out.append([angle, reach, held])
					target = []
					t += 1
					continue
				held = 0
				out.append([angle, reach, held])
				target = [pick[0], grab_reach if grab_reach > 0.0 else pick[1]]
				wait = hold_pick
			else:
				if hold_pick > 0:
					wait = hold_pick
					out.append([angle, reach, held])
					target = []
					t += 1
					continue
				held = item
				out.append([angle, reach, held])
				target = drop
		else:
			out.append([angle, reach, held])
		t += 1
	return out


## The plans from samples every `p` ticks (from `phase`) read back at every tick against the game's
## hand: {"pos_err": mean tiles, "pos_max", "item_late": mean |ticks| the item changes late (+) or
## early, "item_max", "arc": the least of each drawn swing's arc over the true half turn, "ends": whether
## every drawn reversal lies within 2 degrees of an end}.
func measure(hand: Array, p: int, phase: int, pick: Array, drop: Array, omega: float, v: float, belt_pick := false) -> Dictionary:
	# (The sweep's side: learnt from a sample clear of the ends; before one, the game's convention,
	# which here is the east, as inserter_arms.gd's default.)
	var side := 0.0
	var samples := []
	for k in range(phase, hand.size(), p):
		samples.append([k, hand[k][0], hand[k][1], hand[k][2]])
		if Swing.on_side(hand[k][0], pick, drop):
			side = hand[k][0]
	var err_sum := 0.0
	var err_max := 0.0
	var n := 0
	var drawn := []  # [angle, item] per tick from the first to the last sample
	for i in range(samples.size() - 1):
		var a: Array = samples[i]
		var b: Array = samples[i + 1]
		var keys := Swing.plan(a[0], a[1], a[2], a[3], b[0], b[1], b[2], b[3], pick, drop, omega, v, side, belt_pick, 7)
		for t in range(a[0], b[0]):
			var pose := Swing.at(keys, float(t))
			var truth: Array = hand[t]
			var e := Swing.hand_pos(pose[0], pose[1]).distance_to(Swing.hand_pos(truth[0], truth[1]))
			err_sum += e
			err_max = maxf(err_max, e)
			n += 1
			drawn.append([wrapf(pose[0], -PI, PI), pose[2], truth[2]])
	# When the item changed in the plans against when it did in the game.
	var changes_true := []
	var changes_drawn := []
	for i in range(1, drawn.size()):
		if drawn[i][2] != drawn[i - 1][2]:
			changes_true.append(i)
		if drawn[i][1] != drawn[i - 1][1]:
			changes_drawn.append(i)
	var late_sum := 0.0
	var late_max := 0.0
	var late_n := 0
	for c in changes_true:
		var best := 1e9
		for d in changes_drawn:
			if absf(d - c) < absf(best):
				best = d - c
		if best < 1e8:
			late_sum += absf(best)
			late_max = maxf(late_max, absf(best))
			late_n += 1
	# Drawn swings: between reversals of the drawn angle's motion; their arcs against the true half turn.
	var true_arc := absf(wrapf(drop[0] - pick[0], -PI, PI))
	var arc_min := 1e9
	var ends_ok := true
	var turn_at := []
	var dir := 0.0
	var start: float = drawn[0][0] if not drawn.is_empty() else 0.0
	for i in range(1, drawn.size()):
		var d: float = wrapf(drawn[i][0] - drawn[i - 1][0], -PI, PI)
		if absf(d) < 1e-6:
			continue
		var s := signf(d)
		if dir != 0.0 and s != dir:
			# (The first swing is cut short by where the samples begin: not measured.)
			if not turn_at.is_empty():
				var arc := absf(wrapf(drawn[i - 1][0] - start, -PI, PI))
				arc_min = minf(arc_min, arc / true_arc)
			var at_end := absf(wrapf(drawn[i - 1][0] - pick[0], -PI, PI)) < deg_to_rad(2.0) or absf(wrapf(drawn[i - 1][0] - drop[0], -PI, PI)) < deg_to_rad(2.0)
			ends_ok = ends_ok and at_end
			turn_at.append(rad_to_deg(drawn[i - 1][0]))
			start = drawn[i - 1][0]
		dir = s
	return {"pos_err": err_sum / maxi(n, 1), "pos_max": err_max, "item_late": late_sum / maxi(late_n, 1),
		"item_max": late_max, "item_n": late_n, "arc": arc_min if arc_min < 1e8 else 0.0, "ends": ends_ok, "turns": turn_at.size(),
		"side": side, "turn_at": turn_at.slice(0, 6)}


func _init() -> void:
	verbose = "--verbose" in OS.get_cmdline_user_args()
	# The game's cycle counts (wiki, 2.0.26): a half turn in 38 / 35 / 24 / 12 ticks; the 0.2 tile of
	# extension never the slower part; legendary (x2.5) fast inserter 4.
	check(Swing.travel_ticks(PI, 0.2, 0.013, 0.035) == 38 and Swing.travel_ticks(PI, 0.2, 0.014, 0.035) == 35
		and Swing.travel_ticks(PI, 0.2, 0.02, 0.05) == 24 and Swing.travel_ticks(PI, 0.2, 0.04, 0.1) == 12
		and Swing.travel_ticks(PI, 0.2, 0.1, 0.25) == 4 and Swing.travel_ticks(0.0, 0.2, 0.014, 0.035) == 5
		and Swing.travel_ticks(0.0, 0.0, 0.014, 0.035) == 0,
		"a half turn takes ceil(0.5 / speed - 1) ticks: 38 burner, 35 basic, 24 long, 12 fast, 4 legendary fast")
	check(Swing.travel_ticks(0.014 * TAU * 7, 0.0, 0.014, 0.035, false) == 7 and Swing.travel_ticks(0.014 * TAU * 7, 0.0, 0.014, 0.035, true) == 6,
		"a way short of an end takes a tick a step; one ending there snaps the last step")
	var sp := Swing.speeds({"rs": 0.04, "es": 0.1}, "inserter", "normal")
	var sp_q := Swing.speeds({}, "fast-inserter", "legendary")
	var sp_t := Swing.speeds({}, "nobody-inserter", "normal")
	check(sp == [0.04, 0.1] and is_equal_approx(sp_q[0], 0.1) and is_equal_approx(sp_q[1], 0.25) and sp_t == Swing.DEFAULT_SPEEDS,
		"speeds come from eprops, else the table, times the quality's multiplier")
	# The way round: the short way, or when it is nearly a half circle the way over the sweep's side.
	check(is_equal_approx(Swing.delta(0.0, PI / 2.0, NAN), PI / 2.0) and Swing.delta(0.0, PI, PI / 2.0) > 0.0
		and Swing.delta(0.0, PI, -PI / 2.0) < 0.0 and Swing.delta(PI, 0.0, PI / 2.0) < 0.0,
		"a half-circle turn goes over the sweep's side; shorter turns the short way")

	# Chest to chest: pickup north (angle -90 degrees, reach 1), drop south (reach 1.2), over the east side.
	var pick := [-PI / 2.0, 1.0]
	var drop := [PI / 2.0, 1.2]
	var kinds := {"inserter": [0.014, 0.035], "fast-inserter": [0.04, 0.1], "long-handed-inserter": [0.02, 0.05], "burner-inserter": [0.013, 0.035]}
	var long_pick := [-PI / 2.0, 2.0]
	var long_drop := [PI / 2.0, 2.2]
	for name in kinds:
		var omega: float = kinds[name][0]
		var v: float = kinds[name][1]
		var pk := long_pick if name == "long-handed-inserter" else pick
		var dp := long_drop if name == "long-handed-inserter" else drop
		for holds in [[0, 0], [10, 4], [40, 0]]:
			var hand := game_hand(omega, v, pk, dp, holds[0], holds[1], 7, 1800)
			var worst := {}
			for p in [6, 12]:
				for phase in p:
					var m := measure(hand, p, phase, pk, dp, omega, v)
					for key in m:
						if m[key] is float:
							worst[key] = maxf(float(worst.get(key, -1e9)), float(m[key])) if key != "arc" else minf(float(worst.get(key, 1e9)), float(m[key]))
						elif m[key] is bool:
							worst[key] = bool(worst.get(key, true)) and bool(m[key])
					if verbose:
						print("  %s holds %s p %d phase %d: %s" % [name, holds, p, phase, m])
				var tag := "%s (holds %d/%d, p %d)" % [name, holds[0], holds[1], p]
				# The plans follow the game's hand to within a few hundredths of a tile on average (a
				# sample on each side of every tick), the item changes hands within a tick of when it did,
				# every drawn swing covers the whole half turn and turns round at the ends.
				check(worst["pos_err"] < 0.03 and worst["pos_max"] < 0.3,
					"%s: the planned hand is within 0.03 tile of the game's on average, 0.3 at most (%.3f / %.3f)" % [tag, worst["pos_err"], worst["pos_max"]])
				check(worst["item_max"] <= 1.0, "%s: the item changes hands within a tick of the game (%.1f at most)" % [tag, worst["item_max"]])
				check(worst["arc"] > 0.99 and worst["ends"], "%s: every drawn swing covers the half turn and turns at the ends (arc %.3f, ends %s)" % [tag, worst["arc"], worst["ends"]])
				worst.clear()

	# A belt item taken short of the pickup point (the hand chased it to reach 0.75): the plans turn
	# round where the time allows, near where the game did, and the item still appears within a tick.
	var omega := 0.014
	var v := 0.035
	var hand_belt := game_hand(omega, v, pick, drop, 0, 0, 7, 1500, 0.75)
	var worst_err := 0.0
	var worst_item := 0.0
	var worst_arc := 1e9
	for phase in 6:
		var m := measure(hand_belt, 6, phase, pick, drop, omega, v, true)
		worst_err = maxf(worst_err, m["pos_err"])
		worst_item = maxf(worst_item, m["item_max"])
		worst_arc = minf(worst_arc, m["arc"])
		if verbose:
			print("  belt pickup short of the end, phase %d: %s" % [phase, m])
	check(worst_err < 0.05 and worst_item <= 1.0 and worst_arc > 0.95,
		"a belt item taken short of the pickup point: the hand turns round near where the game did (mean error %.3f, item within %.0f ticks, arc %.3f)" % [worst_err, worst_item, worst_arc])

	# Past the newest sample the hand goes on to the end it is bound for and waits there; one that stood
	# still stays.
	var e1 := Swing.extrapolate(0.0, 1.0, 7, false, pick, drop, omega, v, PI * 0.0, 5.0)
	var e2 := Swing.extrapolate(0.0, 1.0, 7, false, pick, drop, omega, v, 0.0, 100.0)
	var e3 := Swing.extrapolate(0.0, 1.0, 0, true, pick, drop, omega, v, 0.0, 100.0)
	check(is_equal_approx(e1[0], 5.0 * omega * TAU) and is_equal_approx(e1[1], 1.0 + 5.0 * v) and is_equal_approx(e2[0], PI / 2.0)
		and is_equal_approx(e2[1], 1.2) and e3[0] == 0.0 and e3[1] == 1.0,
		"extrapolation: on to the drop at its speeds (%.3f, %.3f after 5 ticks), waiting there (%.3f, %.3f); a still hand stays" % [e1[0], e1[1], e2[0], e2[1]])
	# A plan read back at its sample ticks gives the samples themselves (no jumps between plans).
	var keys := Swing.plan(100.0, -1.2, 1.0, 0, 106.0, -0.9, 1.05, 0, pick, drop, omega, v, 0.0)
	var p0 := Swing.at(keys, 100.0)
	var p1 := Swing.at(keys, 106.0)
	check(is_equal_approx(p0[0], -1.2) and is_equal_approx(p0[1], 1.0) and is_equal_approx(wrapf(p1[0], -PI, PI), -0.9) and is_equal_approx(p1[1], 1.05),
		"a plan passes through both its samples")

	print("inserter_swing_test: %s (%d failure(s))" % ["PASS" if failures == 0 else "FAIL", failures])
	quit(1 if failures > 0 else 0)
