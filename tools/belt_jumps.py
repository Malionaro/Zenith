#!/usr/bin/env python3
"""Belt items that jump (the owner's K19: "they all of a sudden jump around"): what the client draws,
frame by frame, beside a recording of the game.

    godot --headless --path client -s res://tests/belt_bs_replay.gd -- --stream=s.jsonl --truth=rec.json
        --every-tick --belt-draw-dump=draw.bin [--sim-dump=sim.txt]
    python tools/belt_jumps.py --truth rec.json --draw draw.bin [--sim sim.txt] [--list 12] [--trace UID]

--draw: the replay's (or the client's) --belt-draw-dump, a job a drawn tick: the records the GPU holds
after each job, placed as the shader places them (tools/belt_view_check.py's DrawState: item records,
the lattice's slots and its mask) at that job's drawn tick. Counted per drawn tick:
  - jumps, by place (a lattice's slots have no identity: a row moved on a whole gap looks the same):
    things drawn with nothing of their kind within a belt's step + --allow tiles (0.07: two ticks'
    travel on a yellow belt) of them the tick before (appeared), and things drawn the tick before with
    nothing there now (vanished). An item put on or taken off is one of either;
  - unseen: the game's items with nothing of their kind drawn within 0.15 tile; phantoms: things drawn
    with no game item of their kind within 0.15 tile.
A glitch shows as a tick with many of either. Exit 1 when any tick has more than --most jumps (4: two
hands at once) or more than --most-off unseen + phantoms.

--sim: the replay's --sim-dump (the simulation's own items at each of its steps): each item's move
beside the game's own over the same ticks; says how many moved otherwise.
"""

import argparse
import collections
import json
import math
import pathlib
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "tools"))
import belt_view_check as bvc  # noqa: E402


def sim_jumps(truth, path, step, allow, show):
    at = {}
    for m in truth["lanes"]:
        ln = float(m[6]) or 1.0
        at[m[0] * 8 + m[5]] = (m[7][0], m[7][1], (m[9][0] - m[7][0]) / ln, (m[9][1] - m[7][1]) / ln)

    def place(key, pos):
        x0, y0, dx, dy = at[key]
        return (x0 + dx * pos, y0 + dy * pos)

    game = {}
    for row in truth["ticks"]:
        g = {}
        for i in range(1, len(row), 5):
            m = truth["lanes"][row[i] - 1]
            g[row[i + 1]] = place(m[0] * 8 + m[5], row[i + 2])
        game[row[0]] = g
    prev, prev_t = None, None
    jumps = []
    n = 0
    for line in open(path):
        parts = line.split()
        if not parts:
            continue
        t = int(parts[0])
        cur = {}
        for p in parts[1:]:
            u, key, pos = (int(v) for v in p.split(","))
            if key in at:
                cur[u] = place(key, pos)
        if prev is not None and t > prev_t:
            n += 1
            for u, (x, y) in cur.items():
                if u not in prev or u not in game.get(t, {}) or u not in game.get(prev_t, {}):
                    continue
                px, py = prev[u]
                (gx, gy), (hx, hy) = game[t][u], game[prev_t][u]
                # The simulated item's move less the game's over the same ticks.
                d = math.hypot((x - px) - (gx - hx), (y - py) - (gy - hy))
                if d > step + 0.5:
                    jumps.append((t, u, d / 256.0, px / 256.0, x / 256.0))
        prev, prev_t = cur, t
    big = [j for j in jumps if j[2] > allow]
    print("simulation: %d steps; %d item-steps moved otherwise than the game's by more than a tick's travel, %d by more than %.2f tile (the largest %.2f)"
          % (n, len(jumps), len(big), allow, max([j[2] for j in jumps] or [0.0])))
    for j in sorted(big, key=lambda j: -j[2])[:show]:
        print("  item %d at tick %d: %.2f tiles (x %.2f -> %.2f)" % (j[1], j[0], j[2], j[3], j[4]))
    return len(big)


def drawn_jumps(truth, path, allow, show, trace, from_tick, tol=0.15):
    rows = bvc.truth_rows(truth)
    names = truth.get("names") or []
    placer = bvc.lane_placer(truth)
    lengths = {int(m[0]) * 8 + int(m[5]): int(m[6]) for m in truth["lanes"]}
    steps = {int(m[0]) * 8 + int(m[5]): int(m[10]) for m in truth["lanes"]}
    state = bvc.DrawState(bvc.lane_cells(placer, lengths))
    xs = [float(v) / 256.0 for m in truth["lanes"] for v in (m[7][0], m[9][0])]
    ys = [float(v) / 256.0 for m in truth["lanes"] for v in (m[7][1], m[9][1])]
    bounds = (min(xs) - 1, min(ys) - 1, max(xs) + 1, max(ys) + 1)
    # The bridge's item ids against the recording's names: by the lane each drawn thing is on.
    kinds = {}
    prev = {}
    prev_t = None
    per_tick = []  # (tick, jumps, the largest, unseen, phantoms, drawn, game)
    examples = []
    for h, ids, recs, gone, paths in bvc.dump_frames(path):
        state.apply(ids, recs, gone, paths)
        t = int(math.floor(float(h.get("fold", -1))))
        if t not in rows or t < from_tick:
            continue
        uids, idr, x, z, shown = state.drawn_at(t)
        game = rows[t]
        # Item ids: the game's item on a drawn thing's own lane, nearest it (once per id).
        if len(kinds) < len(names):
            by_lane = collections.defaultdict(list)
            for uid, key, item, pos, count in game:
                by_lane[key].append(item)
            for i in range(len(uids)):
                iid = int(idr[i, 1])
                its = by_lane.get(int(idr[i, 3]))
                if iid not in kinds and its and len(set(its)) == 1 and 1 <= its[0] <= len(names):
                    kinds[iid] = names[its[0] - 1]
        c, _ = bvc.score_live_tick(game, (uids, idr, x, z, shown), placer, names, kinds, bounds, tol)
        cur = []
        for i in range(len(uids)):
            if shown[i]:
                cur.append((float(x[i]), float(z[i]), int(idr[i, 1]), int(uids[i]), int(idr[i, 3])))
        nj, big = 0, 0.0
        if prev_t is not None and t == prev_t + 1:
            # By place: each thing drawn now against the nearest of its kind a tick before, one to one.
            reach = max(steps.values() or [8]) / 256.0 + allow
            cell = 1.0 / reach
            grid = collections.defaultdict(list)
            for k, q in enumerate(prev):
                grid[(q[2], int(math.floor(q[0] * cell)), int(math.floor(q[1] * cell)))].append(k)
            used = set()
            pairs = []
            for k, q in enumerate(cur):
                gx, gz = int(math.floor(q[0] * cell)), int(math.floor(q[1] * cell))
                for dx in (-1, 0, 1):
                    for dz in (-1, 0, 1):
                        for m in grid.get((q[2], gx + dx, gz + dz), ()):
                            d = math.hypot(q[0] - prev[m][0], q[1] - prev[m][1])
                            if d <= reach:
                                pairs.append((d, k, m))
            pairs.sort()
            got = set()
            for d, k, m in pairs:
                if k in got or m in used:
                    continue
                got.add(k)
                used.add(m)
            appeared = [cur[k] for k in range(len(cur)) if k not in got]
            vanished = [prev[m] for m in range(len(prev)) if m not in used]
            nj = len(appeared) + len(vanished)
            for q in appeared:
                # How far the nearest of its kind was a tick before.
                best = min([math.hypot(q[0] - v[0], q[1] - v[1]) for v in vanished if v[2] == q[2]] or [0.0])
                big = max(big, best)
                if len(examples) < 4000:
                    examples.append((t, q[3], best, q[0], q[1], q[4]))
        if trace:
            for q in cur:
                if q[3] == trace:
                    print("  trace %d at %d: %.3f, %.3f lane %d" % (trace, t, q[0], q[1], q[4]))
        per_tick.append((t, nj, big, c["game"] - c["seen"], c["game"], c["phantoms"], c["drawn"]))
        prev, prev_t = cur, t
    if not per_tick:
        print("drawn: no recorded tick was drawn")
        return 0, 0
    n = len(per_tick)
    tj = sum(p[1] for p in per_tick)
    game_n = sum(p[4] for p in per_tick)
    unseen = sum(p[3] for p in per_tick)
    phant = sum(p[5] for p in per_tick)
    drawn = sum(p[6] for p in per_tick)
    print("drawn: %d ticks (%d to %d); %d things appeared or vanished off their motion (more than %.2f tile over a belt's step) in %d of them, the most in one tick %d"
          % (n, per_tick[0][0], per_tick[-1][0], tj, allow, sum(1 for p in per_tick if p[1]), max(p[1] for p in per_tick)))
    print("drawn: game items seen %.2f%% (unseen %d of %d; the most in one tick %d), phantoms %.2f%% of what is drawn (the most in one tick %d)"
          % (100.0 * (game_n - unseen) / max(1, game_n), unseen, game_n, max(p[3] for p in per_tick),
             100.0 * phant / max(1, drawn), max(p[5] for p in per_tick)))
    worst = sorted(per_tick, key=lambda p: -(p[1] * 3 + p[3] + p[5]))[:show]
    for p in sorted(worst):
        if p[1] > 2 or p[3] + p[5] > 2:
            print("  tick %d: %d appeared or vanished (an appeared one's nearest vanished one up to %.2f tile off), %d of the game's %d items unseen, %d phantoms of %d drawn" % p)
    for e in sorted(examples, key=lambda e: -e[2])[:min(show, 6)]:
        print("  thing %d at tick %d: appeared at (%.2f, %.2f) on lane %d, the nearest that vanished %.2f tile off" % (e[1], e[0], e[3], e[4], e[5], e[2]))
    return max(p[1] for p in per_tick), max(p[3] + p[5] for p in per_tick)


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--truth", required=True)
    ap.add_argument("--draw", default="", help="the replay's or the client's --belt-draw-dump")
    ap.add_argument("--sim", default="", help="the replay's --sim-dump")
    ap.add_argument("--step", type=int, default=8, help="(--sim) the belts' step (1/256 a tick)")
    ap.add_argument("--allow", type=float, default=0.07, help="tiles a drawn thing may be off its motion")
    ap.add_argument("--most", type=int, default=4, help="things appearing or vanishing in one tick that still pass")
    ap.add_argument("--most-off", type=int, default=6, help="unseen + phantoms in one tick that still pass")
    ap.add_argument("--from-tick", type=int, default=0)
    ap.add_argument("--trace", type=int, default=0, help="print this drawn thing's place every tick")
    ap.add_argument("--list", type=int, default=12)
    a = ap.parse_args(argv)
    truth = json.loads(open(a.truth).read())
    bad = False
    if a.sim:
        bad = sim_jumps(truth, a.sim, a.step, a.allow, a.list) > 0 or bad
    if a.draw:
        j, off = drawn_jumps(truth, a.draw, a.allow, a.list, a.trace, a.from_tick)
        bad = bad or j > a.most or off > a.most_off
    print("jumps: %s" % ("FAIL" if bad else "PASS"))
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
