uniform int framemod8;

#include "/lib/reflection_history.glsl"

const vec2[8] offsets = vec2[8](vec2(1./8.,-3./8.),
									vec2(-1.,3.)/8.,
									vec2(5.0,1.)/8.,
									vec2(-3,-5.)/8.,
									vec2(-5.,5.)/8.,
									vec2(-7.,-1.)/8.,
									vec2(3,7.)/8.,
									vec2(7.,-7.)/8.);

vec3 lerp(vec3 X, vec3 Y, float A){
	return X * (1.0 - A) + Y * A;
}

float lerp(float X, float Y, float A){
	return X * (1.0 - A) + Y * A;
}

float square(float x){
  return x*x;
}



vec3 toClipSpace3(vec3 viewSpacePosition) {
    return projMAD(gbufferProjection, viewSpacePosition) / -viewSpacePosition.z * 0.5 + 0.5;
}
float invLinZ (float lindepth){
	return -((2.0*near/lindepth)-far-near)/(far-near);
}
float linZ(float depth) {
    return (2.0 * near) / (far + near - depth * (far - near));
	// l = (2*n)/(f+n-d(f-n))
	// f+n-d(f-n) = 2n/l
	// -d(f-n) = ((2n/l)-f-n)
	// d = -((2n/l)-f-n)/(f-n)

}

void frisvad(in vec3 n, out vec3 f, out vec3 r){
    if(n.z < -0.9) {
        f = vec3(0.,-1,0);
        r = vec3(-1, 0, 0);
    } else {
    	float a = 1./(1.+n.z);
    	float b = -n.x*n.y*a;
    	f = vec3(1. - n.x*n.x*a, b, -n.x) ;
    	r = vec3(b, 1. - n.y*n.y*a , -n.y);
    }
}

mat3 CoordBase(vec3 n){
	vec3 x,y;
    frisvad(n,x,y);
    return mat3(x,y,n);
}

vec2 R2_Sample(int n){
	vec2 alpha = vec2(0.75487765, 0.56984026);
	return fract(alpha * n);
}

vec3 rayTraceSpeculars(vec3 dir, vec3 position, float dither, float quality, bool hand, inout float reflectLength){

	vec3 clipPosition = toClipSpace3(position);
	float rayLength = ((position.z + dir.z * far*sqrt(3.)) > -near) ?
	                   (-near -position.z) / dir.z : far*sqrt(3.);
	vec3 direction = toClipSpace3(position+dir*rayLength)-clipPosition;

	//get at which length the ray intersects with the edge of the screen
	float mult = BlissReflectionRayLimit(clipPosition, direction);

	vec3 stepv = direction * mult / quality*vec3(RENDER_SCALE,1.0);

	vec3 spos = clipPosition*vec3(RENDER_SCALE,1.0) + stepv*dither;

	float minZ = spos.z;
	float maxZ = spos.z;
	
	vec2 jitterOffset = TAA_Offset*texelSize*0.5;
	spos.xy += jitterOffset;
	float depthcancleoffset = pow(1.0-(quality/reflection_quality),1.0);

	float dist = 1.0 + clamp(position.z*position.z/50.0,0.0,2.0); // shrink sample size as distance increases
  	for (int i = 0; i <= int(quality); i++) {
		if (any(lessThanEqual(spos.xy, vec2(0.0))) || any(greaterThanEqual(spos.xy, RENDER_SCALE)) || spos.z <= 0.0 || spos.z >= 1.0) break;

		vec2 scaleUV = hand ? spos.xy*texelSize : spos.xy/texelSize/4.0; // fix for ssr on hand
		float sp = sqrt(texelFetch2D(colortex4,ivec2(scaleUV),0).a/65000.0);


		sp = invLinZ(sp);

		if(sp <= max(maxZ,minZ) && sp >= min(maxZ,minZ) ) return vec3((spos.xy-jitterOffset)/RENDER_SCALE,sp);
		spos += stepv;
		
		//small bias
		float biasamount = (0.0002 + 0.0015*pow(depthcancleoffset,5) ) / dist;
		// float biasamount = 0.0002 / dist;
		if(hand) biasamount = 0.01;
		minZ = maxZ-biasamount / ld(spos.z);
		maxZ += stepv.z;

		reflectLength += 1.0 / quality; // for shit

  	}
  return vec3(1.1);
}

vec3 rayTracePuddleSpeculars(vec3 dir, vec3 position, float dither, inout float reflectLength){
	const float puddleTraceQuality = 64.0;
	vec3 clipPosition = toClipSpace3(position);
	float maximumDistance = far * sqrt(3.0);
	float rayLength = ((position.z + dir.z * maximumDistance) > -near)
		? (-near - position.z) / dir.z
		: maximumDistance;
	vec3 direction = toClipSpace3(position + dir * rayLength) - clipPosition;
	if (dot(direction, direction) < 1e-12) return vec3(1.1);

	float maximumLength = BlissReflectionRayLimit(clipPosition, direction);
	if (maximumLength <= 0.0) return vec3(1.1);

	vec3 stepVector = direction * maximumLength / puddleTraceQuality * vec3(RENDER_SCALE, 1.0);
	vec2 jitterOffset = TAA_Offset * texelSize * 0.5;
	vec3 screenPosition = clipPosition * vec3(RENDER_SCALE, 1.0) + stepVector * (1.0 + dither);
	screenPosition.xy += jitterOffset;

	float minimumDepth = screenPosition.z;
	float maximumDepth = screenPosition.z;
	float distanceScale = 1.0 + clamp(position.z * position.z / 50.0, 0.0, 2.0);

	for (int stepIndex = 0; stepIndex < 64; stepIndex++) {
		if (screenPosition.x <= 0.0 || screenPosition.y <= 0.0 || screenPosition.x >= RENDER_SCALE.x || screenPosition.y >= RENDER_SCALE.y || screenPosition.z <= 0.0 || screenPosition.z >= 1.0) break;

		float sceneDepth = texelFetch2D(depthtex1, ivec2(screenPosition.xy / texelSize), 0).x;
		float lowerDepth = min(minimumDepth, maximumDepth);
		float upperDepth = max(minimumDepth, maximumDepth);
		if (stepIndex > 1 && sceneDepth < 1.0 && sceneDepth >= lowerDepth && sceneDepth <= upperDepth) {
			vec2 hitUV = (screenPosition.xy - jitterOffset) / RENDER_SCALE;
			return vec3(hitUV, sceneDepth);
		}

		screenPosition += stepVector;
		float depthThickness = 0.00035 / (max(ld(clamp(screenPosition.z, 0.0, 1.0)), 1e-5) * distanceScale);
		minimumDepth = maximumDepth - depthThickness;
		maximumDepth += stepVector.z;
		reflectLength += 1.0 / puddleTraceQuality;
	}

	return vec3(1.1);
}

float fma(float a,float b,float c){
 return a * b + c;
}

//// thank you Zombye | the paper: https://ggx-research.github.io/publication/2023/06/09/publication-ggx.html
vec3 SampleVNDFGGX(
    vec3 viewerDirection, // Direction pointing towards the viewer, oriented such that +Z corresponds to the surface normal
    vec2 alpha, // Roughness parameter along X and Y of the distribution
    float xy // Pair of uniformly distributed numbers in [0, 1)
) {
	// alpha *= alpha;
    // Transform viewer direction to the hemisphere configuration
    viewerDirection = normalize(vec3(alpha * viewerDirection.xy, viewerDirection.z));

    // Sample a reflection direction off the hemisphere
    const float tau = 6.2831853; // 2 * pi
    float phi = tau * xy;

    float cosTheta = fma(1.0 - xy, 1.0 + viewerDirection.z, -viewerDirection.z) ;
    float sinTheta = sqrt(clamp(1.0 - cosTheta * cosTheta, 0.0, 1.0));

	// xonk note, i dont know what im doing but this kinda does what i want so whatever
	float attemptTailClamp  = clamp(sinTheta,max(cosTheta-0.25,0), cosTheta);
	float attemptTailClamp2 = clamp(cosTheta,max(sinTheta-0.25,0), sinTheta);

    vec3 reflected = vec3(vec2(cos(phi), sin(phi)) * attemptTailClamp2, attemptTailClamp);
    // vec3 reflected = vec3(vec2(cos(phi), sin(phi)) * sinTheta, cosTheta);

    // Evaluate halfway direction
    // This gives the normal on the hemisphere
    vec3 halfway = reflected + viewerDirection;

    // Transform the halfway direction back to hemiellispoid configuation
    // This gives the final sampled normal
    return normalize(vec3(alpha * halfway.xy, halfway.z));
}

float GGX(vec3 n, vec3 v, vec3 l, float r, float f0) {
  r = max(pow(r,2.5), 0.0001);

  vec3 h = l + v;
  float hn = inversesqrt(dot(h, h));

  float dotLH = clamp(dot(h,l)*hn,0.,1.);
  float dotNH = clamp(dot(h,n)*hn,0.,1.) ;
  float dotNL = clamp(dot(n,l),0.,1.);
  float dotNHsq = dotNH*dotNH;

  float denom = dotNHsq * r - dotNHsq + 1.;
  float D = r / (3.141592653589793 * denom * denom);

  float F = f0 + (1. - f0) * exp2((-5.55473*dotLH-6.98316)*dotLH);
  float k2 = .25 * r;

  return dotNL * D * F / (dotLH*dotLH*(1.0-k2)+k2);
}

// Puddle highlights use perceptual roughness, as in iterationT's deferred
// lighting: alpha = roughness^2 and the GGX distribution uses alpha^2.
// Keep this separate from Bliss' material and water highlight conventions.
float BlissPuddleHighlight(vec3 N, vec3 V, vec3 L, float roughness, float f0) {
    float NoL = clamp(dot(N, L), 0.0, 1.0);
    float NoV = clamp(dot(N, V), 0.0, 1.0);
    vec3 halfway = V + L;
    if (NoL <= 0.0 || NoV <= 0.0 || dot(halfway, halfway) < 1e-8) return 0.0;
    halfway = normalize(halfway);
    float NoH = clamp(dot(N, halfway), 0.0, 1.0);
    float LoH = clamp(dot(L, halfway), 0.0, 1.0);
    float alpha = max(roughness * roughness, 0.0016);
    float alphaSquared = alpha * alpha;
    // Use sin^2 from the cross product to avoid cancellation near the peak.
    vec3 halfPerpendicular = cross(N, halfway);
    float denominator = dot(halfPerpendicular, halfPerpendicular) + NoH * NoH * alphaSquared;
    float distribution = alphaSquared / (3.141592653589793 * denominator * denominator);
    float k = alpha * 0.5;
    float visibility = (NoV / (NoV * (1.0 - k) + k))
                     * (NoL / (NoL * (1.0 - k) + k));
    float fresnel = f0 + (1.0 - f0) * pow(1.0 - LoH, 5.0);
    // Let the material's continuous wet smoothness shape the highlight.
    float smoothnessWeight = clamp(pow(max(1.0 - roughness, 0.0), 0.7) * 2.0, 0.0, 1.0);
    float highlight = NoL * distribution * fresnel * visibility * smoothnessWeight;
    // Preserve the existing brightness ceiling without a flat clipped top.
    return highlight / (1.0 + highlight / 1.25);
}

void DoPuddleSpecularReflections(
	inout vec3 Output,
	vec3 FragPos,
	vec3 WorldPos,
	vec2 Noise,
	vec3 Normal,
	vec3 LightPos,
	vec3 DirectLight,
	vec3 Albedo,
	float MaterialSmoothness,
	float MaterialF0,
	float Wetness
){
	vec3 N = normalize(Normal);
	float wetnessAmount = clamp(Wetness, 0.0, 1.0);
	if (wetnessAmount <= 0.0) return;
	float wetSmoothness = clamp(MaterialSmoothness, 0.0, 1.0);
	float roughness = max(1.0 - wetSmoothness, 0.0001);
	// The dedicated puddle highlight below handles perceptual roughness.
	float specularity = max(wetSmoothness * wetSmoothness * wetSmoothness * 1.15 - 0.15, 0.0);
	float materialF0 = clamp(MaterialF0, 0.0, 1.0);
	float metallic = materialF0 > 229.5 / 255.0 ? pow(materialF0, 2.2) : 0.0;
	float dielectricF0 = 0.008;
	vec3 viewRay = normalize(WorldPos);
	vec3 reflectionDirection = normalize(reflect(viewRay, N));
	float normalDotView = clamp(dot(-viewRay, N), 0.0, 1.0);
	float fresnel = mix(dielectricF0, 1.0, pow(1.0 - normalDotView, 5.0));
	float reflectionAmount = mix(fresnel * specularity, 1.0, metallic);
	vec3 metalTint = metallic > 0.0 ? normalize(Albedo + 1e-7) * (dot(Albedo, vec3(0.21, 0.72, 0.07)) * 0.7 + 0.3) : vec3(1.0);

	vec3 environment = skyCloudsFromTexLOD(reflectionDirection, colortex4, roughness * 9.0).rgb / 30.0 * metalTint;
	float reflectionLength = 0.0;
	vec3 rayPosition = rayTracePuddleSpeculars(mat3(gbufferModelView) * reflectionDirection, FragPos, Noise.y, reflectionLength);
	// An SSR miss is missing screen data, not evidence that the sky is occluded.
	vec3 reflectedScene = environment;
	if (rayPosition.z < 1.0) {
		vec3 previousPosition = mat3(gbufferModelViewInverse) * toScreenSpace(rayPosition) + gbufferModelViewInverse[3].xyz + cameraPosition - previousCameraPosition;
		previousPosition = mat3(gbufferPreviousModelView) * previousPosition + gbufferPreviousModelView[3].xyz;
		// iterationT samples detailed scene reflections. A small footprint keeps
		// nearby bright sky from washing across the puddle's reflected detail.
		float reflectionLod = roughness * roughness * 4.0;
		vec4 history = BlissReflectionHistory(previousPosition, reflectionLod);
		reflectedScene = mix(environment, history.rgb * metalTint, history.a);
	}

	vec3 finalReflection = mix(Output, reflectedScene, reflectionAmount);
	float sunReflection = BlissPuddleHighlight(N, -viewRay, LightPos, roughness, mix(dielectricF0, materialF0, metallic));
	finalReflection += DirectLight * sunReflection * Sun_specular_Strength * metalTint;
	Output = finalReflection;
}

void DoSpecularReflections(
	inout vec3 Output,

	vec3 FragPos, // toScreenspace(vec3(screenUV, depth)
	vec3 WorldPos,
    vec3 LightPos, // should be in world space
    vec2 Noise, // x = bluenoise z = interleaved gradient noise

	vec3 Normal, // normals in world space
	float Roughness, // red channel of specular texture _S
	float F0, // green channel of specular texture _S

	vec3 Albedo, 
	vec3 Diffuse, // should contain the light color and NdotL. and maybe shadows.

    float Lightmap, // in anything other than world0, this should be 1.0;
    bool Hand // mask for the hand
){
	vec3 Final_Reflection = Output;
	vec3 Background_Reflection = Output;
	vec3 Lightsource_Reflection = vec3(0.0);
	vec4 SS_Reflections = vec4(0.0);

	Lightmap = clamp((Lightmap-0.8)*7.0, 0.0,1.0);
	
	Roughness = 1.0 - Roughness; Roughness *= Roughness;
	F0 = F0 == 0.0 ? 0.02 : F0;

	// Roughness = 0.1;
	// F0 = 0.9;

	mat3 Basis = CoordBase(Normal);
	vec3 ViewDir = -WorldPos*Basis;

	#ifdef Rough_reflections
		vec3 SamplePoints = SampleVNDFGGX(ViewDir, vec2(Roughness), Noise.x);
		if(Hand) SamplePoints = normalize(vec3(0.0,0.0,1.0));
	#else
		vec3 SamplePoints = vec3(0.0,0.0,1.0);
	#endif

	vec3 Ln = reflect(-ViewDir, SamplePoints);
	vec3 L = Basis * Ln;

	float Fresnel = pow(clamp(1.0 + dot(-Ln, SamplePoints),0.0,1.0), 5.0); // Schlick's approximation

	float RayContribution = lerp(F0, 1.0, Fresnel); // ensure that when the angle is 0 that the correct F0 is used.
	
	#ifdef Rough_reflections
		if(Hand) RayContribution = RayContribution * pow(1.0-Roughness,3.0);
	#else
		RayContribution = RayContribution * pow(1.0-Roughness,3.0);
	#endif

    bool hasReflections = Roughness_Threshold == 1.0 ? true : F0 * (1.0 - Roughness * Roughness_Threshold) > 0.01;

	// mulitply all reflections by the albedo if it is a metal.
	vec3 Metals = F0 > 229.5/255.0 ? lerp(normalize(Albedo+1e-7) * (dot(Albedo,vec3(0.21, 0.72, 0.07)) * 0.7 + 0.3), vec3(1.0), Fresnel * pow(1.0-Roughness,25.0)) : vec3(1.0);
	// vec3 Metals = F0 > 229.5/255.0 ? max(Albedo, Fresnel) : vec3(1.0);

	// --------------- BACKGROUND REFLECTIONS
	// apply background reflections to the final color. make sure it does not exist based on the lightmap
	#ifdef Sky_reflection

		#ifdef OVERWORLD_SHADER
			if(hasReflections) Background_Reflection = (skyCloudsFromTexLOD(L, colortex4, sqrt(Roughness) * 9.0).rgb / 30.0) * Metals;
		#else
			if(hasReflections) Background_Reflection = (skyCloudsFromTexLOD2(L, colortex4, sqrt(Roughness) * 6.0).rgb / 30.0) * Metals;
		#endif

		// take fresnel and lightmap levels into account and write to the final color
		Final_Reflection = lerp(Output, Background_Reflection, Lightmap * RayContribution);
	#endif

	// --------------- SCREENSPACE REFLECTIONS
	// apply screenspace reflections to the final color and mask out background reflections.
	#ifdef Screen_Space_Reflections
		if(hasReflections){
			#ifdef Dynamic_SSR_quality
				float SSR_Quality = lerp(reflection_quality, 6.0, RayContribution); // Scale quality with ray contribution
			#else
				float SSR_Quality = reflection_quality;
			#endif

			float reflectLength = 0.0;
			vec3 RaytracePos = rayTraceSpeculars(mat3(gbufferModelView) * L, FragPos,  Noise.y, float(SSR_Quality), Hand, reflectLength);
			float LOD = clamp(pow(reflectLength, pow(1.0-sqrt(Roughness),5.0) * 3.0) * 6.0, 0.0, 6.0); // use higher LOD as the reflection goes on, to blur it. this helps denoise a little.
			
			if(Roughness <= 0.0) LOD = 0.0;

			if (RaytracePos.z < 1.0){
				vec3 previousPosition = mat3(gbufferModelViewInverse) * toScreenSpace(RaytracePos) + gbufferModelViewInverse[3].xyz + cameraPosition-previousCameraPosition;
				previousPosition = mat3(gbufferPreviousModelView) * previousPosition + gbufferPreviousModelView[3].xyz;
				vec4 history = BlissReflectionHistory(previousPosition, LOD);
				SS_Reflections.a = history.a;
				SS_Reflections.rgb = history.rgb * Metals;
			}
			// make sure it takes the fresnel into account for SSR.
			SS_Reflections.rgb = lerp(Output, SS_Reflections.rgb, RayContribution);
		
			// occlude the background with the SSR and write to the final color.
			Final_Reflection = lerp(Final_Reflection, SS_Reflections.rgb, SS_Reflections.a);
		}
	#endif

	// --------------- LIGHTSOURCE REFLECTIONS
	// slap the main lightsource reflections to the final color.
	#ifdef LIGHTSOURCE_REFLECTION
		Lightsource_Reflection = Diffuse * GGX(Normal, -WorldPos, LightPos, Roughness, F0) * Metals;
		Final_Reflection += Lightsource_Reflection * Sun_specular_Strength;
	#endif

	Output = Final_Reflection;
}
