extends RefCounted
## Small 3D models for items on belts, on the ground and in inserter hands:
## res://assets/models/items/<item>.glb, made by tools/models/items.py. Each is a few dozen
## triangles with its colours (picked once from Factorio's item icon) in the vertices, so every
## item type shares one plain material and draws as one MultiMesh (item_cards.gd).

const ItemShader := preload("res://shaders/item.gdshader")
const Probing := preload("res://scripts/debug/probing.gd")
const DIR := "res://assets/models/items/"
## Item colours are picked from icons that are drawn lit already; under the sun they'd read
## brighter than the icon (compared side by side with the icon cards).
const EXPOSURE := 0.75

static var _cache := {}  # item name -> Mesh, or null when it has no model
static var _material: ShaderMaterial


## The item's model, or null (the item keeps its icon card). Read on the main thread, once per item (10-40 ms
## the first time an item came into view while walking; the probe's `gi_model_load`). They were read on
## worker threads (ResourceLoader.load_threaded_request), but those reads could deadlock against the main
## thread at start: with Factorio's own folder in reach, the menu's belts asked for four item models at once,
## their four worker threads stood on a lock while the main thread waited for a worker (Zenith
## froze before the main menu on most starts; read here, 5 starts in 5 came up).
static func mesh_for(item: String) -> Mesh:
	if _cache.has(item):
		return _cache[item]
	var path := DIR + item + ".glb"
	var mesh: Mesh = null
	if item != "" and ResourceLoader.exists(path):
		var t0 := Time.get_ticks_usec()
		mesh = _mesh_of(load(path) as PackedScene)
		Probing.add("gi_model_load", t0)
	_cache[item] = mesh
	return mesh


## Whether mesh_for(item) answers at once: always now (it reads the model there and then, see above).
## Kept for its callers, which leave an item its icon card while this says no.
static func ready(item: String) -> bool:
	mesh_for(item)
	return true



static func _mesh_of(packed: PackedScene) -> Mesh:
	if packed == null:
		return null
	var mesh: Mesh = null
	var root := packed.instantiate()
	for node in root.find_children("*", "MeshInstance3D", true, false):
		mesh = (node as MeshInstance3D).mesh
		break
	root.free()
	return mesh


## One material for every item model: the vertex colours are the albedo (linear, as glTF
## stores them).
static func material() -> ShaderMaterial:
	if _material == null:
		_material = ShaderMaterial.new()
		_material.shader = ItemShader
		_material.set_shader_parameter("exposure", EXPOSURE)
	return _material


## A plain block for an item with neither a model nor an icon.
static func block_material(color: Color) -> ShaderMaterial:
	var m := ShaderMaterial.new()
	m.shader = ItemShader
	m.set_shader_parameter("color", color)
	return m
