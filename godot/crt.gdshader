shader_type canvas_item;

// Qud-style CRT terminal overlay: a SHARP interlace + an edge vignette, applied TOGETHER (so the
// interlace stays visible even inside the vignette, like Qud). Full-rect ColorRect on a top CanvasLayer.
// It reads the framebuffer, lifts every other LOGICAL row toward grey (the interlace), then darkens
// toward the corners (the vignette), and writes the result opaquely.
//
// INTERLACE: measured off Qud — a hard period-2 scanline. The chrome's dark rows are the base
// #0c0f10 ≈ (11,14,15); the lit rows lift ~+(9,9,11) to ~(20,23,26).

uniform sampler2D screen_tex : hint_screen_texture, filter_nearest;

uniform float scanline_lift : hint_range(0.0, 0.2) = 0.042;  // grey added to the lit rows (~+10/255)
uniform float scanline_period : hint_range(1.0, 6.0) = 2.0;  // LOGICAL px per scanline pair (Qud ≈ 2)
uniform float px_per_logical : hint_range(1.0, 3.0) = 1.0;   // framebuffer px per logical px (allow_hidpi off -> 1)
uniform float vignette_strength : hint_range(0.0, 1.0) = 0.42;
uniform float vignette_feather : hint_range(0.05, 1.0) = 0.55;

void fragment() {
	vec3 col = texture(screen_tex, SCREEN_UV).rgb;

	// Interlace: lift every other LOGICAL row toward grey (sharp, hard-edged — Qud's period-2 look).
	// FRAGCOORD is framebuffer px; /px_per_logical maps to logical rows so the app's 2x render → 1x
	// screenshot keeps period-2 (period-4 physical) instead of averaging period-2-physical into a flat
	// lift. (A hardcoded 2.0 works on Retina; the DisplayServer DPI query was unreliable.)
	float lit = mod(floor(FRAGCOORD.y / (px_per_logical * scanline_period * 0.5)), 2.0);
	col += scanline_lift * lit;

	// Vignette: darken toward the corners (multiplicative, so it never cancels the interlace).
	vec2 d = SCREEN_UV - vec2(0.5);
	float dist = length(d) / 0.70710678;                    // normalise so a corner ~= 1.0
	float vig = vignette_strength * smoothstep(1.0 - vignette_feather, 1.0, dist);
	col *= (1.0 - vig);

	COLOR = vec4(col, 1.0);
}
