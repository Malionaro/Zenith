shader_type spatial;
// A tree crown's shadow stand-in (model_lods.gd crown_arrays): its leaf cards drawn in to the spray
// their leaves cast, its cores and solid leaves, drawn only into the sun's shadow map, dropping what
// pollution took as the crown itself does (factorio_material.gdshaderinc LEAF_CUT): a card when its
// leaves have fallen (each by its own hash, all of them once the tree is bare), a core half way, solid
// leaves over the leaves' range. Welded in with the trunk, a bare tree cast its whole crown's shadow.
// UV: (the card's seed, its kind: 0 card, 1 core, 2 solid leaves). Lifted by the hills as the model is.

render_mode unshaded;

#include "res://shaders/noise.gdshaderinc"
#include "res://shaders/ground_height.gdshaderinc"
#include "res://shaders/pollution.gdshaderinc"

void vertex() {
	// As factorio_material.gdshaderinc reads it per tree: where it stands, a little ahead or behind.
	vec2 origin = MODEL_MATRIX[3].xz;
	float seed = hash12(origin * 3.17 + 0.5);
	float dying = clamp(pollution_at(origin).x * 1.3 - 0.3 * seed, 0.0, 1.0);
	bool gone;
	if (UV.y > 1.5) {
		gone = smoothstep(0.05, 0.95, dying) >= 0.5;
	} else if (UV.y > 0.5) {
		gone = smoothstep(0.1, 0.6, dying) >= 0.5;
	} else {
		vec2 off = vec2(UV.x * 61.0, UV.x * 37.0);
		gone = dying >= 0.98 || (dying > 0.0 && hash12(off + 71.3) < dying * 0.95);
	}
	// Gone: every corner at one point, so the triangle draws nothing.
	VERTEX = gone ? vec3(0.0) : ground_lift(VERTEX, MODEL_MATRIX);
}

void fragment() {
	ALBEDO = vec3(0.0);
}
