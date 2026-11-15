shader_type spatial;
// The debug menu's bridge update overlays (scripts/debug/update_overlay.gd): a rectangle on the ground
// per update, outlined or filled, fading out over `fade` seconds from when it was drawn. Over everything
// (no depth test, so buildings don't hide it) and riding on the hills (ground_height.gdshaderinc). One
// MultiMesh per kind of update, a flat 1 x 1 plane per rectangle turned and scaled to it by the instance
// transform; INSTANCE_CUSTOM: x when it was drawn (seconds on the overlay's clock, `now`; -1 stays as
// it is, -2 pulses), y and z its size (tiles), w its outline's width (tiles; 0 filled). The instance
// colour is the kind's. Fading is all here: the overlay writes an instance once, when it is drawn.
render_mode unshaded, blend_mix, depth_test_disabled, depth_draw_never, cull_disabled, shadows_disabled, fog_disabled;

#include "res://shaders/ground_height.gdshaderinc"

uniform float now = 0.0;
uniform float fade = 1.0;
// An outline's inside, as a share of its colour's alpha: faint, so what it outlines still shows.
uniform float fill = 0.14;

varying flat vec4 v_color;
varying flat vec3 v_shape;  // size x, size z, outline width

void vertex() {
	float born = INSTANCE_CUSTOM.x;
	float a = 1.0;
	if (born >= 0.0) {
		a = 1.0 - (now - born) / fade;
	} else if (born < -1.5) {
		a = 0.6 + 0.4 * sin(now * 7.0);
	}
	v_color = vec4(COLOR.rgb, COLOR.a * clamp(a, 0.0, 1.0));
	v_shape = INSTANCE_CUSTOM.yzw;
	if (v_color.a <= 0.0) {
		VERTEX = vec3(0.0);  // faded: a point, no pixels
	} else {
		VERTEX = ground_lift(VERTEX, MODEL_MATRIX);
	}
}

void fragment() {
	vec2 size = max(v_shape.xy, vec2(0.001));
	vec2 p = UV * size;
	// Tiles to the nearest edge; the outline at least a pixel and a half wide however far out.
	float e = min(min(p.x, size.x - p.x), min(p.y, size.y - p.y));
	float a = v_color.a;
	if (v_shape.z > 0.0) {
		float w = max(v_shape.z, fwidth(e) * 1.5);
		a *= max(1.0 - smoothstep(w * 0.7, w, e), fill);
	}
	if (a < 0.004) {
		discard;
	}
	ALBEDO = v_color.rgb;
	ALPHA = a;
}
