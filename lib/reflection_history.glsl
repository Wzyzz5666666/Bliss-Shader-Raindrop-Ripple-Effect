#ifndef BLISS_REFLECTION_HISTORY_GLSL
#define BLISS_REFLECTION_HISTORY_GLSL

// Clip the projected segment without changing the ratio between XY and depth.
float BlissReflectionRayLimit(vec3 origin, vec3 direction) {
    float limit = 1.0;
    for (int axis = 0; axis < 3; ++axis) {
        if (abs(direction[axis]) > 1e-7) {
            float boundary = direction[axis] > 0.0 ? 1.0 : 0.0;
            limit = min(limit, (boundary - origin[axis]) / direction[axis]);
        }
    }
    return max(limit, 0.0);
}

// History is valid only inside the image. Do not extend the last row/column:
// dark silhouettes there become long stripes when the camera moves.
vec4 BlissReflectionHistory(vec3 previousViewPosition, float requestedLod) {
    vec4 previousClip = gbufferPreviousProjection * vec4(previousViewPosition, 1.0);
    if (previousClip.w <= 1e-5) return vec4(0.0);
    vec2 uv = previousClip.xy / previousClip.w * 0.5 + 0.5;
    vec2 edgePixels = min(uv, 1.0 - uv) / texelSize;
    float edgeDistance = min(edgePixels.x, edgePixels.y);
    float confidence = smoothstep(0.5, 2.5, edgeDistance);
    if (confidence <= 0.0) return vec4(0.0);

    // Trilinear filtering accesses ceil(lod), so fit that complete mip footprint.
    // Keep UV unchanged; clamping it would also stretch edge texels into stripes.
    float edgeLod = floor(log2(max(2.0 * edgeDistance, 1.0)));
    float lod = clamp(requestedLod, 0.0, edgeLod);
    return vec4(texture2DLod(colortex5, uv, lod).rgb, confidence);
}

#endif
