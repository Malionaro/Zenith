extends RefCounted
## True while --stutter-probe reads the client's own timings and counts: world.gd's prof (with
## anim.gd's and far_chunks.gd's shares of it), chunk_view.gd's counters and bridge.gd's slow
## messages are kept only then, so a normal game doesn't time each animated group every frame.
static var on := false

## Main-thread times (µs) of the scripts' once-a-join work, by key, kept only while `on` (the probe
## shows a frame's share of each as w_<key>, and join_hitches.py names them): movers' (mv_*),
## decoratives' (dc_*), ground items' (gi_*), terrain textures' (tt_*).
static var prof := {}


## Adds the time since `t0` (Time.get_ticks_usec()) to `key`.
static func add(key: String, t0: int) -> void:
	if on:
		prof[key] = int(prof.get(key, 0)) + Time.get_ticks_usec() - t0
