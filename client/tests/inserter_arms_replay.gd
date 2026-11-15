extends SceneTree
## The inserter arms layer (scripts/world/inserter_arms.gd, belt clock) against the game, offline:
## a bridge hand trace (/f3d-ih trace, tools/inserter_check.py) is turned into the `ih` updates the
## layer would get (every 6 ticks on phase 3, --lose=<share> of them lost as UDP loses datagrams on
## a busy base), with a stub world (each inserter's record, a belt at a belt pickup) and eprops, and
## each arm's pose is read at every tick 40 behind the newest update, as the belt clock draws it,
## against the game's hand of that tick: the error in tiles while the hand moves, by kind, whether
## the item is in the drawn hand when it is in the game's, and how many ticks off the drawn hand's
## item changes are from the game's. --unit=<n> prints that arm tick by tick.
## --events: the trace is turned into the `ie` events the bridge would make instead (a sync the first
## tick, a pick or drop at every change of the held count with the hand's position then, a probe
## mid-way on the first two legs and every 8th, a sync every 300 ticks), sent every 2 ticks with
## each event repeated over 3 messages, --lose dropping whole messages.
##
##   godot --headless --path client -s res://tests/inserter_arms_replay.gd -- --trace=<f3d-ih-trace.jsonl>
##       [--lose=0.18] [--unit=<unit number>] [--events]

const Arms := preload("res://scripts/world/inserter_arms.gd")
const ProtoDB := preload("res://scripts/world/protos.gd")


class Rec:
	var pos := Vector2.ZERO
	var proto_id := 0
	var dir := 0
	var extra := {}


class Chunk:
	var entities := {}


class StubWorld extends Node3D:
	var entities := {}
	var chunks := {}


func _init() -> void:
	process_frame.connect(_run, CONNECT_ONE_SHOT)


func _run() -> void:
	var path := ""
	var only := -1
	var lose := 0.0
	var events := false
	var rng := RandomNumberGenerator.new()
	rng.seed = 7
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--trace="):
			path = a.substr(8)
		elif a.begins_with("--unit="):
			only = int(a.substr(7))
		elif a.begins_with("--lose="):
			lose = float(a.substr(7))
		elif a == "--events":
			events = true
	var f := FileAccess.open(path, FileAccess.READ)
	var metas := {}
	var rows := {}
	while not f.eof_reached():
		var line := f.get_line().strip_edges()
		if line == "":
			continue
		var v = JSON.parse_string(line)
		if v is Dictionary and v.has("u"):
			metas[int(v["u"])] = v
		elif v is Array and v.size() > 6:
			rows[int(v[0])] = v
	var protos := ProtoDB.new()
	var world := StubWorld.new()
	var names := {}
	var eprops := {}
	var speeds := {"burner-inserter": [0.013, 0.035], "inserter": [0.014, 0.035], "long-handed-inserter": [0.02, 0.05],
		"fast-inserter": [0.04, 0.1], "bulk-inserter": [0.04, 0.1], "stack-inserter": [0.04, 0.1]}
	var next_id := 1
	for u in metas:
		var m: Dictionary = metas[u]
		var n := str(m["n"])
		if not names.has(n):
			var p := ProtoDB.EntityProto.new()
			p.id = next_id
			p.name = n
			p.type = "inserter"
			protos.entities[p.id] = p
			names[n] = p.id
			var long := n == "long-handed-inserter"
			eprops[p.id] = {"x": {"ip": [0, -2.0 if long else -1.0], "id": [0, 2.2 if long else 1.2], "rs": speeds.get(n, [0.014, 0.035])[0], "es": speeds.get(n, [0.014, 0.035])[1]}}
			next_id += 1
		var r := Rec.new()
		r.pos = Vector2(float(m["x"]), float(m["y"]))
		r.proto_id = names[n]
		r.dir = int(m["d"])
		world.entities[u] = r
		# A belt entity at the pickup point when the trace says the pickup target is a belt.
		if str(m.get("pt", "")) in ["transport-belt", "underground-belt", "splitter", "lane-splitter", "loader", "loader-1x1", "linked-belt"]:
			if not names.has("transport-belt"):
				var bp := ProtoDB.EntityProto.new()
				bp.id = next_id
				bp.name = "transport-belt"
				bp.type = "transport-belt"
				protos.entities[bp.id] = bp
				names["transport-belt"] = bp.id
				next_id += 1
			var b := Rec.new()
			b.pos = Vector2(float(m["pp"][0]), float(m["pp"][1]))
			b.proto_id = names["transport-belt"]
			var key := "belt:%d" % u
			world.entities[key] = b
			var ck := Vector2i(floori(b.pos.x / 32.0), floori(b.pos.y / 32.0))
			if not world.chunks.has(ck):
				world.chunks[ck] = Chunk.new()
			world.chunks[ck].entities[key] = b
	Arms.belt_clock = true
	var arms := Arms.new()
	arms.protos = protos
	arms.world = world
	arms.eprops = eprops
	root.add_child(world)
	root.add_child(arms)
	var ticks := rows.keys()
	ticks.sort()
	var samples_fed := 0
	var errs := {}
	var items_ok := {}
	var item_ticks := {}  # kind -> [abs tick error of each drawn item change matched to a true one]
	var drawn_items := {}  # unit -> {tick: item} drawn
	var last_fed := -1
	# (--events) The events as the bridge would make them, by tick: [kind, unit, tick, a, b, c, x, y, belt]
	# (the status seen every tick here; the bridge sees it at its checks). The trace's statuses are
	# the game's defines.entity_status numbers: the codes the bridge sends are made from the names it
	# knows (inserters.lua STATUS_CODES); here the numbers seen in the owner's save (2.1.24).
	var codes := {1: 0, 36: 1, 38: 2, 37: 3, 5: 4, 4: 5, 6: 5, 7: 6, 8: 7, 11: 7, 12: 7, 62: 7, 14: 8}
	var evs := {}
	if events:
		var state := {}  # unit -> [count, item, legs, probe tick, sync tick, status code, leg ticks, pred tick, start x, start y, held poll]
		var legs_of := {"burner-inserter": 38, "inserter": 35, "long-handed-inserter": 24}
		var pick_of := {}
		var drop_of := {}
		for u in metas:
			pick_of[u] = Vector2(float(metas[u]["pp"][0]), float(metas[u]["pp"][1]))
			drop_of[u] = Vector2(float(metas[u]["dp"][0]), float(metas[u]["dp"][1]))
		for t in ticks:
			var row: Array = rows[t]
			var j := 1
			while j + 5 < row.size():
				var u := int(row[j])
				var hx := int(round(float(row[j + 1])))
				var hy := int(round(float(row[j + 2])))
				var cnt := int(row[j + 3])
				var item := int(row[j + 4])
				var code: int = codes.get(int(row[j + 5]), 9)
				var st = state.get(u)
				var pos := Vector2(hx, hy) / 256.0
				if st == null:
					st = [cnt, item, 0, -1, t + 300 + u % 60, code, legs_of.get(str(metas[u]["n"]), 12), -1, Vector2.ZERO, -1]
					state[u] = st
					_ev(evs, t, [4, u, t, cnt, item, code, hx, hy, 0])
				else:
					# (The bridge's check at the tick the hand should arrive: nothing changed and the hand still
					# where it set off from: looked at every 2 ticks; on its way late: a sync, belt 2.)
					if cnt == st[0] and (t == st[7] or t == st[9]):
						var target: Vector2 = drop_of[u] if cnt > 0 else pick_of[u]
						if pos.distance_to(target) >= (0.7 if cnt == 0 else 0.5):
							if pos.distance_to(st[8]) < 0.35:
								st[9] = t + 2
							else:
								_ev(evs, t, [4, u, t, cnt, item, code, hx, hy, 2])
								if st[3] > 0:
									st[3] = t + st[6] / 2
								st[9] = -1
								st[7] = -1
						else:
							st[9] = -1
							st[7] = -1
					if cnt > st[0]:
						_ev(evs, t, [1, u, t, cnt, item, 0, hx, hy, 0])
						st[2] += 1
						st[3] = t + st[6] / 2 if st[2] <= 2 or st[2] % 8 == 0 else -1
						st[7] = t + st[6]
						st[8] = pos
						st[9] = -1
					elif cnt < st[0]:
						_ev(evs, t, [2, u, t, cnt, st[1], 0, hx, hy, 0])
						st[7] = t + st[6]
						st[8] = pos
						st[9] = -1
					elif t == st[3]:
						_ev(evs, t, [4, u, t, cnt, item, code, hx, hy, 1])
						if pos.distance_to(pick_of[u]) < 0.35 or pos.distance_to(drop_of[u]) < 0.35:
							st[2] -= 1  # (at an end: a probe again next leg)
					elif t >= st[4]:
						_ev(evs, t, [4, u, t, cnt, item, code, hx, hy, 0])
						st[4] = t + 300
					if code != st[5]:
						_ev(evs, t, [3, u, t, cnt, item, code, hx, hy, 0])
						st[5] = code
				st[0] = cnt
				if cnt > 0:
					st[1] = item
				j += 6
	for t in ticks:
		if events and t % 2 == 1 and rng.randf() >= lose:
			var l := []
			for tt in range(t - 5, t + 1):
				for r in evs.get(tt, []):
					l.append_array(r)
			arms.handle_events({"t": "ie", "k": t, "n": 6, "p": 2, "part": 1, "parts": 1, "l": l})
			samples_fed += 1
		if not events and t % 6 == 3 and rng.randf() >= lose:
			var row: Array = rows[t]
			var l := []
			var j := 1
			while j + 5 < row.size():
				l.append(int(row[j]))
				l.append(int(round(float(row[j + 1]))))
				l.append(int(round(float(row[j + 2]))))
				l.append(int(row[j + 4]))
				j += 6
			arms.handle({"t": "ih", "k": t, "p": 6, "part": 1, "parts": 1, "l": l})
			samples_fed += 1
			last_fed = t
		# Pose every arm at this tick as the belt clock would, 40 ticks behind the newest sample.
		var drawn: int = t - 40
		if drawn < ticks[0] or not rows.has(drawn):
			continue
		var row_d: Array = rows[drawn]
		var j2 := 1
		while j2 + 5 < row_d.size():
			var u := int(row_d[j2])
			var arm = arms._arms.get(u)
			if arm != null and (only < 0 or u == only):
				arms._pose_at(arm, float(drawn))
				var m: Dictionary = metas[u]
				var base := Vector2(float(m["x"]), float(m["y"]))
				var hand: Vector2 = base + Vector2(cos(arm.angle), sin(arm.angle)) * arm.reach
				var g := Vector2(float(row_d[j2 + 1]) / 256.0, float(row_d[j2 + 2]) / 256.0)
				var e: float = hand.distance_to(g)
				var n := str(m["n"])
				if not errs.has(n):
					errs[n] = []
					items_ok[n] = [0, 0]
				var prev: Array = rows.get(drawn - 3, [])
				var nxt: Array = rows.get(drawn + 3, [])
				if not prev.is_empty() and not nxt.is_empty():
					var gp = _hand_of(prev, u)
					var gn = _hand_of(nxt, u)
					if gp != null and gn != null and gp.distance_to(gn) > 0.02:
						errs[n].append(e)
				items_ok[n][1] += 1
				if (arm.item_id != 0) == (int(row_d[j2 + 4]) != 0):
					items_ok[n][0] += 1
				if not drawn_items.has(u):
					drawn_items[u] = {}
				drawn_items[u][drawn] = arm.item_id
				if only == u:
					print("tick %d drawn %7.1f deg %.2f item %d | game %7.1f deg %.2f item %d  err %.2f  ends %s %s belt %s side %.2f" % [
						drawn, rad_to_deg(arm.angle), arm.reach, arm.item_id, rad_to_deg((g - base).angle()), (g - base).length(), int(row_d[j2 + 4]), e,
						str(arm.pick), str(arm.drop), str(arm.belt_pick), arm.side])
			j2 += 6
	# The drawn item's changes against the game's: for each true change (the held count going to or from
	# 0) the nearest drawn change within 30 ticks, in ticks.
	for u in drawn_items:
		var d: Dictionary = drawn_items[u]
		var n := str(metas[u]["n"])
		if not item_ticks.has(n):
			item_ticks[n] = []
		var changes := []
		var prev_item := -1
		for t in ticks:
			if not d.has(t):
				continue
			var it: int = d[t]
			if prev_item >= 0 and (it != 0) != (prev_item != 0):
				changes.append(t)
			prev_item = it
		var prev_c := -1
		for t in ticks:
			var h = _hand_count(rows[t], u)
			if h == null:
				continue
			if prev_c >= 0 and (h != 0) != (prev_c != 0) and d.has(t):
				var best := 1e9
				for c in changes:
					if absf(c - t) < absf(best):
						best = c - t
				if absf(best) <= 30.0:
					item_ticks[n].append(absf(best))
			prev_c = h
	print("fed %d %s" % [samples_fed, "ie messages" if events else "updates"])
	for n in item_ticks:
		var e: Array = item_ticks[n]
		var s := 0.0
		for x in e:
			s += x
		e.sort()
		print("  %-22s item change tick error mean %.2f p90 %.1f (n %d)" % [n, s / maxi(e.size(), 1), e[int(e.size() * 0.9)] if not e.is_empty() else NAN, e.size()])
	for n in errs:
		var e: Array = errs[n]
		e.sort()
		var s := 0.0
		for x in e:
			s += x
		print("  %-22s moving error mean %.3f p50 %.3f p90 %.3f (n %d); item right %.1f%%" % [n, s / maxi(e.size(), 1),
			e[e.size() / 2] if not e.is_empty() else NAN, e[int(e.size() * 0.9)] if not e.is_empty() else NAN, e.size(),
			100.0 * items_ok[n][0] / maxi(items_ok[n][1], 1)])
	quit(0)


static func _ev(evs: Dictionary, t: int, rec: Array) -> void:
	if not evs.has(t):
		evs[t] = []
	evs[t].append(rec)


static func _hand_count(row: Array, u: int):
	var j := 1
	while j + 5 < row.size():
		if int(row[j]) == u:
			return int(row[j + 3])
		j += 6
	return null


static func _hand_of(row: Array, u: int):
	var j := 1
	while j + 5 < row.size():
		if int(row[j]) == u:
			return Vector2(float(row[j + 1]) / 256.0, float(row[j + 2]) / 256.0)
		j += 6
	return null
