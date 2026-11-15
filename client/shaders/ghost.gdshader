shader_type spatial;
// Factorio's entity ghosts: the entity drawn in a translucent blue-white, unlit so it reads the
// same by day and night. Shaded as Factorio's ghost sprites keep their picture's light and dark: by a
// fixed light from the north-west (the sprites' own), by the part's colour where the model has one
// (CUSTOM1, part_colors.py) and its baked occlusion (COLOR.a), with a brighter rim at the silhouette.
//
// ghosts.gd draws the map's ghosts after ghost_depth.gdshader has laid down their depth (its
// next_pass is this, render_priority one higher): only each ghost's front-most surface is drawn,
// one translucent layer, instead of every inner face and part showing through in whatever order
// they come (owner's I11: "ghost models look rough"). The build preview draws this alone. A held
// blueprint's preview (blueprint_preview.gd) is drawn the same two passes and colours each instance
// from its MultiMesh custom data (`instance_tint`): red (`bad_tint`) where that entity can't be built.
render_mode unshaded, blend_mix, depth_draw_always, cull_back, shadows_disabled;

#include "res://shaders/ground_height.gdshaderinc"

uniform vec4 tint : source_color = vec4(0.58, 0.68, 1.0, 0.42);
// A slow band of light rising through the ghost, faint (0 off: the build preview, reach boxes).
uniform float shimmer = 0.0;
// Pushes the surface out along its normal (tiles): a ghost over a building of the same shape (an
// upgrade's, a fast-replace's) doesn't flicker against it, and the front surface stays just in front
// of the depth ghost_depth.gdshader wrote for it.
uniform float inflate = 0.004;
// Each instance's INSTANCE_CUSTOM.r: 0 `tint`, 1 `bad_tint` (only MultiMeshes with custom data).
uniform bool instance_tint = false;
uniform vec4 bad_tint : source_color = vec4(1.0, 0.3, 0.25, 0.5);

varying vec3 part;
varying float occlusion;
varying float world_y;
varying flat float bad;

void vertex() {
	VERTEX += NORMAL * inflate;
	VERTEX = ground_lift(VERTEX, MODEL_MATRIX);
	// The part's colour as its brightness (CUSTOM1.a: how much of it comes from the sprite; 0 on
	// meshes without part colours, which then shade by their normal alone).
	part = CUSTOM1.a > 0.0 ? CUSTOM1.rgb : vec3(-1.0);
	occlusion = clamp(COLOR.a, 0.0, 1.0);
	world_y = (MODEL_MATRIX * vec4(VERTEX, 1.0)).y;
	bad = instance_tint ? clamp(INSTANCE_CUSTOM.r, 0.0, 1.0) : 0.0;
}

void fragment() {
	vec3 world_n = normalize((INV_VIEW_MATRIX * vec4(NORMAL, 0.0)).xyz);
	float facing = clamp(dot(world_n, normalize(vec3(-0.45, 0.8, -0.4))) * 0.5 + 0.5, 0.0, 1.0);
	// Part colours are stored with headroom (factorio_material.gdshaderinc PART_RANGE): only how dark
	// one part is against another matters here, squashed so black parts don't vanish.
	float value = part.r >= 0.0 ? clamp(sqrt(dot(part, vec3(0.3, 0.59, 0.11))) * 1.6, 0.35, 1.15) : 0.85;
	float shade = (0.55 + 0.45 * facing) * mix(1.0, value, 0.6) * mix(0.7, 1.0, occlusion);
	float rim = pow(1.0 - clamp(dot(NORMAL, VIEW), 0.0, 1.0), 3.0);
	float band = shimmer > 0.0 ? shimmer * smoothstep(0.85, 1.0, sin(world_y * 3.0 - TIME * 1.6) * 0.5 + 0.5) : 0.0;
	vec4 t = mix(tint, bad_tint, bad);
	ALBEDO = t.rgb * shade + vec3(rim * 0.3 + band * 0.25);
	ALPHA = clamp(t.a + rim * 0.18 + band * 0.08, 0.0, 1.0);
}
