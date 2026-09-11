#version 120
#include "/lib/settings.glsl"

#if RESOURCEPACK_SKY != 0 || defined VANILLA_MOON
	varying vec4 color;
	varying vec2 texcoord;
	uniform sampler2D texture;
	
	uniform int renderStage;

	float interleaved_gradientNoise(){
		// vec2 coord = gl_FragCoord.xy + (frameCounter%40000);
		vec2 coord = gl_FragCoord.xy ;
		// vec2 coord = gl_FragCoord.xy;
		float noise = fract( 52.9829189 * fract( (coord.x * 0.06711056) + (coord.y * 0.00583715)) );
		return noise ;
	}
#endif

void main() {

	#if RESOURCEPACK_SKY != 0 || defined VANILLA_MOON
		/* RENDERTARGETS:10 */

		vec4 COLOR = texture2D(texture, texcoord.xy)*color;

		// With Bliss' resource-pack sky disabled, this pass exists only to
		// capture Minecraft's moon.  Reject the vanilla sun and any other
		// textured sky stage so composite1 can keep Bliss' procedural sun.
		#if defined VANILLA_MOON && RESOURCEPACK_SKY == 0
			if (renderStage != 5) discard;
		#endif

		if(renderStage == 4) COLOR.rgb *= 5.0;
		// if(renderStage == 5) COLOR.rgb *= 1.5;

		// The procedural sky uses this dither to hide banding, but applying it
		// to the vanilla moon creates a visible pixel grid around the moon when
		// it is composited together with procedural stars.
		#ifdef VANILLA_MOON
			if (renderStage != 5) {
				COLOR.rgb = max(COLOR.rgb * (0.9+0.1*interleaved_gradientNoise()), 0.0);
			}
		#else
			COLOR.rgb = max(COLOR.rgb * (0.9+0.1*interleaved_gradientNoise()), 0.0);
		#endif
		
		gl_FragData[0] = vec4(COLOR.rgb/255.0, COLOR.a);
	#else
		discard;
	#endif
}
