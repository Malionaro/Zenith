extends Node
## How far the angled view draws when it is tilted low towards the horizon (Settings > Graphics >
## Horizon distance).
##
## From the default tilt the ground runs out at the top of the screen about 40 tiles from the
## camera; tilted low (and zoomed out) it runs out only at the edge of the loaded chunks, 300 and
## more tiles off, and everything on that long strip is drawn: ten times the chunks, each with its
## ground, trees, ore, rocks and clutter as MultiMeshes of their own (a draw each, again in the depth
## pre-pass and in the shadows). Levels of detail make each of those cheaper but not fewer. Here the
## camera's far plane is pulled in to `reach` tiles while the ground in view would reach further,
## so the renderer culls every chunk node, decorative and belt item past it before drawing (no
## script work), and a depth fog in the sky's own colour (aerial perspective) fades the ground into
## the horizon before the cut, so there is no hard edge: the view ends in haze instead of at the
## loaded chunks' ragged border. The area drawn grows with the square of the depth: at the High
## preset's 10 chunks a low tilt drew ground out to about 330 tiles, now 192 past the character (under half the
## chunks).
##
## Nothing changes while the ground in view ends nearer than `reach` (the default tilt and steeper
## at every zoom, Factorio's orthographic view, the map): there the far plane stays where the camera
## rig put it and there is no fog. First person, a ride's camera and an add-on's camera are left as
## they are. The fog is only Zenith's own while no look (looks.gd, an add-on's) has fog of its own.

const GroundHeight := preload("res://scripts/world/ground_height.gd")
const ModelLods := preload("res://scripts/world/model_lods.gd")

## The camera rig's own far plane (camera_rig.gd), put back when the reach lets go.
const FULL_FAR := 2000.0
## Automatic reach: this share of the view distance (tiles), within REACH_RANGE. The reach is
## counted from the focus (the character), the camera's own distance to it added: counted from the
## camera, a view zoomed far out (the camera 150 tiles and more from the ground) put nearly all of
## its ground in the fog.
const AUTO_SHARE := 0.6
const REACH_RANGE := Vector2(160.0, 320.0)
## Tiles past the ground's furthest point in view that tall things (trees, chimneys) still need.
const TALL_MARGIN := 24.0
## The fog starts at this share of the reach once the view reaches well past it (FOG_BEGIN.y), and
## just short of the reach when it only reaches a little past (FOG_BEGIN.x), easing between, so
## tilting across the line doesn't pop the fog in.
const FOG_BEGIN := Vector2(0.85, 0.55)

## Settings > Graphics > Horizon distance: 0 Automatic (from the view distance), < 0 off, else tiles.
var setting := 0.0
## The view distance in chunks (world.gd view_radius), for Automatic.
var view_radius := 10
var rig  # camera_rig.gd
var env: Environment

## Whether the reach holds the view in now, and how far (for the debug line).
var active := false
var reach := 0.0
## The far plane while it holds: the camera's distance to the focus plus the reach.
var far_plane := 0.0
## The ground's furthest depth in view as the rig sees it now (INF: the horizon).
var view_depth := 0.0
var _owns_fog := false
var _set_far := false


func _ready() -> void:
	process_priority = 5  # after the camera rig moved the camera, before the shadows fit to it


## The reach in tiles for the settings now (<= 0: off).
func reach_tiles() -> float:
	if setting < 0.0:
		return 0.0
	if setting > 0.0:
		return setting
	return clampf(view_radius * 32.0 * AUTO_SHARE, REACH_RANGE.x, REACH_RANGE.y)


func _process(_delta: float) -> void:
	var cam: Camera3D = rig.camera if rig != null and is_instance_valid(rig) else null
	reach = reach_tiles()
	var hold := cam != null and reach > 0.0 and _may_hold()
	view_depth = ground_depth(cam, rig.global_position.y if rig != null else 0.0) if cam != null else 0.0
	# The camera's distance to the focus (it looks at it), then the reach on from there.
	var near: float = float(rig.distance) if rig != null else 0.0
	far_plane = near + reach
	hold = hold and view_depth + TALL_MARGIN > far_plane
	if hold:
		if not is_equal_approx(cam.far, far_plane):
			cam.far = far_plane
		_set_far = true
		# 0 just past the line, 1 once the ground in view reaches half the reach again beyond it.
		var past := 1.0 if view_depth == INF else clampf((view_depth + TALL_MARGIN - far_plane) / (reach * 0.5), 0.0, 1.0)
		_fog(true, near + reach * lerpf(FOG_BEGIN.x, FOG_BEGIN.y, past), far_plane, past)
	else:
		_let_go(cam)
	active = hold


## Only the player's own angled view in perspective, not a screenshot in full detail.
func _may_hold() -> bool:
	if rig.first_person or rig.taken() or rig.in_cinematic() or ModelLods.full_detail:
		return false
	if rig.camera.projection != Camera3D.PROJECTION_PERSPECTIVE:
		return false
	return true


func _let_go(cam: Camera3D) -> void:
	if _set_far and cam != null and is_instance_valid(cam) and not rig.taken():
		if is_equal_approx(cam.far, far_plane) or cam.far < FULL_FAR:
			cam.far = FULL_FAR
	_set_far = false
	_fog(false, 0.0, 0.0, 0.0)


## The depth (along the view) of the furthest ground at the top of the screen, from a camera
## `height` tiles over the focus's ground: INF when the top edge looks at or over the horizon.
static func ground_depth(cam: Camera3D, focus_height: float) -> float:
	var half := deg_to_rad(cam.fov) * 0.5
	var forward := -cam.global_basis.z
	var down := asin(clampf(-forward.y, -1.0, 1.0))  # the view's tilt below the horizon
	var top := down - half  # the top edge's
	if top <= deg_to_rad(0.5):
		return INF
	var height := cam.global_position.y - focus_height
	if height <= 0.0:
		return INF
	return height / sin(top) * cos(half)


## Zenith's depth fog for the reach: on from `begin` to `end` tiles, off again. Its colour is the
## sky's haze colour (planet_sky.gdshader haze_color), and the sky's own horizon haze rises with it
## (`past`, 0-1): the fog's colour taken from the sky's radiance (aerial perspective) had none of
## the low clouds the sky draws over the cut, which showed as a grey wall under a dark band.
## Left alone while a look has fog of its own on.
func _fog(on: bool, begin: float, end: float, past: float) -> void:
	if env == null:
		return
	var sky_mat := _sky_material()
	if on:
		if not _owns_fog:
			if env.fog_enabled:
				return  # a look's own fog
			_owns_fog = true
			env.fog_mode = Environment.FOG_MODE_DEPTH
			env.fog_light_energy = 1.0
			env.fog_sun_scatter = 0.0
			env.fog_density = 1.0
			env.fog_aerial_perspective = 0.0 if sky_mat != null else 1.0
			env.fog_sky_affect = 0.0
			env.fog_height_density = 0.0
			# Clear for longer, then closing in: the near ground keeps its colours.
			env.fog_depth_curve = 1.6
			env.fog_enabled = true
		if sky_mat != null:
			var haze = sky_mat.get_shader_parameter("haze_color")
			if haze is Color and not env.fog_light_color.is_equal_approx(haze):
				env.fog_light_color = haze
			sky_mat.set_shader_parameter("horizon_haze", smoothstep(0.0, 1.0, past))
		if absf(env.fog_depth_begin - begin) > 0.5 or absf(env.fog_depth_end - end) > 0.5:
			env.fog_depth_begin = begin
			env.fog_depth_end = end
	elif _owns_fog:
		_owns_fog = false
		env.fog_enabled = false
		env.fog_mode = Environment.FOG_MODE_EXPONENTIAL
		if sky_mat != null:
			sky_mat.set_shader_parameter("horizon_haze", 0.0)


## The planet sky's material (planet_sky.gdshader), or null (space, a look's own sky).
func _sky_material() -> ShaderMaterial:
	if env == null or env.sky == null:
		return null
	var mat := env.sky.sky_material as ShaderMaterial
	if mat == null or mat.shader == null or mat.shader.resource_path != "res://shaders/planet_sky.gdshader":
		return null
	return mat


## One line for the debug line (F4).
func status() -> String:
	if reach <= 0.0:
		return "horizon reach off"
	if not active:
		return "horizon reach %d tiles (not needed: ground in view ends at %s)" % [int(reach), "horizon" if view_depth == INF else "%d" % int(view_depth)]
	return "horizon reach %d tiles (far %d) holds the view (ground would reach %s)%s" % [int(reach), int(far_plane), "the horizon" if view_depth == INF else "%d tiles" % int(view_depth),
		"" if _owns_fog else ", a look's own fog"]
