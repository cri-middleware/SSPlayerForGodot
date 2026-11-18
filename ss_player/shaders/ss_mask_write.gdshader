R"GLSL(
// Mask coverage write shader.
//
// Used only for rendering mask-writer geometry into a pooled coverage bitmap
// (an offscreen RGBA8 viewport the player borrows while it masks). Each writer
// gets one of up to 96 bits (24 per tile); `mask_bit_color` carries that bit
// pre-encoded into the right RGB channel. Additive blending then ORs the
// disjoint bits together across writers.
//
// LIMITATION: add is only equivalent to OR while no texel receives the same bit
// twice. That holds across writers (their bits are disjoint) and for the quad /
// pentagon and triangulated-shape geometry we emit, but a single writer whose
// own triangles overlap (e.g. a bone-deformed mesh folded onto itself) adds its
// bit twice into the shared texels, which carries into the neighbouring bit —
// those texels then read as a different writer's mask. Godot's canvas render
// modes offer no saturating (max) blend, so fixing this properly needs a
// stencil-style write rather than a shader change.
//
// Cutout: a texel contributes to the mask only where the writer sprite's alpha
// is strictly greater than `mask_threshold`. The player derives the threshold
// from the part's `mask` attribute (PartState.mask()); mask == 0 maps to
// threshold 1.0 so nothing is written (empty mask). Shape masks with no bound
// texture sample the default white texture (alpha 1.0) and so write their full
// geometry whenever the threshold is below 1.0.
shader_type canvas_item;
render_mode blend_add, unshaded;

uniform vec4 mask_bit_color;
uniform float mask_threshold;

void fragment() {
	// Cutout: only texels above the mask threshold contribute to the mask.
	if (texture(TEXTURE, UV).a <= mask_threshold) {
		discard;
	}
	// Godot's canvas `blend_add` is premultiplied (src.rgb * src.a), so the bit
	// must be written with alpha 1 or it is dropped. Bits live in R/G/B only
	// (24 writers a tile); the alpha channel is the "any coverage" accumulator.
	COLOR = vec4(mask_bit_color.rgb, 1.0);
}
)GLSL"
