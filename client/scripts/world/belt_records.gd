extends RefCounted
## Items on belts as GPU records (docs/PERFORMANCE-PLAN.md item 7; Satisfactory's position textures,
## Captain of Industry's pose tables). Each item, and each copy in a pile, has a record of four
## texels in one float texture array (the global `f3d_belt_records`):
##   0: where it is (x, y, z) at tick t0
##   1: how far it goes (x, y, z) by tick t1; it stands there after (and before t0 where it was)
##   2: its turn (cosine, sine), its lift above that place, and its path: 0 a straight glide, 1 + the
##      path's code in the `belt_paths` texture (belt_path.gdshaderinc), -1 not drawn (an empty slot,
##      an item under the ground)
##   3: for a pile's copy (belt_items.gd Layer): its item's record from this one (slots apart), its
##      step k in the pile (0: not a copy, the record is an item's own) and the kind's pile step (how far
##      each copy lifts); the copy's own turn is in its texel 2, and the shader draws the copy's place
##      from the item's record, so a pile's motion is one record
## The shaders (belt_path.gdshaderinc) place every item from its record and the drawn clock
## (`f3d_belt_clock`), so the CPU writes a record only when an item appears, leaves or changes its
## motion: an item that goes on as its record says, or stands, costs nothing.
##
## Each item kind (a MultiMesh, item_cards.gd) has a run of records of its own, one per slot: the
## shader reads record `belt_base` + INSTANCE_ID, so the MultiMesh's own buffer is never written
## after its size changes. Records live in pages (layers of the texture array); only the pages
## written since the last upload go to the GPU. A page is 4 rows (64 KB, 1,024 records) and the array
## starts with START_PAGES of them (--belt-draw-small-pages=off: 16 rows, 256 KB, and one page, as
## before); the shader takes a page's size from the texture's.
##
## Ticks are stored from `base` (the first update's tick), so a float32 keeps them to a few
## hundredths of a tick for several hours of game.
##
## This runs on belt_items.gd's worker thread (its Job); the main thread only uploads the pages.

const TEXELS := 4  # texels a record
const ROW := 1024  # texels a row
const PAGE_ROWS := 16  # (--belt-draw-small-pages=off) 4,096 records a page
const SMALL_ROWS := 4  # 1,024 records a page
const FLOATS := TEXELS * 4
## (small) The pages the array starts with: the first load's growing made the array again (every page
## uploaded) at 1, 2, 4 and 8 pages, a 1.5-3 ms frame each.
const START_PAGES := 8
## Runs are handed out in sizes of a power of two, from this up.
const MIN_RUN := 64
## Path codes in texel 2, w.
const HIDDEN := -1.0

## --belt-draw-small-pages=off: pages of 16 rows (256 KB), one at the start, as before. On (the default):
## 4 rows (64 KB), START_PAGES at the start. One record written sends its whole page up: a job wrote a few
## thousand records over every page, and a quarter of a page each is a quarter of the copy and the upload.
static var small := true

var rows := PAGE_ROWS  # this one's page: rows, records and floats (set when made, from `small`)
var per_page := ROW * PAGE_ROWS / TEXELS
var page_floats := ROW * PAGE_ROWS / TEXELS * FLOATS
var start_pages := 1
var data := PackedFloat32Array()
var pages := 0
## Pages written since take_pages().
var dirty := {}
## Every page must go up again (the texture array's size changed).
var all_dirty := false
var base := -1.0
var _top := 0  # records handed out so far, the next run starts here
var _free := {}  # run size -> Array of free run starts


func _init() -> void:
	if small:
		rows = SMALL_ROWS
		start_pages = START_PAGES
	per_page = ROW * rows / TEXELS
	page_floats = per_page * FLOATS


## A run of records for `n` slots (rounded up to a power of two): its first record.
func alloc(n: int) -> int:
	var size := MIN_RUN
	while size < n:
		size *= 2
	var list: Array = _free.get(size, [])
	if not list.is_empty():
		return list.pop_back()
	var start := _top
	_top += size
	_grow(_top)
	return start


func release(start: int, size: int) -> void:
	if size <= 0:
		return
	for r in range(start, start + size):
		hide(r)
	var list: Array = _free.get(size, [])
	list.append(start)
	_free[size] = list


## Copies `n` records from one run to another.
func copy(from: int, to: int, n: int) -> void:
	for k in n * FLOATS:
		data[to * FLOATS + k] = data[from * FLOATS + k]
	_mark_range(to, n)


func _grow(records: int) -> void:
	var need := (records + per_page - 1) / per_page
	if need <= pages:
		return
	var p := maxi(start_pages, pages)
	while p < need:
		p *= 2
	pages = p
	data.resize(pages * page_floats)
	all_dirty = true


func _mark_range(start: int, n: int) -> void:
	for p in range(start / per_page, (start + maxi(n, 1) - 1) / per_page + 1):
		dirty[p] = true


## An empty slot: drawn nowhere.
func hide(r: int) -> void:
	var o := r * FLOATS
	for k in FLOATS:
		data[o + k] = 0.0
	data[o + 11] = HIDDEN
	dirty[r / per_page] = true


## Ticks as stored: from `base`.
func tick(t: float) -> float:
	return t - base


## The pages to upload since the last call: [page, Image], or every page when the texture array must
## be made again (`all` true then).
func take_pages() -> Dictionary:
	var list: Array = []
	var all := all_dirty
	var which: Array = range(pages) if all else dirty.keys()
	for p in which:
		var bytes := data.slice(p * page_floats, (p + 1) * page_floats).to_byte_array()
		list.append([p, Image.create_from_data(ROW, rows, false, Image.FORMAT_RGBAF, bytes)])
	dirty = {}
	all_dirty = false
	return {"all": all, "pages": list}


## Where a record puts its item at tick `t` (absolute), as the shader does, without the lift and
## without paths (tests).
func position(r: int, t: float) -> Vector3:
	var o := r * FLOATS
	var from := Vector3(data[o], data[o + 1], data[o + 2])
	var step := Vector3(data[o + 4], data[o + 5], data[o + 6])
	var t0 := data[o + 3]
	var t1 := data[o + 7]
	var g := 1.0 if t1 <= t0 else clampf((t - base - t0) / (t1 - t0), 0.0, 1.0)
	return from + step * g
