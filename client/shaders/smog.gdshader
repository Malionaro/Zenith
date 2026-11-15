// Smog over polluted ground (scripts/world/pollution.gd, Settings > Graphics > Smog), in one
// full-screen pass after the world, as the remote view's fog is drawn: a layer of haze `height`
// tiles deep lies on the ground wherever the chunks' pollution says (pollution.gdshaderinc, green).
// Each pixel's view ray is cut to that layer between the camera and what the depth buffer has there,
// and the length inside it thickens the haze: looked at from above it is a veil, along the ground
// in first person it closes in over distance, and a tall building's top stands out of it.
shader_type spatial;
render_mode unshaded, depth_draw_never, depth_test_disabled, cull_disabled, fog_disabled, shadows_disabled;

#include "res://shaders/noise.gdshaderinc"
#include "res://shaders/ground_height.gdshaderinc"
#include "res://shaders/pollution.gdshaderinc"

uniform sampler2D depth_texture : hint_depth_texture, filter_nearest;
// The Smog setting, 0 to 1 (0.5 by default).
uniform float strength = 0.5;
// How deep the haze lies over the ground, in tiles.
uniform float height = 5.0;
// Haze per tile of view ray through it, at the worst pollution.
uniform float density = 0.08;
// Factorio's pollution is a brownish grey (its map's pollution overlay, its smoke).
uniform vec3 smog_color : source_color = vec3(0.37, 0.34, 0.27);
// The day's light on it (pollution.gd, from the game's darkness): unshaded, so it dims by hand.
uniform float light = 1.0;
// Where nothing was drawn (the sky), how far the ray is taken.
uniform float far = 600.0;

void vertex() {
	POSITION = vec4(VERTEX.xy, 1.0, 1.0);
}

vec3 view_point(vec2 uv, float depth, mat4 inv_projection) {
	vec4 p = inv_projection * vec4(uv * 2.0 - 1.0, depth, 1.0);
	return p.xyz / p.w;
}

void fragment() {
	// The ray worked out in view space and then turned into the world (remote_fog.gdshader: two
	// points near the camera subtracted in world space lose precision far from the map's origin).
	// Reverse depth: 1 is the near plane.
	vec3 near_v = view_point(SCREEN_UV, 1.0, INV_PROJECTION_MATRIX);
	vec3 dir = normalize(mat3(INV_VIEW_MATRIX) * (view_point(SCREEN_UV, 0.5, INV_PROJECTION_MATRIX) - near_v));
	vec3 origin = (INV_VIEW_MATRIX * vec4(near_v, 1.0)).xyz;
	float depth = texture(depth_texture, SCREEN_UV).r;
	vec3 end = origin + dir * far;
	if (depth > 0.0) {
		end = (INV_VIEW_MATRIX * vec4(view_point(SCREEN_UV, depth, INV_PROJECTION_MATRIX), 1.0)).xyz;
	}
	// The layer: from a tile under the ground (banks, water) to `height` over it, the hills' ground
	// taken where the ray ends.
	float ground = ground_h(end.xz);
	float y0 = ground - 1.0;
	float y1 = ground + height;
	vec3 d = end - origin;
	float t0 = 0.0;
	float t1 = 1.0;
	if (abs(d.y) > 1e-5) {
		float ta = (y0 - origin.y) / d.y;
		float tb = (y1 - origin.y) / d.y;
		t0 = max(t0, min(ta, tb));
		t1 = min(t1, max(ta, tb));
	} else if (origin.y < y0 || origin.y > y1) {
		discard;
	}
	if (t1 <= t0) {
		discard;
	}
	vec3 a = origin + d * t0;
	vec3 b = origin + d * t1;
	// The pollution where the ray goes in and where it leaves, so a long ray along the ground (first
	// person) takes in both ends of its way through.
	float s = 0.5 * (pollution_at(a.xz).g + pollution_at(b.xz).g);
	if (s < 0.002) {
		discard;
	}
	vec2 mid = 0.5 * (a.xz + b.xz);
	// Slowly drifting patches, so it reads as a haze rather than a tint.
	float n = fbm3(mid * 0.035 + TIME * vec2(0.012, 0.005));
	float k = density * s * (0.55 + 0.9 * n);
	float thick = 1.0 - exp(-k * distance(a, b));
	ALBEDO = smog_color * light;
	ALPHA = clamp(thick * strength * 1.6, 0.0, 0.85);
}
