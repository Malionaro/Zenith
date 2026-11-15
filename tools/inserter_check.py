#!/usr/bin/env python3
"""How the client's drawn inserter arms compare with the game's hands: the bridge's per-tick trace
(/f3d-ih trace, script-output/f3d-ih-trace.jsonl) against the client's per-frame trace
(--inserter-arms-trace=<file>), both from one live run (tools/belt_view_check.py with those switches,
or the scratch runner round it).

    python tools/inserter_check.py --bridge f3d-ih-trace.jsonl --client arms.jsonl
        [--poll poll.jsonl] [--belt-report report.json] [--json out.json] [--lag-range 60]

The bridge trace: a line per inserter the first tick it is seen ({"u", "n", "x", "y", "d", "pp", "dp",
"rs", "es", "q", "m", "pt", "dt"}), a line per tick ([tick, unit, hand x, hand y (1/256 tile), held
count, held item, status, ...]) and a last line ({"end", "ticks", "ih_sends", "ih_hands", "ih_bytes"}).
The client trace: a line per frame ({"f", "ms", "T": the game tick the arms stand for, "B": the belts'
drawn tick, "us": the arms' cost, "a": [unit, hand x, hand y (tiles), held item, ...]}).

The report:
1. Hand position error: each drawn hand against the game's hand at the tick the arm stands for
   (interpolated between ticks), in tiles: mean, median, p90, max, by inserter kind; and the lag that
   fits best (the shift of the arms' ticks that makes the error least: how far behind the tick they
   claim the arms really are) with the error at that lag.
2. Swing coverage: the game's swings (the hand turning one way through at least 60 degrees between
   stops or reversals) and the drawn swings, matched by time: how much of each true swing's arc the
   drawn one covers, and whether the drawn arm reaches both ends (within 10 degrees of the true
   turning angles), by kind. Also the drawn swings' arcs on their own.
3. Arm vs belt timing: each pickup from a belt in the game (the held count rising from 0 for an
   inserter whose pickup target is a belt) at tick T0 with the hand at H0: at the frame the belts'
   drawn tick reaches T0 (when the belt's own copy of the item is taken off: the bridge dates the take
   at its read tick, 0-5 ticks later, which this doesn't know), how far the drawn hand is from H0 and
   from the game's hand of that tick, and whether it holds an item then or within the next 6 belt
   ticks; the ticks between the arms' tick and the belts' drawn tick per frame (the two timelines'
   offset). The same for drops onto belts (the count falling to 0).
4. Cost: the arms' client ms per frame (mean, p50, p99, with how many arms), the bridge's `inserters`
   step ms per tick (the profiler's samples before the trace began, from poll.jsonl) and `ih` bytes
   per second and per hand (the trace's last line).
5. The sweep's side per inserter (which way round the hand goes from the pickup to the drop), by
   direction and mirroring, and the pickup vector against the direction: the conventions the client
   relies on (inserter_arms.gd _learn_ends).
3b. Item change ticks: for every inserter (chests too), the drawn hand's item appearing or vanishing
   against the game's held count changing, in ticks (the pick/drop tick accuracy as drawn).
6. The bridge's events (the trace's {"ev"} lines, when the hands went as `ie`): each picked/dropped
   record's tick against the tick the count really changed, how many changes got no record, the
   records' own uncertainty, and the event rate.
--belt-report: belt_view_check's --json report, for its visible/phantoms beside these numbers.
"""

import argparse
import bisect
import collections
import json
import math
import statistics
import sys

BELT_TYPES = {"transport-belt", "underground-belt", "splitter", "lane-splitter", "loader", "loader-1x1", "linked-belt"}
SWING_MIN_DEG = 60.0
STILL_DEG = 0.3  # a turn per tick below this is standing


def read_bridge(path, events=None):
    """meta, rows and the end line; `events`, when a list is given, gets the bridge's `ie` records
    ({"ev": [kind, unit, tick, a, b, c, hand x, hand y, belt]} lines) as lists."""
    meta, rows, end = {}, {}, None
    with open(path, encoding="utf-8", errors="replace") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                v = json.loads(line)
            except ValueError:
                continue
            if isinstance(v, dict):
                if "u" in v:
                    meta[int(v["u"])] = v
                elif "end" in v:
                    end = v
                elif "ev" in v and events is not None:
                    events.append([int(x) for x in v["ev"]])
            elif isinstance(v, list) and v:
                t = int(v[0])
                hands = {}
                i = 1
                while i + 5 < len(v):
                    hands[int(v[i])] = (v[i + 1] / 256.0, v[i + 2] / 256.0, int(v[i + 3]), int(v[i + 4]), int(v[i + 5]))
                    i += 6
                rows[t] = hands
    return meta, rows, end


def read_client(path, meets=None):
    """The frames; `meets`, when a list is given, gets the client's hand-offs ({"meet": [inserter, tick,
    uid, x, z, why]} lines, --inserter-handoff)."""
    frames = []
    with open(path, encoding="utf-8", errors="replace") as f:
        for line in f:
            try:
                v = json.loads(line)
            except ValueError:
                continue
            if "meet" in v:
                if meets is not None:
                    meets.append(v["meet"])
                continue
            a = v.get("a") or []
            hands = {}
            for i in range(0, len(a) - 3, 4):
                hands[int(a[i])] = (float(a[i + 1]), float(a[i + 2]), int(a[i + 3]))
            frames.append({"f": v.get("f"), "ms": v.get("ms"), "T": float(v.get("T", -1)), "B": float(v.get("B", -1)),
                           "us": int(v.get("us", 0)), "a": hands})
    return frames


def pct(values, q):
    if not values:
        return float("nan")
    s = sorted(values)
    i = min(len(s) - 1, max(0, int(round(q * (len(s) - 1)))))
    return s[i]


def stats(values):
    if not values:
        return {"n": 0}
    return {"n": len(values), "mean": statistics.fmean(values), "p50": pct(values, 0.5), "p90": pct(values, 0.9),
            "p99": pct(values, 0.99), "max": max(values)}


def fmt_stats(s, unit="", scale=1.0):
    if not s or s.get("n", 0) == 0:
        return "none"
    return "mean %.3f, p50 %.3f, p90 %.3f, max %.3f%s (n %d)" % (s["mean"] * scale, s["p50"] * scale, s["p90"] * scale, s["max"] * scale, unit, s["n"])


class Truth:
    """One inserter's game hands by tick."""

    def __init__(self, meta):
        self.meta = meta
        self.ticks = []
        self.hands = []  # (x, y, count, item, status)

    def at(self, t):
        """The hand (x, y, item) at a fractional tick, interpolated; None outside the trace."""
        if not self.ticks or t < self.ticks[0] or t > self.ticks[-1]:
            return None
        i = bisect.bisect_right(self.ticks, t) - 1
        if i >= len(self.ticks) - 1:
            h = self.hands[-1]
            return (h[0], h[1], h[3])
        t0, t1 = self.ticks[i], self.ticks[i + 1]
        h0, h1 = self.hands[i], self.hands[i + 1]
        u = (t - t0) / (t1 - t0) if t1 > t0 else 0.0
        return (h0[0] + (h1[0] - h0[0]) * u, h0[1] + (h1[1] - h0[1]) * u, h0[3] if u < 1.0 else h1[3])


def angle_of(meta, x, y):
    return math.atan2(y - meta["y"], x - meta["x"])


def wrap(a):
    while a > math.pi:
        a -= 2 * math.pi
    while a <= -math.pi:
        a += 2 * math.pi
    return a


def swings(series, meta, min_deg=SWING_MIN_DEG, refine=False):
    """Swings in a (t, x, y) series: runs of the hand turning one way about its base, between
    standstills or reversals, through at least `min_deg`. [(t_start, t_end, a_start, a_end)].
    `refine`: the series samples a path that is straight between its turns (the client's frames of
    the planned hand), so a turn's angle is where the two straight runs round it meet, not the
    nearest sample's (a fast inserter turns 14 degrees a tick; frames miss the peak by half of one)."""
    out = []
    if len(series) < 3:
        return out
    angs = [angle_of(meta, x, y) for _, x, y in series]
    ts = [t for t, _, _ in series]
    if refine:
        peaks = {}
        for i in range(2, len(angs) - 1):
            d0 = wrap(angs[i - 1] - angs[i - 2])
            d1 = wrap(angs[i] - angs[i - 1])
            d2 = wrap(angs[i + 1] - angs[i])
            if d1 == 0.0 or d2 == 0.0 or (d1 > 0) == (d2 > 0) or (d0 > 0) != (d1 > 0):
                continue
            dt0, dt1 = ts[i] - ts[i - 1], ts[i + 1] - ts[i]
            if dt0 <= 0 or dt1 <= 0:
                continue
            s_in, s_out = d1 / dt0, d2 / dt1
            # The incoming line (through i-1 and i) meets the outgoing one (through i and i+1) at
            # the peak: angs[i-1] + s_in (t - ts[i-1]) = angs[i] + s_out (t - ts[i]).
            denom = s_in - s_out
            if denom == 0.0:
                continue
            tp = (d1 + s_in * ts[i - 1] - s_out * ts[i]) / denom
            if ts[i - 1] <= tp <= ts[i + 1]:
                peaks[i] = angs[i - 1] + s_in * (tp - ts[i - 1])
        angs = [wrap(peaks.get(i, a)) for i, a in enumerate(angs)]
    direction = 0
    start = 0
    thr = math.radians(STILL_DEG)
    for i in range(1, len(angs)):
        d = wrap(angs[i] - angs[i - 1])
        dt = ts[i] - ts[i - 1]
        rate = d / dt if dt > 0 else 0.0
        s = 0 if abs(rate) < thr else (1 if d > 0 else -1)
        if s == 0:
            if direction != 0:
                arc = abs(wrap(angs[i - 1] - angs[start]))
                if math.degrees(arc) >= min_deg:
                    out.append((ts[start], ts[i - 1], angs[start], angs[i - 1]))
            direction = 0
            start = i
        elif s != direction:
            if direction != 0:
                arc = abs(wrap(angs[i - 1] - angs[start]))
                if math.degrees(arc) >= min_deg:
                    out.append((ts[start], ts[i - 1], angs[start], angs[i - 1]))
            direction = s
            start = i - 1
    if direction != 0:
        arc = abs(wrap(angs[-1] - angs[start]))
        if math.degrees(arc) >= min_deg:
            out.append((ts[start], ts[-1], angs[start], angs[-1]))
    return out


def analyze(meta, rows, end, frames, lag_range=60, poll=None, belt_report=None, ev_records=None):
    ticks = sorted(rows)
    if not ticks:
        raise SystemExit("the bridge trace has no tick rows")
    t_lo, t_hi = ticks[0], ticks[-1]
    truth = {}
    for t in ticks:
        for u, h in rows[t].items():
            tr = truth.get(u)
            if tr is None:
                tr = truth[u] = Truth(meta.get(u, {"u": u, "n": "?", "x": h[0], "y": h[1], "d": -1}))
            tr.ticks.append(t)
            tr.hands.append(h)
    # Frames whose arm tick lies in the trace (the client runs on either side of it).
    fr = [f for f in frames if t_lo <= f["T"] <= t_hi]
    kinds = {u: tr.meta.get("n", "?") for u, tr in truth.items()}
    rep = {"trace": {"ticks": [t_lo, t_hi], "n_ticks": len(ticks), "inserters": len(truth), "end": end,
                     "kinds": dict(collections.Counter(kinds.values()))},
           "frames": {"all": len(frames), "in_trace": len(fr)}}

    # 1. Position error at the tick the arm stands for, and the best-fitting lag.
    def moving(tr, t):
        # Whether the game's hand moved about tick t (within 3 ticks): idle inserters are right at
        # any tick and would dilute the error.
        a = tr.at(t - 3)
        b = tr.at(t + 3)
        return a is not None and b is not None and math.hypot(a[0] - b[0], a[1] - b[1]) > 0.02

    def errors(lag, only_moving):
        errs = collections.defaultdict(list)
        for f in fr:
            t = f["T"] - lag
            for u, (x, y, item) in f["a"].items():
                tr = truth.get(u)
                if tr is None:
                    continue
                g = tr.at(t)
                if g is None or only_moving and not moving(tr, f["T"]):
                    continue
                errs[kinds[u]].append(math.hypot(x - g[0], y - g[1]))
        return errs

    err0 = errors(0.0, False)
    all0 = [e for v in err0.values() for e in v]
    err_m = errors(0.0, True)
    all_m = [e for v in err_m.values() for e in v]
    best_lag, best_mean = 0, statistics.fmean(all_m) if all_m else float("nan")
    lag_curve = []
    for lag in range(-lag_range, lag_range + 1, 1):
        e = [x for v in errors(float(lag), True).values() for x in v]
        if not e:
            continue
        m = statistics.fmean(e)
        lag_curve.append((lag, m))
        if m < best_mean:
            best_lag, best_mean = lag, m
    working = {k: len({u for u, tr in truth.items() if kinds[u] == k and any(moving(tr, t) for t in tr.ticks[::10])}) for k in set(kinds.values())}
    rep["position"] = {"all": stats(all0), "by_kind": {k: stats(v) for k, v in sorted(err0.items())},
                       "moving": stats(all_m), "moving_by_kind": {k: stats(v) for k, v in sorted(err_m.items())},
                       "working_inserters": working,
                       "best_lag": best_lag, "error_at_best_lag": best_mean,
                       "lag_curve": lag_curve}

    # 2. Swing coverage.
    drawn_series = collections.defaultdict(list)
    for f in fr:
        for u, (x, y, item) in f["a"].items():
            drawn_series[u].append((f["T"], x, y))
    cov_by_kind = collections.defaultdict(list)
    ends_by_kind = collections.defaultdict(list)
    true_arcs = collections.defaultdict(list)
    drawn_arcs = collections.defaultdict(list)
    n_true = n_matched = 0
    for u, tr in truth.items():
        true_sw = swings([(t, h[0], h[1]) for t, h in zip(tr.ticks, tr.hands)], tr.meta)
        ds = sorted(drawn_series.get(u, []))
        # (A frame per tick is enough for the drawn swings; the trace has several a tick.)
        thinned = []
        last_t = None
        for t, x, y in ds:
            if last_t is None or t - last_t >= 0.5:
                thinned.append((t, x, y))
                last_t = t
        drawn_sw = swings(thinned, tr.meta, 20.0, refine=True)
        for s in drawn_sw:
            drawn_arcs[kinds[u]].append(math.degrees(abs(wrap(s[3] - s[2]))))
        for ts0, ts1, a0, a1 in true_sw:
            n_true += 1
            arc = abs(wrap(a1 - a0))
            true_arcs[kinds[u]].append(math.degrees(arc))
            # The drawn swing overlapping it most in time (the best lag applied to the drawn ticks).
            best = None
            best_ov = 0.0
            for d in drawn_sw:
                lo = max(ts0, d[0] - best_lag)
                hi = min(ts1, d[1] - best_lag)
                ov = hi - lo
                if ov > best_ov:
                    best_ov, best = ov, d
            if best is None or best_ov < 0.3 * (ts1 - ts0):
                cov_by_kind[kinds[u]].append(0.0)
                ends_by_kind[kinds[u]].append(False)
                continue
            n_matched += 1
            darc = abs(wrap(best[3] - best[2]))
            cov_by_kind[kinds[u]].append(min(1.0, darc / arc) if arc > 0 else 0.0)
            at_start = math.degrees(abs(wrap(best[2] - a0))) <= 10.0
            at_end = math.degrees(abs(wrap(best[3] - a1))) <= 10.0
            ends_by_kind[kinds[u]].append(at_start and at_end)
    rep["swings"] = {"true": n_true, "matched": n_matched,
                     "by_kind": {k: {"n": len(v), "coverage_mean": statistics.fmean(v) if v else float("nan"),
                                     "both_ends_pct": 100.0 * sum(ends_by_kind[k]) / len(v) if v else float("nan"),
                                     "true_arc_mean": statistics.fmean(true_arcs[k]) if true_arcs[k] else float("nan"),
                                     "drawn_arc_mean": statistics.fmean(drawn_arcs[k]) if drawn_arcs[k] else float("nan"),
                                     "drawn_arc_p10": pct(drawn_arcs[k], 0.1), "drawn_n": len(drawn_arcs[k])}
                                 for k, v in sorted(cov_by_kind.items())}}
    allcov = [x for v in cov_by_kind.values() for x in v]
    allends = [x for v in ends_by_kind.values() for x in v]
    rep["swings"]["coverage_mean"] = statistics.fmean(allcov) if allcov else float("nan")
    rep["swings"]["both_ends_pct"] = 100.0 * sum(allends) / len(allends) if allends else float("nan")

    # 3. Arm vs belt timing.
    offsets = [f["T"] - f["B"] for f in fr if f["B"] >= 0]
    rep["timing"] = {"arm_minus_belt_tick": stats(offsets)}
    frames_by_B = [(f["B"], i) for i, f in enumerate(frames) if f["B"] >= 0]
    frames_by_B.sort()
    b_keys = [b for b, _ in frames_by_B]

    def frame_when_belt_reaches(t):
        i = bisect.bisect_left(b_keys, t)
        if i >= len(b_keys):
            return None
        return frames[frames_by_B[i][1]]

    def events(kind):
        out = []
        for u, tr in truth.items():
            target = tr.meta.get("pt" if kind == "pick" else "dt", "")
            if target not in BELT_TYPES:
                continue
            for i in range(1, len(tr.ticks)):
                c0, c1 = tr.hands[i - 1][2], tr.hands[i][2]
                if kind == "pick" and c0 == 0 and c1 > 0 or kind == "drop" and c0 > 0 and c1 == 0:
                    out.append((u, tr.ticks[i], tr.hands[i][0], tr.hands[i][1], tr.hands[i - 1][0], tr.hands[i - 1][1]))
        return out

    for kind in ("pick", "drop"):
        evs = events(kind)
        dist_spot, dist_hand, held_now, held_soon = [], [], [], []
        for u, t0, hx, hy, px, py in evs:
            f = frame_when_belt_reaches(t0)
            if f is None or u not in f["a"]:
                continue
            x, y, item = f["a"][u]
            spot = (hx, hy) if kind == "pick" else (px, py)  # the hand where it took / where it dropped
            dist_spot.append(math.hypot(x - spot[0], y - spot[1]))
            g = truth[u].at(f["B"])
            if g is not None:
                dist_hand.append(math.hypot(x - g[0], y - g[1]))
            want_item = kind == "pick"
            held_now.append((item != 0) == want_item)
            soon = False
            for f2 in frames[frames.index(f):]:
                if f2["B"] > f["B"] + 6:
                    break
                if u in f2["a"] and (f2["a"][u][2] != 0) == want_item:
                    soon = True
                    break
            held_soon.append(soon)
        rep["timing"][kind] = {"events": len(evs), "scored": len(dist_spot),
                               "hand_from_spot": stats(dist_spot), "hand_from_game_hand": stats(dist_hand),
                               "item_state_right_pct": 100.0 * sum(held_now) / len(held_now) if held_now else float("nan"),
                               "item_state_right_within_6_pct": 100.0 * sum(held_soon) / len(held_soon) if held_soon else float("nan")}

    # 3b. The drawn hand's item changes against the game's, every inserter (chests too): for each
    # true change of the held count to or from 0 at T0, the drawn item change (the frames' arm tick)
    # nearest in time within 30 ticks, as drawn tick minus T0 (positive: late), by kind; and how many
    # true changes have no drawn change near them.
    by_unit_frames = collections.defaultdict(list)
    for f in fr:
        for u, (x, y, item) in f["a"].items():
            by_unit_frames[u].append((f["T"], item))
    drawn_changes = collections.defaultdict(list)  # unit -> [(tick, now holding)]
    for u, lst in by_unit_frames.items():
        lst.sort()
        prev = None
        for t, item in lst:
            if prev is not None and (item != 0) != (prev != 0):
                drawn_changes[u].append((t, item != 0))
            prev = item
    item_err = collections.defaultdict(list)
    item_missed = collections.Counter()
    item_n = collections.Counter()
    for u, tr in truth.items():
        dc = drawn_changes.get(u, [])
        dc_t = [t for t, _ in dc]
        for i in range(1, len(tr.ticks)):
            c0, c1 = tr.hands[i - 1][2], tr.hands[i][2]
            if (c0 == 0) == (c1 == 0):
                continue
            t0 = tr.ticks[i]
            if t0 < t_lo + 60 or t0 > t_hi - 60:
                continue  # (the drawn arms may not cover the trace's edges)
            item_n[kinds[u]] += 1
            j = bisect.bisect_left(dc_t, t0)
            best = None
            for cand in (j - 1, j):
                if 0 <= cand < len(dc) and dc[cand][1] == (c1 != 0):
                    d = dc[cand][0] - t0
                    if best is None or abs(d) < abs(best):
                        best = d
            if best is None or abs(best) > 30:
                item_missed[kinds[u]] += 1
            else:
                item_err[kinds[u]].append(best)
    all_item = [e for v in item_err.values() for e in v]
    rep["item_ticks"] = {"all": stats([abs(e) for e in all_item]), "signed_mean": statistics.fmean(all_item) if all_item else float("nan"),
                         "within_1_pct": 100.0 * sum(1 for e in all_item if abs(e) <= 1) / len(all_item) if all_item else float("nan"),
                         "missed": sum(item_missed.values()), "true_changes": sum(item_n.values()),
                         "by_kind": {k: {"abs": stats([abs(e) for e in v]), "signed_mean": statistics.fmean(v), "n_true": item_n[k], "missed": item_missed[k]}
                                     for k, v in sorted(item_err.items())}}

    # 6. The bridge's events against the per-tick truth: each picked/dropped record's tick minus the
    # tick the held count really changed (the nearest change of the right sense within 40 ticks),
    # with the record's own uncertainty `c`; how many true changes got no record; events per tick
    # and per kind.
    if ev_records:
        ev_err, ev_unc, ev_missed, ev_n = [], [], 0, 0
        ev_kinds = collections.Counter(e[0] for e in ev_records)
        by_unit = collections.defaultdict(list)
        for e in ev_records:
            if e[0] in (1, 2) and t_lo <= e[2] <= t_hi:
                by_unit[e[1]].append(e)
        for u, tr in truth.items():
            evs_u = sorted(by_unit.get(u, []), key=lambda e: e[2])
            ev_t = [e[2] for e in evs_u]
            for i in range(1, len(tr.ticks)):
                c0, c1 = tr.hands[i - 1][2], tr.hands[i][2]
                if c0 == c1:
                    continue
                t0 = tr.ticks[i]
                if t0 < t_lo + 60 or t0 > t_hi - 60:
                    continue
                ev_n += 1
                want = 1 if c1 > c0 else 2
                j = bisect.bisect_left(ev_t, t0)
                best = None
                for cand in range(max(0, j - 3), min(len(evs_u), j + 3)):
                    e = evs_u[cand]
                    if e[0] == want and abs(e[2] - t0) <= 40:
                        if best is None or abs(e[2] - t0) < abs(best[2] - t0):
                            best = e
                if best is None:
                    ev_missed += 1
                else:
                    ev_err.append(best[2] - t0)
                    ev_unc.append(best[5])
        n_ticks = max(1, len(ticks))
        names = {1: "picked", 2: "dropped", 3: "status", 4: "sync", 5: "gone"}
        rep["events"] = {"records": len(ev_records), "per_tick": len(ev_records) / n_ticks,
                         "kinds": {names.get(k, str(k)): v for k, v in sorted(ev_kinds.items())},
                         "true_changes": ev_n, "matched": len(ev_err), "missed": ev_missed,
                         "tick_error": stats([abs(e) for e in ev_err]), "signed_mean": statistics.fmean(ev_err) if ev_err else float("nan"),
                         "exact_pct": 100.0 * sum(1 for e in ev_err if e == 0) / len(ev_err) if ev_err else float("nan"),
                         "within_1_pct": 100.0 * sum(1 for e in ev_err if abs(e) <= 1) / len(ev_err) if ev_err else float("nan"),
                         "uncertainty": stats(ev_unc), "uncertain_pct": 100.0 * sum(1 for c in ev_unc if c > 0) / len(ev_unc) if ev_unc else float("nan")}

    # 4. Cost.
    us = [f["us"] for f in frames if f["a"]]
    arms_n = [len(f["a"]) for f in frames if f["a"]]
    rep["cost"] = {"client_us_per_frame": stats(us), "arms_per_frame": stats(arms_n)}
    if poll:
        before, during = [], []
        trace_t = None
        for p in poll:
            if "trace" in p:
                trace_t = p["t"]
            v = (p.get("prof") or {}).get("inserters")
            if v is None:
                continue
            (during if trace_t and p["t"] >= trace_t else before).append(v)
        rep["cost"]["bridge_inserters_ms_per_tick"] = {"before_trace": stats(before), "during_trace": stats(during)}
        total = [(p.get("prof") or {}).get("TOTAL") for p in poll if (p.get("prof") or {}).get("TOTAL") is not None]
        rep["cost"]["bridge_total_ms_per_tick"] = stats(total)
    if end:
        tk = max(1, int(end.get("ticks", 1)))
        rep["cost"]["ih_bytes_per_tick"] = end.get("ih_bytes", 0) / tk
        rep["cost"]["ih_bytes_per_hand"] = end.get("ih_bytes", 0) / max(1, end.get("ih_hands", 1))
        rep["cost"]["ih_hands_per_send"] = end.get("ih_hands", 0) / max(1, end.get("ih_sends", 1))
        rep["cost"]["ie_bytes_per_tick"] = end.get("ie_bytes", 0) / tk
        rep["cost"]["ie_events_per_tick"] = end.get("ie_events", 0) / tk
        rep["cost"]["ie_sends"] = end.get("ie_sends", 0)
        rep["cost"]["checks_per_tick"] = end.get("checks", 0) / tk

    # 5. Conventions: the sweep's side and the pickup vector against the direction.
    sides = collections.Counter()
    pick_dirs = collections.Counter()
    for u, tr in truth.items():
        m = tr.meta
        if "pp" not in m or "dp" not in m:
            continue
        ax = (m["dp"][0] - m["pp"][0], m["dp"][1] - m["pp"][1])
        side_votes = collections.Counter()
        for h in tr.hands:
            rel = (h[0] - m["x"], h[1] - m["y"])
            cross = ax[0] * rel[1] - ax[1] * rel[0]
            along = ax[0] * rel[0] + ax[1] * rel[1]
            if abs(cross) > 0.3 * math.hypot(*ax) and abs(along) < 0.7 * math.hypot(*ax):
                side_votes["left" if cross < 0 else "right"] += 1
        if side_votes:
            sides[(m.get("n"), m.get("d"), m.get("m"), side_votes.most_common(1)[0][0])] += 1
        pv = (round(m["pp"][0] - m["x"], 2), round(m["pp"][1] - m["y"], 2))
        pick_dirs[(m.get("d"), pv)] += 1
    rep["conventions"] = {"sides": [[list(k), v] for k, v in sides.most_common()],
                          "pickup_by_direction": [[k[0], list(k[1]), v] for k, v in pick_dirs.most_common()]}
    if belt_report:
        live = belt_report.get("live") or {}
        rep["belts"] = {"visible_pct": live.get("visible_pct"), "phantom_pct": live.get("phantom_pct"),
                        "replay_visible_pct": (belt_report.get("visible") or {}).get("pct") if isinstance(belt_report.get("visible"), dict) else None,
                        "pass": belt_report.get("pass")}
    return rep


def format_report(rep):
    out = []
    tr = rep["trace"]
    out.append("Inserter check: trace ticks %d-%d (%d ticks, %d inserters); client frames %d, %d in the trace" % (
        tr["ticks"][0], tr["ticks"][1], tr["n_ticks"], tr["inserters"], rep["frames"]["all"], rep["frames"]["in_trace"]))
    p = rep["position"]
    out.append("1. Hand position error at the tick the arm stands for (tiles), while the game's hand moves: %s" % fmt_stats(p["moving"]))
    for k, s in p["moving_by_kind"].items():
        out.append("   %-22s %s (%d of %d inserters working)" % (k, fmt_stats(s), p["working_inserters"].get(k, 0), rep["trace"]["kinds"].get(k, 0)))
    out.append("   over every frame, idle hands too: %s" % fmt_stats(p["all"]))
    out.append("   best-fitting lag %+d ticks (moving error there %.3f): the arms really stand for %d ticks %s the tick they claim" % (
        p["best_lag"], p["error_at_best_lag"], abs(p["best_lag"]), "before" if p["best_lag"] > 0 else "after"))
    s = rep["swings"]
    out.append("2. Swing coverage: %d true swings, %d matched to a drawn one; coverage %.1f%% of the arc on average, %.1f%% reach both ends" % (
        s["true"], s["matched"], 100.0 * s["coverage_mean"], s["both_ends_pct"]))
    for k, v in s["by_kind"].items():
        out.append("   %-22s n %3d: coverage %.1f%%, both ends %.0f%%; true arc %.0f deg, drawn swings %d of %.0f deg (p10 %.0f)" % (
            k, v["n"], 100.0 * v["coverage_mean"], v["both_ends_pct"], v["true_arc_mean"], v["drawn_n"], v["drawn_arc_mean"], v["drawn_arc_p10"]))
    t = rep["timing"]
    out.append("3. Arm vs belt timing: arm tick minus belt drawn tick per frame: %s" % fmt_stats(t["arm_minus_belt_tick"], " ticks"))
    for kind, label in (("pick", "belt pickups"), ("drop", "belt drops")):
        e = t.get(kind, {})
        out.append("   %s: %d in the game, %d scored at the frame the belts' drawn tick reaches the event" % (label, e.get("events", 0), e.get("scored", 0)))
        if e.get("scored"):
            out.append("     drawn hand from the %s spot: %s" % ("take" if kind == "pick" else "drop", fmt_stats(e["hand_from_spot"])))
            out.append("     drawn hand from the game's hand then: %s" % fmt_stats(e["hand_from_game_hand"]))
            out.append("     drawn hand %s then: %.0f%%; within the next 6 belt ticks: %.0f%%" % (
                "holds the item" if kind == "pick" else "is empty", e["item_state_right_pct"], e["item_state_right_within_6_pct"]))
    c = rep["cost"]
    out.append("4. Cost: arms %s; arms per frame %s" % (fmt_stats(c["client_us_per_frame"], " ms", 0.001), fmt_stats(c["arms_per_frame"])))
    if "bridge_inserters_ms_per_tick" in c:
        b = c["bridge_inserters_ms_per_tick"]
        out.append("   bridge `inserters` step: %s before the trace; %s with it" % (fmt_stats(b["before_trace"], " ms/tick"), fmt_stats(b["during_trace"], " ms/tick")))
    if "ih_bytes_per_tick" in c:
        out.append("   ih: %.0f bytes/tick (%.0f KB/s at 60 UPS), %.1f bytes/hand, %.0f hands/send" % (
            c["ih_bytes_per_tick"], c["ih_bytes_per_tick"] * 60 / 1024, c["ih_bytes_per_hand"], c["ih_hands_per_send"]))
    if c.get("ie_sends"):
        out.append("   ie: %.0f bytes/tick (%.1f KB/s at 60 UPS), %.2f event records/tick (each sent 3 times), %d sends; %.1f hand checks/tick" % (
            c["ie_bytes_per_tick"], c["ie_bytes_per_tick"] * 60 / 1024, c["ie_events_per_tick"], c["ie_sends"], c["checks_per_tick"]))
    it = rep.get("item_ticks")
    if it:
        out.append("3b. Item change ticks (every inserter): drawn hand's item changes vs the game's: |error| %s; signed mean %+.2f (late > 0); within 1 tick %.0f%%; %d of %d true changes with no drawn change within 30 ticks" % (
            fmt_stats(it["all"], " ticks"), it["signed_mean"], it["within_1_pct"], it["missed"], it["true_changes"]))
        for k, v in it["by_kind"].items():
            out.append("   %-22s %s, signed %+.2f, missed %d of %d" % (k, fmt_stats(v["abs"], " ticks"), v["signed_mean"], v["missed"], v["n_true"]))
    ev = rep.get("events")
    if ev:
        out.append("6. Bridge events (`ie`): %d records (%.2f/tick): %s" % (ev["records"], ev["per_tick"], ", ".join("%s %d" % kv for kv in ev["kinds"].items())))
        out.append("   picked/dropped tick vs the true change: |error| %s, signed mean %+.2f, exact %.0f%%, within 1 tick %.0f%%; %d of %d true changes without a record; uncertainty c: %s (c > 0 in %.0f%%)" % (
            fmt_stats(ev["tick_error"], " ticks"), ev["signed_mean"], ev["exact_pct"], ev["within_1_pct"], ev["missed"], ev["true_changes"],
            fmt_stats(ev["uncertainty"], " ticks"), ev["uncertain_pct"]))
    cv = rep["conventions"]
    out.append("5. Conventions: sweep side by (kind, direction, mirrored, side): %s" % ", ".join("%s x%d" % (k, v) for k, v in cv["sides"][:12]))
    out.append("   pickup vector by direction: %s" % ", ".join("d%s %s x%d" % (d, v, n) for d, v, n in cv["pickup_by_direction"][:8]))
    if rep.get("belts"):
        b = rep["belts"]
        out.append("Belts (belt_view_check): live visible %s%%, phantoms %s%%, %s" % (
            "%.1f" % b["visible_pct"] if b.get("visible_pct") is not None else "?",
            "%.2f" % b["phantom_pct"] if b.get("phantom_pct") is not None else "?", "PASS" if b.get("pass") else "FAIL/unknown"))
    return "\n".join(out)


# 7. (--inserter-handoff) The hand and the belt item at the moment they meet, from the client's draw dump
# (--belt-draw-dump: what each job wrote for the GPU and when it was drawn) against the bridge's trace.
HANDOFF_NEAR = 2.5  # tiles: records this near a traced inserter's pickup or drop point are followed
HANDOFF_WINDOW = (-30, 90)  # ticks: an item's leaving (appearing) is looked for this far round the game's pick (drop)
HANDOFF_MATCH = 1.2  # tiles: and this near the game's hand then


def _rec_place(r, t, paths):
    """Where one record (16 floats, absolute ticks; belt_view_check DrawState) draws its item at tick t:
    (x, z) or None (not drawn)."""
    t0, t1, code = r[3], r[7], r[11]
    if code < -0.5:
        return None
    g = min(1.0, max(0.0, (t - t0) / (t1 - t0))) if t1 > t0 else 1.0
    if r[13] < 0.5 and r[14] > 0.5 and r[15] > 0.0:
        q = (t - t0) / r[15]
        g = q - math.floor(q)
    if code < 0.5:
        return r[0] + r[4] * g, r[2] + r[6] * g
    if paths is None:
        return None
    c = int(round(code)) - 1
    first = c // 64
    pieces = c - first * 64 + 1
    f = g * pieces
    i = min(int(math.floor(f)), pieces - 1)
    a = (first + i) * 4
    if a + 7 >= len(paths):
        return None
    u = f - i
    if paths[a + 3] * (1 - u) + paths[a + 7] * u < 0.5:
        return None
    return r[0] + paths[a] * (1 - u) + paths[a + 4] * u, r[2] + paths[a + 2] * (1 - u) + paths[a + 6] * u


def read_draw_events(draw_path, apply_path, spots, t_lo, t_hi):
    """Streams a --belt-draw-dump: the items (not lattice slots) that left the drawing and those that came,
    near the spots, with the drawn tick of the job that did it and the record then, the hide (take) or show
    (put) tick a record carried, and the lattice: lanes drawn as one and the holes takes left in them.
    Returns (left, came, lattice) where left/came are lists of dicts and lattice {lane: [(D, 'on'|'off')],
    'holes': [(lane, h, D)]}."""
    import numpy as np
    sys.path.insert(0, str(__import__("pathlib").Path(__file__).resolve().parent))
    import belt_view_check as bvc
    applies = {int(d["n"]): float(d["drawn"]) for d in bvc.read_apply(apply_path)}
    sp = np.array(spots if spots else [(1e9, 1e9)], dtype=np.float64)
    seen_ever = set()
    near = {}  # uid -> (item, row, lane)
    lat_slots = collections.Counter()  # lane -> slots drawn
    left, came = [], []
    lattice = {"lanes": collections.defaultdict(list), "holes": []}
    paths = None
    for h, ids, recs, gone, pth in bvc.dump_frames(draw_path):
        D = applies.get(int(h.get("n", -1)))
        if pth is not None:
            paths = pth
        in_window = D is not None and t_lo - 200 <= D <= t_hi + 200
        if gone is not None:
            for uid in gone.tolist():
                if uid < 0:
                    lane = (-uid - 1) // 8
                    if lat_slots[lane] > 0:
                        lat_slots[lane] -= 1
                        if lat_slots[lane] == 0 and in_window:
                            lattice["lanes"][lane].append((D, "off"))
                    continue
                e = near.pop(uid, None)
                if e is not None and in_window:
                    r = e[1]
                    hide = r[15] if r[13] < 0.5 and r[14] <= 0.5 and r[15] > 0.0 else None
                    left.append({"uid": uid, "item": e[0], "D": D, "row": r, "hide": hide, "lane": e[2], "paths": paths,
                                 "lattice": lat_slots[e[2]] > 0})
        if ids is None:
            continue
        uids = ids[:, 0]
        neg = uids < 0
        if neg.any():
            for i in np.nonzero(neg)[0].tolist():
                lane = int(ids[i, 3])
                uid = int(uids[i])
                if uid not in seen_ever:
                    seen_ever.add(uid)
                    lat_slots[lane] += 1
                    if lat_slots[lane] == 1 and in_window:
                        lattice["lanes"][lane].append((D, "on"))
                if recs[i, 12] > 0.0 and in_window:
                    lattice["holes"].append((lane, float(recs[i, 12]), D))
        pos = ~neg
        if not pos.any():
            continue
        # (Near a spot: the record's glide from where it starts to where it gets, within HANDOFF_NEAR of one;
        # a record on a long straight run starts far up the belt.)
        idx = np.nonzero(pos)[0]
        ax, az = recs[idx, 0], recs[idx, 2]
        bx, bz = ax + recs[idx, 4], az + recs[idx, 6]
        dx, dz = bx - ax, bz - az
        ll = dx * dx + dz * dz
        tt = ((sp[None, :, 0] - ax[:, None]) * dx[:, None] + (sp[None, :, 1] - az[:, None]) * dz[:, None]) / np.where(ll > 0, ll, 1.0)[:, None]
        tt = np.clip(tt, 0.0, 1.0)
        qx = ax[:, None] + dx[:, None] * tt - sp[None, :, 0]
        qz = az[:, None] + dz[:, None] * tt - sp[None, :, 1]
        close = (qx * qx + qz * qz).min(axis=1) <= HANDOFF_NEAR * HANDOFF_NEAR
        for q, i in enumerate(idx.tolist()):
            uid = int(uids[i])
            new = uid not in seen_ever
            if new:
                seen_ever.add(uid)
            if not close[q] and uid not in near:
                continue
            near[uid] = (int(ids[i, 1]), recs[i].copy(), int(ids[i, 3]))
            if new and in_window:
                r = recs[i]
                show = -r[15] if r[13] < 0.5 and r[14] <= 0.5 and r[15] < 0.0 else None
                came.append({"uid": uid, "item": int(ids[i, 1]), "D": D, "row": r.copy(), "show": show, "lane": int(ids[i, 3]),
                             "paths": paths, "lattice": lat_slots[int(ids[i, 3])] > 0})
    lattice["drawn_until"] = max(applies.values()) if applies else 0.0
    return left, came, lattice


def handoff_analysis(truth, frames, meets, draw_path, apply_path, t_lo, t_hi):
    """Section 7: at each pickup from a belt in the game (and each drop onto one), the drawn moment the item
    left (came onto) the drawn belt, where it was then, the drawn hand then, and the ticks from the hand
    closing (opening) to it; and the client's own takes and puts (the arms trace's meet lines)."""
    picks, drops, spots = [], [], []
    for u, tr in truth.items():
        m = tr.meta
        pt, dt = m.get("pt", "") in BELT_TYPES, m.get("dt", "") in BELT_TYPES
        if pt and m.get("pp"):
            spots.append(tuple(m["pp"]))
        if dt and m.get("dp"):
            spots.append(tuple(m["dp"]))
        for i in range(1, len(tr.ticks)):
            c0, c1 = tr.hands[i - 1][2], tr.hands[i][2]
            if pt and c0 == 0 and c1 > 0:
                picks.append((u, tr.ticks[i], tr.hands[i][0], tr.hands[i][1], tr.hands[i][3]))
            elif dt and c0 > 0 and c1 == 0:
                drops.append((u, tr.ticks[i], tr.hands[i - 1][0], tr.hands[i - 1][1], tr.hands[i - 1][3]))
    left, came, lattice = read_draw_events(draw_path, apply_path, spots, t_lo, t_hi)
    # (Only what the client drew: the bridge's trace runs on after the client's recording stops.)
    t_hi = min(t_hi, lattice["drawn_until"] - HANDOFF_WINDOW[1] + 60)
    by_T = sorted((f["T"], i) for i, f in enumerate(frames) if f["T"] >= 0)
    t_keys = [t for t, _ in by_T]

    def hand_at(u, t):
        i = bisect.bisect_left(t_keys, t)
        best = None
        for j in (i - 1, i):
            if 0 <= j < len(by_T) and abs(by_T[j][0] - t) <= 2.0:
                f = frames[by_T[j][1]]
                if u in f["a"] and (best is None or abs(by_T[j][0] - t) < abs(best[0] - t)):
                    best = (by_T[j][0], f["a"][u])
        return best[1] if best else None

    changes = collections.defaultdict(list)  # unit -> [(T, holding)]
    prev = {}
    for t, i in by_T:
        for u, (x, y, item) in frames[i]["a"].items():
            if u in prev and (item != 0) != (prev[u] != 0):
                changes[u].append((t, item != 0))
            prev[u] = item

    def change_near(u, t0, holding):
        best = None
        for t, h in changes.get(u, []):
            if h == holding and abs(t - t0) <= 30 and (best is None or abs(t - t0) < abs(best - t0)):
                best = t
        return best

    out = {}
    for kind, evs, pool in (("pick", picks, left), ("drop", drops, came)):
        used = set()
        dist, dt_hand, dt_game, miss, lat_n = [], [], [], 0, 0
        dist_sim, dt_sim = [], []
        detail = []
        for u, t0, gx, gy, item in evs:
            if t0 < t_lo + 60 or t0 > t_hi - 60:
                continue
            best, bs = None, None
            for k, e in enumerate(pool):
                if k in used or e["item"] != item:
                    continue
                if kind == "pick":
                    L = e["hide"] if e["hide"] is not None and e["hide"] <= e["D"] else e["D"]
                    at = _rec_place(e["row"], L - 0.01, e["paths"])
                    # (Matched by where it was drawn at the game's tick: one that left late went on meanwhile.)
                    then = _rec_place(e["row"], min(t0, L - 0.01), e["paths"])
                else:
                    L = e["show"] if e["show"] is not None and e["show"] >= e["D"] else e["D"]
                    at = _rec_place(e["row"], L + 0.01, e["paths"])
                    then = at
                if at is None or then is None or not (HANDOFF_WINDOW[0] <= L - t0 <= HANDOFF_WINDOW[1]):
                    continue
                d = math.hypot(then[0] - gx, then[1] - gy)
                if d > HANDOFF_MATCH:
                    continue
                # (The nearest in time first: a hand at a busy belt takes or puts every few dozen ticks at one spot.)
                s = d + 0.1 * abs(L - t0)
                if bs is None or s < bs:
                    best, bs = (k, L, at), s
            if best is None:
                miss += 1
                continue
            k, L, at = best
            used.add(k)
            e = pool[k]
            if e["lattice"]:
                # (On a lane drawn as a lattice its record is masked: what shows leaving is the lattice's hole or
                # the lane going back to the simulation's items, whichever comes first.)
                lat_n += 1
                cand = [h for ln, h, D in lattice["holes"] if ln == e["lane"] and -30 <= h - t0 <= 90]
                cand += [D for D, what in lattice["lanes"].get(e["lane"], []) if what == "off" and -30 <= D - t0 <= 90]
                if cand:
                    L = min(cand, key=lambda v: abs(v - t0))
            hand = hand_at(u, L)
            if hand is not None:
                dd = math.hypot(hand[0] - at[0], hand[1] - at[1])
                dist.append(dd)
                (dist_sim if not e["lattice"] else []).append(dd)
            c = change_near(u, t0, kind == "pick")
            detail.append((u, t0, round(L, 2), c, round(math.hypot(hand[0] - at[0], hand[1] - at[1]), 3) if hand else None,
                           e["lattice"], e["uid"], e["hide"] if kind == "pick" else e["show"], e["D"]))
            if c is not None:
                dt_hand.append(L - c)
                if not e["lattice"]:
                    dt_sim.append(L - c)
            dt_game.append(L - t0)
        out[kind] = {"events": len([1 for e in evs if t_lo + 60 <= e[1] <= t_hi - 60]), "matched": len(dt_game), "unmatched": miss,
                     "on_lattice": lat_n,
                     "hand_to_item": stats(dist), "hand_to_item_sim_lanes": stats(dist_sim),
                     "item_minus_hand_ticks": stats(dt_hand), "item_minus_hand_abs": stats([abs(v) for v in dt_hand]),
                     "item_minus_hand_within_1_pct": 100.0 * sum(1 for v in dt_hand if abs(v) <= 1.0) / len(dt_hand) if dt_hand else float("nan"),
                     "item_minus_hand_sim_lanes": stats(dt_sim),
                     "item_minus_game_ticks": stats(dt_game), "detail": detail}
    whys = collections.Counter(int(m[5]) for m in meets)
    out["client"] = {"meets": len(meets), "taken": whys.get(0, 0), "read_first": whys.get(1, 0), "none_near": whys.get(2, 0),
                     "put": whys.get(3, 0), "had": whys.get(4, 0), "no_lane": whys.get(5, 0)}
    return out


def format_handoff(h):
    out = ["", "7. Hand and belt item meeting (draw dump; --inserter-handoff)"]
    for kind, what in (("pick", "pickups from belts: the item leaving the drawn belt"), ("drop", "drops onto belts: the item appearing on the drawn belt")):
        e = h.get(kind)
        if not e:
            continue
        out.append("   %s: %d in the trace, %d matched to a drawn item (%d not), %d on lattice lanes" % (what, e["events"], e["matched"], e["unmatched"], e["on_lattice"]))
        out.append("     drawn hand from the item then (tiles): %s" % fmt_stats(e["hand_to_item"]))
        out.append("       simulated lanes only: %s" % fmt_stats(e["hand_to_item_sim_lanes"]))
        out.append("     item %s minus the hand %s (ticks): %s" % ("leaving" if kind == "pick" else "appearing", "closing" if kind == "pick" else "opening", fmt_stats(e["item_minus_hand_ticks"])))
        out.append("       |that|: %s; within a tick %.0f%%" % (fmt_stats(e["item_minus_hand_abs"]), e["item_minus_hand_within_1_pct"]))
        out.append("       simulated lanes only: %s" % fmt_stats(e["item_minus_hand_sim_lanes"]))
        out.append("     item %s minus the game's tick: %s" % ("leaving" if kind == "pick" else "appearing", fmt_stats(e["item_minus_game_ticks"])))
    c = h.get("client", {})
    out.append("   client hand-offs: %d (taken %d, a read first %d, none near %d; put %d, already there %d, no lane %d)" % (
        c.get("meets", 0), c.get("taken", 0), c.get("read_first", 0), c.get("none_near", 0), c.get("put", 0), c.get("had", 0), c.get("no_lane", 0)))
    return "\n".join(out)


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--bridge", required=True)
    ap.add_argument("--client", required=True)
    ap.add_argument("--poll", default="")
    ap.add_argument("--belt-report", default="")
    ap.add_argument("--json", default="")
    ap.add_argument("--lag-range", type=int, default=60)
    ap.add_argument("--draw", default="", help="the run's --belt-draw-dump (draw.bin; its .apply.jsonl beside it): section 7")
    a = ap.parse_args()
    events = []
    meta, rows, end = read_bridge(a.bridge, events)
    meets = []
    frames = read_client(a.client, meets)
    poll = None
    if a.poll:
        poll = []
        with open(a.poll, encoding="utf-8", errors="replace") as f:
            for line in f:
                try:
                    poll.append(json.loads(line))
                except ValueError:
                    pass
    belt_report = None
    if a.belt_report:
        try:
            belt_report = json.load(open(a.belt_report, encoding="utf-8"))
        except (OSError, ValueError):
            belt_report = None
    rep = analyze(meta, rows, end, frames, a.lag_range, poll, belt_report, events)
    text = format_report(rep)
    if a.draw:
        truth = {}
        for t in sorted(rows):
            for u, hh in rows[t].items():
                tr = truth.get(u)
                if tr is None:
                    tr = truth[u] = Truth(meta.get(u, {"u": u, "n": "?", "x": hh[0], "y": hh[1], "d": -1}))
                tr.ticks.append(t)
                tr.hands.append(hh)
        ticks = sorted(rows)
        rep["handoff"] = handoff_analysis(truth, frames, meets, a.draw, a.draw + ".apply.jsonl", ticks[0], ticks[-1])
        text += "\n" + format_handoff(rep["handoff"])
    print(text)
    if a.json:
        with open(a.json, "w", encoding="utf-8") as f:
            json.dump(rep, f, indent=1, default=str)
    return 0


if __name__ == "__main__":
    sys.exit(main())
