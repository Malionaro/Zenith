extends SceneTree
## The swing model (scripts/world/inserter_swing.gd) against the game: a bridge hand trace
## (/f3d-ih trace: every hand near the focus each tick, tools/inserter_check.py) is sampled as `ih`
## samples it (every --period ticks on the --phase, 6 and 3 by default), the plans between the
## samples are read back at every tick as inserter_arms.gd would draw them and compared with the
## game's hand of that tick: the error in tiles while the hand moves, by kind; how far the planned
## hand is from the game's at each of its turns (does the drawn swing reach the ends?); whether the
## item is in the planned hand when it is in the game's. Offline, no live run:
##
##   godot --headless --path client -s res://tests/inserter_swing_replay.gd -- --trace=<f3d-ih-trace.jsonl>
##       [--period=6] [--phase=3] [--kind=fast-inserter] [--slack=1.6 (inserter_swing.gd reach_slack)]

const Swing := preload("res://scripts/world/inserter_swing.gd")

const BELT_TYPES := ["transport-belt", "underground-belt", "linked-belt", "splitter", "lane-splitter", "loader", "loader-1x1"]


class Ins:
	var meta: Dictionary
	var ticks := PackedInt64Array()
	var hands := []  # [x, y, count, item]


func _init() -> void:
	var path := ""
	var period := 6
	var phase := 3
	var only := ""
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--trace="):
			path = a.substr(8)
		elif a.begins_with("--period="):
			period = int(a.substr(9))
		elif a.begins_with("--phase="):
			phase = int(a.substr(8))
		elif a.begins_with("--kind="):
			only = a.substr(7)
		elif a.begins_with("--slack="):
			Swing.reach_slack = float(a.substr(8))
	if path == "":
		print("usage: --trace=<f3d-ih-trace.jsonl>")
		quit(2)
		return
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		print("can't read ", path)
		quit(2)
		return
	var ins := {}
	while not f.eof_reached():
		var line := f.get_line().strip_edges()
		if line == "":
			continue
		var v = JSON.parse_string(line)
		if v is Dictionary and v.has("u"):
			var i := Ins.new()
			i.meta = v
			ins[int(v["u"])] = i
		elif v is Array and v.size() > 6:
			var t := int(v[0])
			var j := 1
			while j + 5 < v.size():
				var u := int(v[j])
				var i: Ins = ins.get(u)
				if i != null:
					i.ticks.append(t)
					i.hands.append([float(v[j + 1]) / 256.0, float(v[j + 2]) / 256.0, int(v[j + 3]), int(v[j + 4])])
				j += 6
	var err_by_kind := {}
	var turn_by_kind := {}
	var item_ok := {}
	var n_ins := 0
	for u in ins:
		var i: Ins = ins[u]
		var m := i.meta
		var kind := str(m.get("n", "?"))
		if only != "" and kind != only:
			continue
		if i.ticks.size() < 20 or not m.has("pp"):
			continue
		var base := Vector2(float(m["x"]), float(m["y"]))
		var pick_rel := Vector2(float(m["pp"][0]), float(m["pp"][1])) - base
		var drop_rel := Vector2(float(m["dp"][0]), float(m["dp"][1])) - base
		var pick := [pick_rel.angle(), pick_rel.length()]
		var drop := [drop_rel.angle(), drop_rel.length()]
		var omega := float(m.get("rs", 0.014))
		var v := float(m.get("es", 0.035))
		var belt_pick := BELT_TYPES.has(str(m.get("pt", "")))
		# The samples, as `ih` takes them.
		var sk := PackedFloat64Array()
		var sa := PackedFloat32Array()
		var sr := PackedFloat32Array()
		var si := PackedInt32Array()
		var side := NAN
		var last_item := 0
		for j in i.ticks.size():
			if i.ticks[j] % period != phase:
				continue
			var h: Array = i.hands[j]
			var rel := Vector2(h[0], h[1]) - base
			sk.append(float(i.ticks[j]))
			sa.append(rel.angle())
			sr.append(rel.length())
			si.append(h[3])
		if sk.size() < 3:
			continue
		var moving := false
		for j in range(1, i.hands.size()):
			if Vector2(i.hands[j][0], i.hands[j][1]).distance_to(Vector2(i.hands[j - 1][0], i.hands[j - 1][1])) > 0.02:
				moving = true
				break
		if not moving:
			continue
		n_ins += 1
		# Plans between samples, read at every tick, as the arms layer does (side learnt as it goes).
		var errs: Array = err_by_kind.get(kind, [])
		var turns: Array = turn_by_kind.get(kind, [])
		var ok: Array = item_ok.get(kind, [0, 0])
		var by_tick := {}
		for j in i.ticks.size():
			by_tick[i.ticks[j]] = i.hands[j]
		var planned := {}  # tick -> [angle, reach, item]
		for s in range(sk.size() - 1):
			if si[s] != 0:
				last_item = si[s]
			if Swing.on_side(sa[s], pick, drop):
				side = sa[s]
			var keys := Swing.plan(sk[s], sa[s], sr[s], si[s], sk[s + 1], sa[s + 1], sr[s + 1], si[s + 1], pick, drop, omega, v, side, belt_pick, last_item)
			if is_nan(side) and keys.size() >= 2 and absf(keys[keys.size() - 1][1] - keys[0][1]) > Swing.AMBIGUOUS:
				side = wrapf((keys[0][1] + keys[keys.size() - 1][1]) * 0.5, -PI, PI)
			for t in range(int(sk[s]), int(sk[s + 1])):
				planned[t] = Swing.at(keys, float(t))
		for t in planned:
			var g: Array = by_tick.get(t, [])
			var g_prev: Array = by_tick.get(t - 3, [])
			var g_next: Array = by_tick.get(t + 3, [])
			if g.is_empty():
				continue
			var p: Array = planned[t]
			var hand := base + Swing.hand_pos(p[0], p[1])
			var e := hand.distance_to(Vector2(g[0], g[1]))
			if not g_prev.is_empty() and not g_next.is_empty() and Vector2(g_prev[0], g_prev[1]).distance_to(Vector2(g_next[0], g_next[1])) > 0.02:
				errs.append(e)
			ok[1] += 1
			if (p[2] != 0) == (g[3] != 0):
				ok[0] += 1
			# A turn of the game's hand: the angle's motion reverses here, both legs over 20 degrees.
			var g0: Array = by_tick.get(t - 1, [])
			var g1: Array = by_tick.get(t + 1, [])
			if not g0.is_empty() and not g1.is_empty():
				var a0 := (Vector2(g0[0], g0[1]) - base).angle()
				var a1 := (Vector2(g[0], g[1]) - base).angle()
				var a2 := (Vector2(g1[0], g1[1]) - base).angle()
				var d1 := wrapf(a1 - a0, -PI, PI)
				var d2 := wrapf(a2 - a1, -PI, PI)
				if absf(d1) > 0.02 and absf(d2) > 0.02 and signf(d1) != signf(d2):
					# The planned hand's nearest approach to this turn, within a tick either way.
					var best := e
					for dt in [-1, 1]:
						var q: Array = planned.get(t + dt, [])
						if not q.is_empty():
							best = minf(best, (base + Swing.hand_pos(q[0], q[1])).distance_to(Vector2(g[0], g[1])))
					turns.append(best)
		err_by_kind[kind] = errs
		turn_by_kind[kind] = turns
		item_ok[kind] = ok
	print("inserter_swing_replay: %d working inserters, samples every %d ticks (phase %d)" % [n_ins, period, phase])
	var all_e := []
	var all_t := []
	var kinds := err_by_kind.keys()
	kinds.sort()
	for kind in kinds:
		var e: Array = err_by_kind[kind]
		var t: Array = turn_by_kind[kind]
		e.sort()
		t.sort()
		all_e.append_array(e)
		all_t.append_array(t)
		var ok: Array = item_ok[kind]
		print("  %-22s moving error mean %.3f p50 %.3f p90 %.3f (n %d); at the game's turns %.3f mean, %.0f%% within 0.15 (n %d); item right %.1f%%" % [
			kind, _mean(e), _pct(e, 0.5), _pct(e, 0.9), e.size(), _mean(t), 100.0 * _share(t, 0.15), t.size(), 100.0 * ok[0] / maxi(ok[1], 1)])
	all_e.sort()
	all_t.sort()
	print("  all: moving error mean %.3f p50 %.3f p90 %.3f (n %d); at turns %.3f mean, %.0f%% within 0.15 (n %d)" % [
		_mean(all_e), _pct(all_e, 0.5), _pct(all_e, 0.9), all_e.size(), _mean(all_t), 100.0 * _share(all_t, 0.15), all_t.size()])
	quit(0)


static func _mean(a: Array) -> float:
	if a.is_empty():
		return NAN
	var s := 0.0
	for x in a:
		s += x
	return s / a.size()


static func _pct(sorted: Array, q: float) -> float:
	if sorted.is_empty():
		return NAN
	return sorted[clampi(int(round(q * (sorted.size() - 1))), 0, sorted.size() - 1)]


static func _share(a: Array, below: float) -> float:
	if a.is_empty():
		return NAN
	var n := 0
	for x in a:
		if x < below:
			n += 1
	return float(n) / a.size()
