shader_type spatial;
// The map's ghosts' depth, laid down before their colour (ghosts.gd: this material's next_pass is
// ghost.gdshader, one render_priority later, so every ghost's depth is in before any is coloured).
// Nothing of it shows: fully transparent, depth only. ghost.gdshader then draws only the nearest
// surface of each pixel, and a ghost's own inner faces and parts, and the ghosts behind it, no longer
// pile up into blotchy layers.
//
// The surface here is the model's own; ghost.gdshader pushes its surface out along the normal by
// its `inflate` (a few thousandths of a tile), which for a face turned to the camera is towards it,
// so the front surface always passes the depth test against what this wrote (no reliance on two
// shaders giving bit-equal depths) and anything further in than that fails it.
render_mode unshaded, blend_mix, depth_draw_always, cull_back, shadows_disabled;

#include "res://shaders/ground_height.gdshaderinc"

void vertex() {
	VERTEX = ground_lift(VERTEX, MODEL_MATRIX);
}

void fragment() {
	ALBEDO = vec3(0.0);
	ALPHA = 0.0;
}
