extends RefCounted
## A bar the bridge reports now and then (a machine's craft, a drill's mining, the burning fuel
## left), drawn on every frame between its reports (owner's I26: the bars stepped along with each
## update). A crafter's report says how fast it goes (`ps`), so its bar runs on from where the craft
## stood at the game's measured tick rate and is checked against the bridge once a craft, not pulled
## to every report; a bar without a rate (fuel, mining) learns it from the reports and eases to them.
## machine_screen.gd and entity_info.gd keep one per bar and call advance() every frame.

## Further than this from what is drawn, a report is another state (a new recipe, refuelled): jump.
const SNAP := 0.25
## How fast a correction is taken up (per second).
const EASE := 8.0

## The drawn value, 0..1; -1 before the first report.
var value := -1.0
## Crafting and mining come round from 1 to 0 at each cycle; fuel drops and is refilled.
var wraps := false
## With no report for this long the game is paused or gone, and the bar waits.
var wait_ms := 1500

var _rate := 0.0  # what is drawn a real second, signed
var _learnt := 0.0  # the rate the reports show, for bars without a given one
var _learnt_any := false
var _given := false  # the rate came with the report (a crafter's `ps`)
var _checked := false  # this cycle has been checked against a report
var _gap := 0.0  # a correction still to take up
var _last := -1.0
var _last_ms := 0
var _last_tick := 0
var _was_running := false
var _ticks_per_s := 60.0


func _init(cycle := false, wait := 1500) -> void:
	wraps = cycle
	wait_ms = wait


## A report: `v` 0..1, `per_second` how much one second of game time at 60 UPS makes (below 0: not
## known, learnt from the reports), `running` false while the machine stands (no power, no
## ingredients, output full): the bar then shows what the bridge says and waits.
func report(v: float, per_second := -1.0, running := true) -> void:
	v = clampf(v, 0.0, 1.0)
	var now := Time.get_ticks_msec()
	var tick: int = Bridge.server_tick
	var dt := float(now - _last_ms) / 1000.0
	var recent := _last >= 0.0 and dt > 0.05 and dt * 1000.0 < float(wait_ms)
	if recent and tick > _last_tick:
		_ticks_per_s = lerpf(_ticks_per_s, clampf(float(tick - _last_tick) / dt, 1.0, 600.0), 0.3)
	if per_second < 0.0 and recent and running and _was_running:
		var d := v - _last
		if wraps:
			d -= floorf(d)  # came round: under one cycle a report
		if wraps or d <= 0.02:  # fuel going up is the next item, not a rate
			_learnt = lerpf(_learnt, d / dt, 0.5) if _learnt_any else d / dt
			_learnt_any = true
	_given = per_second >= 0.0
	var rate := per_second * _ticks_per_s / 60.0 if _given else _learnt
	if not running:
		rate = 0.0
	var rate_changed := absf(rate - _rate) > 0.001
	_rate = rate
	_last = v
	_last_ms = now
	_last_tick = tick
	_was_running = running
	if value < 0.0 or not running:
		value = v
		_gap = 0.0
		_checked = true
		return
	var gap := v - value
	if wraps:
		gap -= roundf(gap)  # 0.98 drawn and 0.02 reported: it came round, 0.04 ahead
	if absf(gap) > SNAP:
		value = v
		_gap = 0.0
		_checked = false
	elif not _given or not _checked or rate_changed:
		# a learnt rate is only a guess, so every report corrects it; a given one once a cycle
		_gap = gap
		_checked = true


## Moves the bar on by `delta` seconds and returns what to draw (-1 before the first report).
func advance(delta: float) -> float:
	if value < 0.0:
		return value
	if Time.get_ticks_msec() - _last_ms < wait_ms:
		value += _rate * delta
	var take := _gap * (1.0 - exp(-delta * EASE))
	value += take
	_gap -= take
	if wraps:
		if value >= 1.0:
			value = fmod(value, 1.0)
			_checked = false  # the next craft: checked against the bridge once
		elif value < 0.0:
			value += 1.0
	else:
		value = clampf(value, 0.0, 1.0)  # fuel at 0 waits for the next item's report
	return value
