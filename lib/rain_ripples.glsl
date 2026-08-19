#ifndef BLISS_RAIN_RIPPLES_GLSL
#define BLISS_RAIN_RIPPLES_GLSL

uniform sampler2D rainNoiseTex;

vec3 BlissRippleHash(vec3 position) {
    position = fract(position * vec3(0.1031, 0.1030, 0.0973));
    position += dot(position, position.yxz + 19.19);
    return fract((position.xxy + position.yxx) * position.zyx);
}

float BlissRippleBias(float signal, float biasValue) {
    return signal / ((((1.0 / biasValue) - 2.0) * (1.0 - signal)) + 1.0);
}

float BlissSmootherstep(float edge0, float edge1, float value) {
    float normalizedValue = clamp((value - edge0) / max(edge1 - edge0, 0.0001), 0.0, 1.0);
    return normalizedValue * normalizedValue * normalizedValue * (normalizedValue * (normalizedValue * 6.0 - 15.0) + 10.0);
}

vec3 BlissPuddleNoise3D(vec3 position) {
    vec3 cellPosition = floor(position);
    vec3 localPosition = fract(position);
    localPosition = localPosition * localPosition * (3.0 - 2.0 * localPosition);

    vec2 lowerCell = cellPosition.xy + cellPosition.z * vec2(17.0, 37.0) + localPosition.xy;
    vec2 upperCell = cellPosition.xy + (cellPosition.z + 1.0) * vec2(17.0, 37.0) + localPosition.xy;
    vec3 lowerNoise = texture2D(rainNoiseTex, (lowerCell + 0.5) / 64.0).xyz;
    vec3 upperNoise = texture2D(rainNoiseTex, (upperCell + 0.5) / 64.0).xyz;
    return mix(lowerNoise, upperNoise, localPosition.z);
}

float BlissPuddleNoise(vec3 position) {
    position.xz /= max(Puddle_Size, 0.5);
    position.y *= 0.2 / max(Puddle_Size, 0.5);

    float puddleNoise = BlissPuddleNoise3D(position).y;
    puddleNoise += BlissPuddleNoise3D(position * 0.5).x * 2.0;
    puddleNoise += BlissPuddleNoise3D(position * 0.25).x * 4.0;
    puddleNoise = saturate(puddleNoise / 7.0 * 0.8 + 0.5) * 0.75;
    return saturate(puddleNoise + (PUDDLE_COVERAGE - 1.0) * 0.35);
}

float BlissRainSkyExposure(float skyLight) {
    return BlissSmootherstep(0.762, 0.952, skyLight);
}

float BlissPuddleMask(vec3 position, float skyExposure, float rainfall, float surfaceSlope) {
    float puddleField = BlissPuddleNoise(position);
    float groundSlope = saturate(surfaceSlope * 0.5 + 0.5);
    return puddleField * skyExposure * rainfall * groundSlope;
}

float BlissRippleVoronoi(vec3 position, float randomSeed) {
    float rippleField = 0.0;
    float rippleScale = 3.0 / max(PUDDLE_COVERAGE, 0.25);
    position = position.xzy * rippleScale;
    vec3 originalPosition = position;
    vec3 cellPosition = floor(position);
    float timer = frameTimeCounter * 2.625 * RIPPLE_SPEED;

    for (int cellX = -1; cellX <= 1; cellX++) {
        for (int cellY = -1; cellY <= 1; cellY++) {
            vec3 cellOffset = vec3(float(cellX), float(cellY), 0.0);
            vec3 randomValue = BlissRippleHash(cellPosition + cellOffset + 127.43 + randomSeed);
            float dropPhase = floor(randomValue.x + timer);
            vec3 dropIndex = vec3(dropPhase, 0.0, dropPhase);
            vec3 dropPosition = BlissRippleHash(cellPosition + cellOffset + dropIndex + randomSeed);
            vec3 phase = mod(randomValue + timer, 1.0);

            float opacity = BlissRippleBias(1.0 - phase.x, 0.21);
            float profile = BlissRippleBias(phase.x, 0.62);
            float radius = mix(4.0, 1.0, profile);
            float radiusOffset = mix(0.005, 2.0, profile);

            float ring = 1.0 - length((cellPosition.xy + dropPosition.xz) - (originalPosition.xy - cellOffset.xy)) * radius;
            ring *= radiusOffset;
            if (ring > 0.5) ring = mix(1.0, 0.0, ring);
            ring = mix(0.0, 2.0, ring);
            if (ring > 0.5) ring = mix(1.0, 0.0, ring);
            ring = smoothstep(0.0, 1.0, ring) * opacity;
            rippleField = 1.0 - (1.0 - rippleField) * (1.0 - ring);
        }
    }

    return rippleField * 0.1;
}

float BlissRippleHeight(vec3 position, float wet) {
    vec3 ripples = vec3(0.0);
    for (int layer = 0; layer < 3; layer++) {
        ripples += vec3(BlissRippleVoronoi(position, float(layer + 1)));
    }
    return (position.y + 1.0 - ripples.x * 0.25) * wet;
}

float BlissRippleDownfall(vec3 position) {
    vec2 rippleCoord = fract(position.xz * 0.0025 - vec2(frameTimeCounter * 0.003, 0.0));
    return saturate(texture2D(rainNoiseTex, rippleCoord).r * 1.5 - 0.25);
}

vec3 BlissRainRippleVoronoiNormal(vec3 position, float wet) {
    if (max(rainStrength, wetness) < 0.01 || wet < 0.001) {
        // Ripple normals are consumed as tangent-space (x, y, 1) data.
        return vec3(0.0, 0.0, 1.0);
    }

    float downfall = BlissRippleDownfall(position);
    wet = saturate(wet * (0.55 + downfall * 0.45));
    position -= vec3(0.005, 0.0, 0.005);

    float center = BlissRippleHeight(position, wet);
    float left = BlissRippleHeight(position + vec3(0.01, 0.0, 0.0), wet);
    float up = BlissRippleHeight(position + vec3(0.0, 0.0, 0.01), wet);

    vec3 rippleNormal = vec3(center - left, 0.0, center - up);
    rippleNormal.xz *= 20.0 * 0.875 * RIPPLE_INTENSITY;
    rippleNormal.y = 1.0;
    float rippleLod = dot(abs(fwidth(position.xz * (3.0 / max(PUDDLE_COVERAGE, 0.25)))), vec2(1.0));
    rippleNormal.xz *= 1.0 / (1.0 + rippleLod * 5.0);
    return normalize(rippleNormal);
}

vec3 BlissRainRippleAnimation(sampler2D rippleTexture, vec2 uv, float wet) {
    float frame = mod(floor(frameTimeCounter * RIPPLE_SPEED * 60.0), 60.0);
    vec2 animationCoord = vec2(uv.x, mod(uv.y / 60.0, 1.0) - frame / 60.0);
    vec3 rippleNormal = texture2D(rippleTexture, animationCoord).rgb * 2.0 - 1.0;
    rippleNormal.y *= -1.0;
    rippleNormal.xy = pow(abs(rippleNormal.xy), vec2(2.0 - wet * wet * wet * 1.2)) * sign(rippleNormal.xy);
    return rippleNormal;
}

vec3 BlissRainRippleBilateral(sampler2D rippleTexture, vec2 uv, float wet) {
    vec3 rippleNormal = BlissRainRippleAnimation(rippleTexture, uv, wet);

    #ifndef RIPPLE_SMOOTHING
        return rippleNormal;
    #else
    vec2 texel = vec2(1.0 / 128.0, 0.0);
    vec3 rippleNormalRight = BlissRainRippleAnimation(rippleTexture, uv + texel.xy, wet);
    vec3 rippleNormalUp = BlissRainRippleAnimation(rippleTexture, uv + texel.yx, wet);
    vec3 rippleNormalUpRight = BlissRainRippleAnimation(rippleTexture, uv + texel.xx, wet);
    vec2 interpolation = fract(uv * 128.0);
    vec3 lerpX = mix(rippleNormal, rippleNormalRight, interpolation.x);
    vec3 lerpX2 = mix(rippleNormalUp, rippleNormalUpRight, interpolation.x);
    return mix(lerpX, lerpX2, interpolation.y);
    #endif
}

vec3 BlissRainRippleNormal(
    vec3 position,
    inout float wet,
    sampler2D rippleTexture1,
    sampler2D rippleTexture2,
    sampler2D rippleTexture3,
    float waterScale
) {
    if (max(rainStrength, wetness) < 0.01 || wet < 0.001) {
        // Keep the same tangent-space convention as the animated ripple
        // textures.  Returning (0, 1, 0) would be interpreted as a full
        // sideways normal by BlissApplyRippleTangentNormal.
        return vec3(0.0, 0.0, 1.0);
    }

    vec3 ripplePosition = position * 0.5;
    vec3 rippleNormal1 = BlissRainRippleBilateral(rippleTexture1, ripplePosition.xz, wet);
    vec3 rippleNormal2 = BlissRainRippleBilateral(rippleTexture2, ripplePosition.xz, wet);
    vec3 rippleNormal3 = BlissRainRippleBilateral(rippleTexture3, ripplePosition.xz, wet);

    ripplePosition.x -= frameTimeCounter * RIPPLE_SPEED * 1.5;
    float downfall = saturate(texture2D(rainNoiseTex, ripplePosition.xz * 0.0025).x * 1.0 - 0.25);

    vec3 rippleNormal = rippleNormal1 * 2.0;
    rippleNormal += rippleNormal2 * saturate(downfall * 2.0) * 2.0;
    rippleNormal += rippleNormal3 * saturate(downfall * 2.0 - 1.0) * 2.0;
    rippleNormal *= 0.3;

    float rippleLod = dot(abs(fwidth(ripplePosition.xyz)), vec3(1.0));
    rippleNormal.xy *= 1.0 / (1.0 + rippleLod * 5.0);

    // Match interactionT: the animated normal is scaled by global weather,
    // while the local noise profile is returned to the caller as coverage.
    // The caller applies sky exposure/slope afterwards instead of feeding
    // that already-masked value back into the profile.
    wet = saturate(downfall * ((1.0 - wet) * 0.95) + wet);
    rippleNormal.xy *= max(rainStrength, wetness) * RIPPLE_INTENSITY * 7.0 * waterScale;
    return vec3(rippleNormal.x, rippleNormal.y, 1.0);
}

vec3 BlissApplyRippleNormal(vec3 baseNormal, vec3 rippleNormal, float influence) {
    vec3 rippleOffset = rippleNormal - vec3(0.0, 1.0, 0.0);
    return normalize(baseNormal + rippleOffset * clamp(influence, 0.0, 1.0));
}

vec3 BlissApplyRippleTangentNormal(vec3 baseNormal, mat3 tangentBasis, vec3 rippleNormal, float influence) {
    vec3 rippleOffset = vec3(rippleNormal.xy, 0.0) * tangentBasis;
    return normalize(baseNormal + rippleOffset * clamp(influence, 0.0, 1.0));
}

#endif
