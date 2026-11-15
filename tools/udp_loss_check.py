#!/usr/bin/env python3
"""Which of the bridge's datagrams the client lost, from one live run with both ends traced: the bridge's
log while `/f3d-profile trace` ran (a line per datagram sent to a client whose hello says `dq`:
"f3ddg <tick> <n> <bytes> <type:count,...>") and the client's --udp-trace=<file> (a JSON line per datagram
read: {"us", "n", "b", "k", "m": {type: count}}).

    python tools/udp_loss_check.py --bridge-log factorio-current.log --client udp.jsonl
        [--stream stream.jsonl] [--json out.json]

The report:
1. Datagrams sent in the client's window (its first to its last number), read, lost; bytes; the loss
   as a share of datagrams and of bytes.
2. Lost datagrams by the message types they held (a datagram with a `bs` part counts for bs, ...),
   against the sent ones with that type: the share lost per type.
3. Lost datagrams by size, and by their tick's burst: how many datagrams the tick sent, how many bytes
   the tick had sent before this one (the OS keeps 64 KB of unread datagrams per socket on Windows:
   a datagram arriving when more than that is queued is dropped), and the position in the tick.
4. The ticks' bursts overall: datagrams and bytes per tick (distribution), ticks over 64 KB, and how many
   of those lost something.
5. (--stream, the client's `bs` capture) The `bs` updates' tick gaps split by the bridge's announced period
   `p`: a 12-tick gap after an update saying p=12 is the bridge's rate level, not a loss; one after p=6 is
   an update whose every part was lost. Parts missing from updates that did arrive.
Only the client's window is scored: datagrams the bridge sent before the client started or after it
stopped aren't losses.
"""

import argparse
import collections
import json
import re
import sys

WINDOWS_RCVBUF = 65536


def read_bridge(path):
    sent = {}
    pat = re.compile(r"f3ddg (\d+) (\d+) (\d+) ?(\S*)")
    with open(path, encoding="utf-8", errors="replace") as f:
        for line in f:
            m = pat.search(line)
            if not m:
                continue
            tick, n, nbytes, types = int(m.group(1)), int(m.group(2)), int(m.group(3)), m.group(4)
            tm = {}
            for part in types.split(","):
                if ":" in part:
                    t, c = part.rsplit(":", 1)
                    try:
                        tm[t] = int(c)
                    except ValueError:
                        pass
            sent[n] = {"tick": tick, "bytes": nbytes, "types": tm}
    return sent


def read_client(path):
    got = {}
    unnumbered = 0
    with open(path, encoding="utf-8", errors="replace") as f:
        for line in f:
            try:
                m = json.loads(line)
            except ValueError:
                continue
            n = int(m.get("n", -1))
            if n < 0:
                unnumbered += 1
                continue
            got[n] = m
    return got, unnumbered


def pct(a, b):
    return 100.0 * a / b if b else 0.0


def size_bucket(b):
    for edge in (1000, 5000, 15000, 30000, 45000, 60000):
        if b < edge:
            return "<%dK" % (edge // 1000) if edge >= 1000 else "<1K"
    return ">=60K"


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--bridge-log", required=True)
    ap.add_argument("--client", required=True)
    ap.add_argument("--stream", default="")
    ap.add_argument("--json", default="")
    a = ap.parse_args()
    sent = read_bridge(a.bridge_log)
    got, unnumbered = read_client(a.client)
    out = {}
    print("UDP loss check")
    if not got:
        print("   the client read no numbered datagrams (a bridge without `dg`, or the trace is empty)")
        return 1
    lo, hi = min(got), max(got)
    window = {n: s for n, s in sent.items() if lo <= n <= hi}
    if not sent:
        print("   the bridge log has no f3ddg lines (/f3d-profile trace wasn't on): only the client's side")
    lost = sorted(n for n in range(lo, hi + 1) if n not in got)
    sent_n = hi - lo + 1
    sent_bytes = sum(s["bytes"] for s in window.values())
    lost_bytes = sum(window[n]["bytes"] for n in lost if n in window)
    print("1. Datagrams in the client's window (numbers %d-%d): sent %d, read %d, lost %d (%.2f%%); %d unnumbered read" % (
        lo, hi, sent_n, len(got), len(lost), pct(len(lost), sent_n), unnumbered))
    if window:
        print("   bytes: sent %.1f MB, lost %.1f KB (%.2f%%); bridge log covers %d of the window's datagrams" % (
            sent_bytes / 1e6, lost_bytes / 1e3, pct(lost_bytes, sent_bytes), len(window)))
    out["window"] = {"first": lo, "last": hi, "sent": sent_n, "read": len(got), "lost": len(lost), "lost_pct": round(pct(len(lost), sent_n), 3),
                     "sent_bytes": sent_bytes, "lost_bytes": lost_bytes, "unnumbered": unnumbered, "logged": len(window)}
    if not window:
        print("   (no bridge log lines in the window: sections 2-4 need them)")
    else:
        # 2. by type
        by_type_sent = collections.Counter()
        by_type_lost = collections.Counter()
        msgs_lost = collections.Counter()
        for n, s in window.items():
            for t in s["types"]:
                by_type_sent[t] += 1
                if n not in got:
                    by_type_lost[t] += 1
                    msgs_lost[t] += s["types"][t]
        print("2. Lost datagrams by the message types they held (datagrams lost / sent with the type; messages lost):")
        for t, c in sorted(by_type_sent.items(), key=lambda x: -by_type_lost[x[0]])[:14]:
            print("   %-6s %5d / %6d (%.2f%%)  messages lost %d" % (t, by_type_lost[t], c, pct(by_type_lost[t], c), msgs_lost[t]))
        out["by_type"] = {t: {"sent": by_type_sent[t], "lost": by_type_lost[t], "messages_lost": msgs_lost[t]} for t in by_type_sent}
        # 3. by size and burst position
        ticks = collections.defaultdict(list)
        for n in sorted(window):
            ticks[window[n]["tick"]].append(n)
        pos = {}
        for tick, ns in ticks.items():
            before = 0
            for i, n in enumerate(ns):
                pos[n] = (i, len(ns), before, sum(window[x]["bytes"] for x in ns))
                before += window[n]["bytes"]
        by_size_sent = collections.Counter(size_bucket(s["bytes"]) for s in window.values())
        by_size_lost = collections.Counter(size_bucket(window[n]["bytes"]) for n in lost if n in window)
        print("3. Lost datagrams by size (lost / sent):")
        for k in ("<1K", "<5K", "<15K", "<30K", "<45K", "<60K", ">=60K"):
            if by_size_sent[k]:
                print("   %-6s %5d / %6d (%.2f%%)" % (k, by_size_lost[k], by_size_sent[k], pct(by_size_lost[k], by_size_sent[k])))
        out["by_size"] = {k: {"sent": by_size_sent[k], "lost": by_size_lost[k]} for k in by_size_sent}
        over = 0
        first_in_tick = 0
        lost_rows = []
        for n in lost:
            if n not in window:
                continue
            i, count, before, total = pos[n]
            if before >= WINDOWS_RCVBUF:
                over += 1
            if i == 0:
                first_in_tick += 1
            lost_rows.append({"n": n, "tick": window[n]["tick"], "bytes": window[n]["bytes"], "index": i, "of": count,
                              "bytes_before": before, "tick_bytes": total, "types": window[n]["types"]})
        print("   of the %d lost logged: %d came when their tick had already sent >= 64 KB (the OS buffer's size), %d were the tick's first datagram" % (
            len(lost_rows), over, first_in_tick))
        before_hist = collections.Counter(min(r["bytes_before"] // 16384, 8) for r in lost_rows)
        print("   lost by the tick's bytes before them: " + ", ".join("%d-%dK: %d" % (k * 16, (k + 1) * 16, c) if k < 8 else ">=128K: %d" % c for k, c in sorted(before_hist.items())))
        idx_hist = collections.Counter("%d/%d" % (r["index"] + 1, r["of"]) for r in lost_rows)
        print("   lost by position in the tick's burst (i/of): " + ", ".join("%s: %d" % kv for kv in sorted(idx_hist.items(), key=lambda x: -x[1])[:12]))
        print("   first lost: " + "; ".join("n%d t%d %dB #%d/%d before %dB %s" % (r["n"], r["tick"], r["bytes"], r["index"] + 1, r["of"], r["bytes_before"],
                                                                           ",".join("%s:%d" % kv for kv in sorted(r["types"].items()))) for r in lost_rows[:10]))
        out["lost"] = lost_rows
        # 4. bursts
        per_tick = [(len(ns), sum(window[x]["bytes"] for x in ns)) for ns in ticks.values()]
        per_tick_bytes = sorted(b for _, b in per_tick)
        per_tick_n = sorted(c for c, _ in per_tick)
        over_ticks = [t for t, ns in ticks.items() if sum(window[x]["bytes"] for x in ns) > WINDOWS_RCVBUF]
        over_lost = sum(1 for t in over_ticks if any(n not in got for n in ticks[t]))

        def q(xs, p):
            return xs[min(len(xs) - 1, int(p * len(xs)))] if xs else 0
        print("4. Ticks that sent (%d): datagrams a tick median %d, p90 %d, max %d; bytes a tick median %.0f, p90 %.0f, max %.0f" % (
            len(per_tick), q(per_tick_n, 0.5), q(per_tick_n, 0.9), per_tick_n[-1], q(per_tick_bytes, 0.5), q(per_tick_bytes, 0.9), per_tick_bytes[-1]))
        print("   ticks over 64 KB: %d (%.1f%% of sending ticks), %d of them lost a datagram; ticks under 64 KB that lost one: %d" % (
            len(over_ticks), pct(len(over_ticks), len(per_tick)), over_lost, sum(1 for t, ns in ticks.items() if t not in set(over_ticks) and any(n not in got for n in ns))))
        out["bursts"] = {"ticks": len(per_tick), "n_median": q(per_tick_n, 0.5), "n_p90": q(per_tick_n, 0.9), "n_max": per_tick_n[-1],
                         "bytes_median": q(per_tick_bytes, 0.5), "bytes_p90": q(per_tick_bytes, 0.9), "bytes_max": per_tick_bytes[-1],
                         "ticks_over_64k": len(over_ticks), "ticks_over_64k_lost": over_lost}
        # the client's read timing: datagrams read in one drain, and how the bytes a tick compare
        drains = collections.Counter()
        last_us = None
        run = 0
        for n in sorted(got):
            us = int(got[n].get("us", 0))
            if last_us is not None and us - last_us < 200:
                run += 1
            else:
                if run:
                    drains[run] += 1
                run = 1
            last_us = us
        if run:
            drains[run] += 1
        print("   client reads: datagrams read within 0.2 ms of the one before (one drain): " + ", ".join("%d: %d" % kv for kv in sorted(drains.items())[:10]))
    if a.stream:
        ups = {}
        order = []
        with open(a.stream, encoding="utf-8", errors="replace") as f:
            for line in f:
                try:
                    m = json.loads(line)
                except ValueError:
                    continue
                if m.get("t") != "bs":
                    continue
                k = int(m["k"])
                u = ups.get(k)
                if u is None:
                    u = ups[k] = {"parts": int(m.get("parts", 1)), "got": set(), "p": m.get("p")}
                    order.append(k)
                u["got"].add(int(m.get("part", 1)))
        gaps = collections.Counter()
        for x, y in zip(order, order[1:]):
            gaps[(y - x, int(ups[x]["p"] or 0))] += 1
        incomplete = sum(1 for k in order if len(ups[k]["got"]) < ups[k]["parts"])
        parts_missing = sum(ups[k]["parts"] - len(ups[k]["got"]) for k in order)
        parts_total = sum(ups[k]["parts"] for k in order)
        paced = sum(c for (g, p), c in gaps.items() if p and g == p)
        lost_updates = sum(c for (g, p), c in gaps.items() if p and g > p)
        print("5. `bs` updates in the capture: %d; tick gaps (gap, announced p): %s" % (
            len(order), ", ".join("%d after p=%d: %d" % (g, p, c) for (g, p), c in sorted(gaps.items(), key=lambda x: -x[1])[:8])))
        print("   gaps as announced (the bridge's pace): %d; gaps longer than announced (updates lost whole): %d; updates with parts missing: %d (%d of %d parts)" % (
            paced, lost_updates, incomplete, parts_missing, parts_total))
        out["bs"] = {"updates": len(order), "paced_gaps": paced, "lost_updates": lost_updates, "incomplete": incomplete,
                     "parts_missing": parts_missing, "parts": parts_total, "gaps": {"%d/%d" % k: v for k, v in gaps.items()}}
    if a.json:
        with open(a.json, "w", encoding="utf-8") as f:
            json.dump(out, f, indent=1)
    return 0


if __name__ == "__main__":
    sys.exit(main())
