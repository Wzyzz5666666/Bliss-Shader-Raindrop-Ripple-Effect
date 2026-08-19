#define VOXY_PROGRAM

#include "/lib/settings.glsl"

layout(location = 0) out vec4 gbuffer_data_0;
layout(location = 1) out vec4 gbuffer_data_1;

vec2 VoxyEncodeNormal(vec3 normal) {
    normal.xy /= dot(abs(normal), vec3(1.0));
    normal.xy = normal.z <= 0.0 ? (1.0 - abs(normal.yx)) * sign(normal.xy) : normal.xy;
    return clamp(normal.xy * 0.5 + 0.5, 0.0, 1.0);
}

float VoxyEncodeVec2(vec2 value) {
    const vec2 weights = vec2(1.0, 256.0) / 65535.0;
    return dot(floor(clamp(value, 0.0, 1.0) * 255.0), weights);
}

vec3 VoxyFaceNormal(uint face) {
    vec3 axis = vec3(
        uint((face >> 1) == 2),
        uint((face >> 1) == 0),
        uint((face >> 1) == 1)
    );
    return axis * (float(int(face) & 1) * 2.0 - 1.0);
}

void voxy_emitFragment(VoxyFragmentParameters parameters) {
    int blockID = int(parameters.customId);
    vec4 albedo = clamp(parameters.sampledColour * parameters.tinting, 0.0, 1.0);

    #ifdef WhiteWorld
        albedo.rgb = vec3(0.5);
    #endif

    #ifdef AEROCHROME_MODE
        float gray = dot(albedo.rgb, vec3(0.2, 1.0, 0.07));
        if (blockID == 10001 || blockID == 10003 || blockID == 10004 || blockID == 10006 || blockID == 10009) {
            albedo.rgb = mix(vec3(gray), aerochrome_color, 0.7);
        } else if (blockID == 10008) {
            albedo.rgb = mix(albedo.rgb, aerochrome_color, 1.0 - parameters.tinting.b);
        }
        #ifdef AEROCHROME_WOOL_ENABLED
            else if (blockID == 200) albedo.rgb = mix(albedo.rgb, aerochrome_color, 0.3);
        #endif
    #endif

    vec3 normal = VoxyFaceNormal(parameters.face);
    if (normal.z < -0.9) normal.xy = vec2(-1e-13);

    vec2 lightmap = parameters.lightMap / (30.0 / 32.0) - (1.0 / 32.0);
    lightmap = clamp(lightmap, 0.0, 1.0);

    float material = 1.0;
    if (blockID == 10003) material = 0.55;
    else if (blockID == 10009) material = 0.60;

    float sss = 0.0;
    #if SSS_TYPE > 0 && defined VOXY_SSS
        if (blockID == 10001 || blockID == 10003 || blockID == 10004 || blockID == 10009) sss = 1.0;
        else if (blockID == 10006 || blockID == 200) sss = 0.75;
        else if (blockID == 10010) sss = 0.4;
        #ifdef MISC_BLOCK_SSS
            else if (blockID == 10007 || blockID == 10008) sss = 0.5;
        #endif
    #endif

    float emissive = 0.0;
    #if EMISSIVE_TYPE > 0
        if (blockID == 10005) emissive = 0.5;
    #endif

    vec4 packedSurface = vec4(VoxyEncodeNormal(normal), lightmap);
    gbuffer_data_0 = vec4(
        VoxyEncodeVec2(vec2(albedo.r, packedSurface.r)),
        VoxyEncodeVec2(vec2(albedo.g, packedSurface.g)),
        VoxyEncodeVec2(vec2(albedo.b, packedSurface.b)),
        VoxyEncodeVec2(vec2(packedSurface.a, material))
    );
    gbuffer_data_1 = vec4(0.0, 0.0, clamp(sss, 0.0, 0.99), clamp(emissive, 0.0, 0.99));
}
