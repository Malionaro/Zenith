# Cinematic shaders: changes

Newest first. Versions before 0.4.5 are summarised from Zenith's history.

## 0.4.5 (with Zenith 0.2.1)

The same picture for less GPU time.

- The clouds' pattern is drawn once into a texture when the add-on starts (`shaders/cloud_field.gdshader`,
  1024 x 1024 at 16 bits a channel, about 8 MB of video memory), and the grade reads it: one texture read
  where it worked out the noise before, up to 48 sines and cosines for a pixel of cloud shadow on the
  ground and about 150 noise calls for a pixel of sky. The pattern now repeats every 1,800 tiles or so; it
  is the same kind of noise at the same sizes, but the clouds are new shapes (the old noise couldn't be
  made to repeat as it was). Most saved in first person or with a low camera, where the sky is in view;
  from above the clouds measured 0.13-0.25 ms at 4K before.
  Ported to numpy, the two cover the sky and ground alike (17.8% of the ground's shadow layer against
  16.9%, 36.2% of the sky's widest layer against 35.5%) and the field wraps without a seam.
- The grade skips reads that changed nothing: the far softening where nothing is softened (from above,
  nearly the whole screen), and the colour fringe's two extra reads where red and blue would land less
  than a quarter of a pixel from green (the middle of the screen).
- With Zenith 0.2.1: the look's temporal anti-aliasing (off by default) runs in place of SMAA instead of
  over it (SMAA under it measured 0.37-0.40 ms at 4K), and Zenith draws the grade before any ground
  clutter that shares its render priority (some flat clutter near the map's origin was drawn first and
  then covered by it).

Not yet seen in a window: the clouds by day, at dusk and at night, and the fringe at the screen's edges.

## Before

- 0.4.4: ambient occlusion lighter (intensity 2.2 -> 1.5), bounce light (SSIL) its own option, off by
  default; with ambient occlusion off the grade no longer makes Godot's depth pre-pass write normals.
- 0.4.3: on a space platform the grade leaves the black backdrop and its stars alone.
- 0.4.2: the grade reads the screen finite and never darkens a pixel below a quarter of itself (black
  boxes round sun glints on Aquilo's and Gleba's water).
- 0.4.1: no clouds or cloud shadows on space platforms.
- 0.4.0: a real sunrise and sunset: exposure, sky-lit ambient, fog, shadows and the grade keyed to the
  sun, dawn mist, clouds that catch the light, a blue hour; one Sunrise and sunset slider.
- 0.3.0: the look owns its clouds, TAA and roughness limiter (add-on API 1.4).
- 0.2.2: a roughness floor of 0.55; TAA off by default (shader-animated inserter arms and belts flickered
  under it).
- 0.2.1: the roughness limiter while the look is on, bloom capped per pixel, calmer bounce light.
- 0.2.0: the add-on is the look; sharpening faded with distance; clouds in the sky and their shadows.
- First version with Zenith's shader API (add-on API 1.3).
