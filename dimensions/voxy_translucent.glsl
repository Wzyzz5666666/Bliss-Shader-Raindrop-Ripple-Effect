#define VOXY_PROGRAM

#include "/lib/settings.glsl"
#include "/lib/res_params.glsl"
#include "/lib/waterBump.glsl"

layout(location = 0) out vec4 gbuffer_data_0;
layout(location = 1) out vec4 gbuffer_data_1;
layout(location = 2) out vec4 gbuffer_data_2;
layout(location = 3) out vec4 gbuffer_data_3;

#define diagonal3(m) vec3((m)[0].x, (m)[1].y, (m)[2].z)
#define projMAD(m, v) (diagonal3(m) * (v) + (m)[3].xyz)

float VoxyEncodeVec2(vec2 value) {
    const vec2 weights = vec2(1.0, 256.0) / 65535.0;
    return dot(floor(clamp(value, 0.0, 1.0) * 255.0), weights);
}

vec3 VoxyToLinear(vec3 srgb) {
    return srgb * (srgb * (srgb * 0.305306011 + 0.682171111) + 0.012522878);
}

vec3 VoxyFaceNormal(uint face) {
    vec3 axis = vec3(
        uint((face >> 1) == 2),
        uint((face >> 1) == 0),
        uint((face >> 1) == 1)
    );
    return axis * (float(int(face) & 1) * 2.0 - 1.0);
}

vec3 VoxyToViewSpace(vec3 screenPosition) {
    vec4 inverseProjection = vec4(vxProjInv[0].x, vxProjInv[1].y, vxProjInv[2].zw);
    vec3 ndc = screenPosition * 2.0 - 1.0;
    vec4 viewPosition = inverseProjection * ndc.xyzz + vxProjInv[3];
    return viewPosition.xyz / viewPosition.w;
}

vec3 VoxyToClipSpace(vec3 viewPosition) {
    return projMAD(vxProj, viewPosition) / -viewPosition.z * 0.5 + 0.5;
}

vec2 VoxySkyCoord(vec3 direction) {
    const float inverseTwoPi = 0.15915494309189535;
    float longitude = clamp(atan(-direction.x, -direction.z), -3.14159265359, 3.14159265359);
    return vec2(longitude * inverseTwoPi + 0.5, direction.y * 0.5 + 0.5);
}

vec3 VoxySkyReflection(vec3 direction) {
    vec2 atlasCoord = VoxySkyCoord(direction) * texelSize * 256.0;
    atlasCoord += vec2(275.5, 1.5) * texelSize;
    return texture2D(colortex4, atlasCoord).rgb / 30.0;
}

float VoxyGGX(vec3 normal, vec3 viewDirection, vec3 lightDirection, float roughness, float f0) {
    roughness = max(pow(roughness, 2.5), 0.0001);
    vec3 halfVector = lightDirection + viewDirection;
    float inverseHalfLength = inversesqrt(max(dot(halfVector, halfVector), 1e-6));
    float lightHalf = clamp(dot(halfVector, lightDirection) * inverseHalfLength, 0.0, 1.0);
    float normalHalf = clamp(dot(halfVector, normal) * inverseHalfLength, 0.0, 1.0);
    float normalLight = clamp(dot(normal, lightDirection), 0.0, 1.0);
    float denominator = normalHalf * normalHalf * roughness - normalHalf * normalHalf + 1.0;
    float distribution = roughness / (3.14159265359 * denominator * denominator);
    float fresnel = f0 + (1.0 - f0) * exp2((-5.55473 * lightHalf - 6.98316) * lightHalf);
    float geometry = 0.25 * roughness;
    return normalLight * distribution * fresnel / max(lightHalf * lightHalf * (1.0 - geometry) + geometry, 1e-5);
}

vec3 VoxyRippleAnimation(sampler2D rippleTexture, vec2 uv, float wetAmount) {
    float frame = mod(floor(frameTimeCounter * RIPPLE_SPEED * 60.0), 60.0);
    vec2 animationCoord = vec2(uv.x, mod(uv.y / 60.0, 1.0) - frame / 60.0);
    vec3 ripple = texture2D(rippleTexture, animationCoord).rgb * 2.0 - 1.0;
    ripple.y *= -1.0;
    ripple.xy = pow(abs(ripple.xy), vec2(2.0 - wetAmount * wetAmount * wetAmount * 1.2)) * sign(ripple.xy);
    return ripple;
}

vec3 VoxyRainRipple(vec3 worldPosition, float wetAmount, float distanceToCamera) {
    vec3 ripplePosition = worldPosition * 0.5;
    vec3 ripple = VoxyRippleAnimation(blissRainRippleTex1, ripplePosition.xz, wetAmount) * 2.0;
    float downfall = saturate(texture2D(rainNoiseTex, (ripplePosition.xz - vec2(frameTimeCounter * RIPPLE_SPEED * 1.5, 0.0)) * 0.0025).r - 0.25);
    ripple += VoxyRippleAnimation(blissRainRippleTex2, ripplePosition.xz, wetAmount) * saturate(downfall * 2.0) * 2.0;
    ripple += VoxyRippleAnimation(blissRainRippleTex3, ripplePosition.xz, wetAmount) * saturate(downfall * 2.0 - 1.0) * 2.0;
    float distanceFade = saturate(1.0 - distanceToCamera / 1024.0);
    ripple.xy *= 2.1 * max(rainStrength, wetness) * RIPPLE_INTENSITY * distanceFade;
    return vec3(ripple.xy, 1.0);
}

vec3 VoxyRayTrace(vec3 direction, vec3 viewPosition, float dither) {
    #if VOXY_REFLECTION_STEPS <= 0
        return vec3(1.1);
    #else
        vec3 clipPosition = VoxyToClipSpace(viewPosition);
        float rayLength = ((viewPosition.z + direction.z * dhVoxyFarPlane * 1.7320508) > -dhVoxyNearPlane)
            ? (-dhVoxyNearPlane - viewPosition.z) / direction.z
            : dhVoxyFarPlane * 1.7320508;
        vec3 clipDirection = VoxyToClipSpace(viewPosition + direction * rayLength) - clipPosition;
        vec3 edgeLength = (step(0.0, clipDirection) - clipPosition) / clipDirection;
        vec3 stepVector = clipDirection * min(min(edgeLength.x, edgeLength.y), edgeLength.z) / float(VOXY_REFLECTION_STEPS);
        clipPosition.xy *= RENDER_SCALE;
        stepVector.xy *= RENDER_SCALE;
        vec3 samplePosition = clipPosition + stepVector * dither;
        float minimumDepth = samplePosition.z - 0.0002;
        float maximumDepth = samplePosition.z;

        for (int stepIndex = 0; stepIndex <= VOXY_REFLECTION_STEPS; ++stepIndex) {
            if (any(lessThan(samplePosition.xy, vec2(0.0))) || any(greaterThan(samplePosition.xy, RENDER_SCALE))) break;
            ivec2 samplePixel = ivec2(samplePosition.xy / texelSize);
            if (texelFetch(depthtex0, samplePixel, 0).x >= 1.0) {
                float sceneDepth = texelFetch(vxDepthTexOpaque, samplePixel, 0).x;
                if (sceneDepth < max(minimumDepth, maximumDepth) && sceneDepth > min(minimumDepth, maximumDepth)) {
                    return vec3(samplePosition.xy / RENDER_SCALE, sceneDepth);
                }
            }
            minimumDepth = maximumDepth - 0.0002;
            maximumDepth += stepVector.z;
            samplePosition += stepVector;
        }
        return vec3(1.1);
    #endif
}

void voxy_emitFragment(VoxyFragmentParameters parameters) {
    if (gl_FragCoord.x * texelSize.x >= 1.0 || gl_FragCoord.y * texelSize.y >= 1.0) return;

    vec3 screenPosition = gl_FragCoord.xyz * vec3(texelSize / RENDER_SCALE, 1.0);
    vec3 viewPosition = VoxyToViewSpace(screenPosition);
    vec3 feetPlayerPosition = mat3(vxModelViewInv) * viewPosition + vxModelViewInv[3].xyz;
    vec3 worldPosition = feetPlayerPosition + cameraPosition;

    vec4 sourceColor = clamp(parameters.sampledColour * parameters.tinting, 0.0, 1.0);
    vec3 albedo = VoxyToLinear(sourceColor.rgb);
    float unchangedAlpha = sourceColor.a;
    int blockID = int(parameters.customId);
    bool isWater = blockID == 8;
    bool isReflectiveGlass = blockID == 10002;

    #ifdef AEROCHROME_MODE
        if (isWater || isReflectiveGlass) albedo = mix(albedo, vec3(0.01, 0.08, 0.15), 0.5);
    #endif

    vec3 worldNormal = VoxyFaceNormal(parameters.face);
    if (worldNormal.z < -0.9) worldNormal.xy = vec2(-1e-13);
    vec2 tangentNormal = vec2(0.5);

    vec2 lightmap = parameters.lightMap / (30.0 / 32.0) - (1.0 / 32.0);
    lightmap = clamp(lightmap, 0.0, 1.0);

    #ifndef Vanilla_like_water
        if (isWater) {
            albedo = vec3(0.0);
            sourceColor.a = 1.0 / 255.0;
        }
    #endif

    if (isWater && worldNormal.y > 0.1) {
        vec3 waveNormal = normalize(getWaveNormal(worldPosition, true));
        waveNormal = normalize(waveNormal * vec3(WATER_WAVE_STRENGTH) + vec3(0.0, 0.0, 1.0 - WATER_WAVE_STRENGTH));
        worldNormal.xz = waveNormal.xy;
        tangentNormal = (waveNormal.xy / 3.0) * 0.5 + 0.5;

        #if defined OVERWORLD_SHADER && defined RAIN_SPLASH_EFFECT
            float rainExposure = smoothstep(0.762, 0.952, lightmap.y) * max(rainStrength, wetness);
            if (rainExposure > 0.001) {
                vec3 rainRipple = VoxyRainRipple(worldPosition, rainExposure, length(feetPlayerPosition));
                worldNormal.xz += rainRipple.xy * rainExposure * 0.5;
                tangentNormal += rainRipple.xy * rainExposure / 6.0;
            }
        #endif
    }

    worldNormal = normalize(worldNormal);
    vec3 viewNormal = normalize(mat3(vxModelView) * worldNormal);
    float lightSourceSign = float(sunElevation > 1e-5) * 2.0 - 1.0;
    vec3 worldLightDirection = lightSourceSign * normalize(mat3(vxModelViewInv) * sunPosition);
    vec3 viewLightDirection = lightSourceSign * normalize(sunPosition);

    vec3 ambientColor = texelFetch(colortex4, ivec2(0, 37), 0).rgb / 30.0;
    vec3 directColor = texelFetch(colortex4, ivec2(6, 37), 0).rgb / 80.0;

    #ifdef NETHER_SHADER
        ambientColor = max(ambientColor, vec3(0.10, 0.075, 0.055));
        directColor = vec3(0.0);
        lightmap.y = 1.0;
    #endif
    #ifdef END_SHADER
        ambientColor = max(ambientColor, vec3(0.08, 0.11, 0.18));
    #endif

    float skyLight = (pow(lightmap.y, 15.0) * 2.0 + pow(lightmap.y, 2.5)) * 0.5;
    float torchLight = pow(lightmap.x, 10.0) * 5.0 + pow(lightmap.x, 1.5);
    vec3 minimumLight = vec3(MIN_LIGHT_AMOUNT * 0.01 + nightVision);
    vec3 indirectLighting = max(ambientColor * ambient_brightness * skyLight, minimumLight);
    indirectLighting += vec3(TORCH_R, TORCH_G, TORCH_B) * TORCH_AMOUNT * torchLight;

    float normalLight = clamp((-15.0 + dot(worldNormal, worldLightDirection) * 255.0) / 240.0, 0.0, 1.0);
    float outdoors = smoothstep(0.55, 0.95, lightmap.y);
    vec3 directLighting = directColor * normalLight * outdoors;
    vec3 finalColor = (indirectLighting + directLighting) * albedo;

    float material = isWater ? 1.0 : (isReflectiveGlass ? 0.2 : 0.0);

    #if defined WATER_REFLECTIONS && defined VOXY_REFLECTIONS
        if ((isWater || isReflectiveGlass) && sourceColor.a < 0.999999) {
            vec3 reflectedDirection = reflect(normalize(viewPosition), viewNormal);
            float f0 = 0.02;
            float fresnel = mix(f0, 1.0, pow(clamp(1.0 + dot(viewNormal, normalize(viewPosition)), 0.0, 1.0), 5.0));
            #ifdef SNELLS_WINDOW
                if (isEyeInWater == 1) fresnel = pow(clamp(1.5 + dot(viewNormal, normalize(viewPosition)), 0.0, 1.0), 25.0);
            #endif

            vec3 skyReflection = VoxySkyReflection(mat3(vxModelViewInv) * reflectedDirection);
            vec4 screenReflection = vec4(0.0);
            #ifdef SCREENSPACE_REFLECTIONS
                float dither = fract(52.9829189 * fract(0.06711056 * gl_FragCoord.x + 0.00583715 * gl_FragCoord.y) + float(frameCounter) * 0.61803398875);
                vec3 hitPosition = VoxyRayTrace(reflectedDirection, viewPosition, dither);
                if (hitPosition.z < 1.0) {
                    vec3 hitViewPosition = VoxyToViewSpace(hitPosition);
                    vec3 previousFeetPosition = mat3(vxModelViewInv) * hitViewPosition + vxModelViewInv[3].xyz + cameraPosition - previousCameraPosition;
                    vec3 previousViewPosition = mat3(vxModelViewPrev) * previousFeetPosition + vxModelViewPrev[3].xyz;
                    vec2 previousCoord = projMAD(vxProjPrev, previousViewPosition).xy / -previousViewPosition.z * 0.5 + 0.5;
                    if (all(greaterThan(previousCoord, vec2(0.0))) && all(lessThan(previousCoord, vec2(1.0)))) {
                        screenReflection = vec4(texture2D(colortex5, previousCoord).rgb, 1.0);
                    }
                }
            #endif

            float roughness = 0.05;
            #if defined OVERWORLD_SHADER && defined RAIN_SPLASH_EFFECT
                roughness = mix(roughness, 0.12, max(rainStrength, wetness) * smoothstep(0.762, 0.952, lightmap.y));
            #endif
            vec3 reflection = mix(skyReflection, screenReflection.rgb, screenReflection.a);
            vec3 sunReflection = directColor * VoxyGGX(viewNormal, -normalize(viewPosition), viewLightDirection, roughness, f0) * (1.0 - screenReflection.a);
            finalColor = mix(finalColor, reflection, fresnel) + sunReflection;
            sourceColor.a = mix(sourceColor.a, 1.0, fresnel);
        }
    #endif

    gbuffer_data_0 = vec4(finalColor, sourceColor.a);
    gbuffer_data_1 = vec4(albedo, material);
    gbuffer_data_2 = vec4(
        VoxyEncodeVec2(clamp(tangentNormal, 0.0, 1.0)),
        VoxyEncodeVec2(vec2(albedo.r, albedo.g)),
        VoxyEncodeVec2(vec2(albedo.b, unchangedAlpha)),
        unchangedAlpha
    );
    gbuffer_data_3 = vec4(0.0, 0.0, 0.0, lightmap.y);
}
