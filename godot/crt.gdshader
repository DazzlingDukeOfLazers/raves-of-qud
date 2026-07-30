shader_type canvas_item;

// Qud-style CRT terminal overlay: darkening scanlines + an edge vignette, giving the "viewed through
// an old monitor" look (wiki Visual Style). Meant for a full-rect ColorRect on a CanvasLayer ABOVE
// everything — it draws BLACK with a computed alpha, so it just darkens whatever chrome / 3D is behind
// (no SCREEN_TEXTURE read-back needed). Tune the uniforms live; all effects fade out at strength 0.

// Scanlines
uniform float scanline_strength : hint_range(0.0, 1.0) = 0.16;   // how dark the dim rows get
uniform float scanline_period_px = 5.0;                          // framebuffer px per scanline pair

// Vignette (edge darkening) — kept gentle so the corner command-bar items stay readable.
uniform float vignette_strength : hint_range(0.0, 1.0) = 0.42;   // darkness reached at the corners
uniform float vignette_feather : hint_range(0.05, 1.0) = 0.55;   // how far in the falloff starts

void fragment() {
	// Scanline: soft dark band on the lower part of each period, from the framebuffer pixel row.
	float band = fract(FRAGCOORD.y / max(scanline_period_px, 1.0));
	float scan = scanline_strength * smoothstep(0.45, 1.0, band);

	// Vignette: 0 at the centre, ramping to vignette_strength toward the corners.
	vec2 d = SCREEN_UV - vec2(0.5);
	float dist = length(d) / 0.70710678;          // normalise so a corner ~= 1.0
	float vig = vignette_strength * smoothstep(1.0 - vignette_feather, 1.0, dist);

	COLOR = vec4(0.0, 0.0, 0.0, clamp(scan + vig, 0.0, 1.0));
}
