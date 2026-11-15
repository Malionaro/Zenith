// Pollution round the focus (scripts/world/pollution.gd, the bridge's `pol`): one texel a chunk,
// red how far its trees are dying and its water greening (0 healthy, 1 bare trees), green how thick
// its smog is. Read bilinearly between chunk centres, as ground_height.gdshaderinc reads the hills
// (texelFetch, so no sampler setting can change it), so nothing changes in steps at chunk edges.
// Off (f3d_pollution_rect.w 0: no pollution, a space platform) it is 0 everywhere.

global uniform sampler2D f3d_pollution;
// The first texel's corner (x, z) in tiles, tiles a texel (32), and 1 while there is pollution.
global uniform vec4 f3d_pollution_rect;

vec2 pollution_texel(ivec2 i, ivec2 size) {
	if (i.x < 0 || i.y < 0 || i.x >= size.x || i.y >= size.y) {
		return vec2(0.0);
	}
	return texelFetch(f3d_pollution, i, 0).rg;
}

// (dying, smog) at a world point (x, z in tiles).
vec2 pollution_at(vec2 xz) {
	if (f3d_pollution_rect.w < 0.5) {
		return vec2(0.0);
	}
	ivec2 size = textureSize(f3d_pollution, 0);
	vec2 g = (xz - f3d_pollution_rect.xy) / f3d_pollution_rect.z - 0.5;
	if (g.x < -1.0 || g.y < -1.0 || g.x > float(size.x) || g.y > float(size.y)) {
		return vec2(0.0);
	}
	ivec2 i = ivec2(floor(g));
	vec2 f = g - vec2(i);
	vec2 a = mix(pollution_texel(i, size), pollution_texel(i + ivec2(1, 0), size), f.x);
	vec2 b = mix(pollution_texel(i + ivec2(0, 1), size), pollution_texel(i + ivec2(1, 1), size), f.x);
	return mix(a, b, f.y);
}
