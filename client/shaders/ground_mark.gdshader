shader_type spatial;
// Plain marks on the ground that the world in front hides (demolisher territories' borders, modded
// robots' drop shadows, the throw and wire tools' rings, the tile brush): see-through and unshaded, as
// a StandardMaterial3D's alpha, but riding on the hills (ground_height.gdshaderinc) as the ground does.
// `tint`, times the vertex colour when `vertex_color` (a model's own vertex colours hold its baked
// weathering, not a colour: its drop shadow leaves them out). Factorio's marks drawn over everything
// use ground_overlay.gdshader.
render_mode unshaded, blend_mix, cull_disabled, shadows_disabled;

#include "res://shaders/ground_height.gdshaderinc"

uniform vec4 tint : source_color = vec4(1.0);
uniform bool vertex_color = true;

void vertex() {
	VERTEX = ground_lift(VERTEX, MODEL_MATRIX);
}

void fragment() {
	vec4 c = vertex_color ? COLOR * tint : tint;
	ALBEDO = c.rgb;
	ALPHA = c.a;
}
