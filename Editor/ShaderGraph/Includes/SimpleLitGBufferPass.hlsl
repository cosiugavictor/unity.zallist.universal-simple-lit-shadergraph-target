#ifndef SIMPLE_LIT_GBUFFER_PASS_INCLUDED
#define SIMPLE_LIT_GBUFFER_PASS_INCLUDED

#include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/GBufferOutput.hlsl"  // Unity 6: Defines FragmentOutput

// Conditional include for deprecated SurfaceDataToGbuffer (for compatibility)
#if !defined(SurfaceDataToGbuffer)
#include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/UnityGBuffer.hlsl"  // Deprecated, but provides SurfaceDataToGbuffer
#endif

// Fallback for Unity 6 if SurfaceDataToGbuffer is unavailable (implements GBuffer layout from source)
#ifndef SurfaceDataToGbuffer
#define kLightingSimpleLit 1  // Material flag for SimpleLit

struct FragmentOutput
{
    half4 GBUFFER0 : SV_Target0;  // Albedo (RGB), Occlusion (A)
    half4 GBUFFER1 : SV_Target1;  // Specular (RGB), Smoothness (A)
    half4 GBUFFER2 : SV_Target2;  // Packed Normal (RGB), Smoothness (A)
    half4 GBUFFER3 : SV_Target3;  // Emission + GI (RGB), Rendering Layers (A)
#if _RENDER_PASS_ENABLED
    float GBUFFER4 : SV_Target4;  // Depth (Z)
#endif
#if OUTPUT_SHADOWMASK
    half4 GBUFFER_SHADOWMASK : SV_Target5;  // ShadowMask
#endif
};

FragmentOutput SurfaceDataToGbuffer(SurfaceData surfaceData, InputData inputData, half3 globalIllumination, uint materialFlags)
{
    FragmentOutput output;

    half3 packedNormalWS = PackNormal(inputData.normalWS);  // Pack world-space normal for GBUFFER2

    output.GBUFFER0 = half4(surfaceData.albedo, surfaceData.occlusion);  // Albedo + Occlusion
    output.GBUFFER1 = half4(surfaceData.specular, surfaceData.smoothness);  // Specular + Smoothness
    output.GBUFFER2 = half4(packedNormalWS, surfaceData.smoothness);  // Packed Normal + Smoothness
    output.GBUFFER3 = half4(globalIllumination + surfaceData.emission, 0.0);  // GI + Emission

#if _RENDER_PASS_ENABLED
    output.GBUFFER4 = inputData.positionCS.z;  // Depth
#endif

#if OUTPUT_SHADOWMASK
    output.GBUFFER_SHADOWMASK = half4(inputData.shadowMask, 1.0);  // ShadowMask
#endif

// Set material flags (e.g., for SimpleLit)
    output.GBUFFER0.a = saturate(output.GBUFFER0.a) * (1.0 / 64.0);  // Encode material flags in occlusion if needed
    output.GBUFFER0.a += (half)(materialFlags & kMaterialFlagReceiveShadowsOff ? 1.0 : 0.0) / 256.0;

    return output;
}
#endif

void InitializeInputData(Varyings input, SurfaceDescription surfaceDescription, out InputData inputData)
{
    inputData = (InputData)0;

    inputData.positionWS = input.positionWS;
    inputData.positionCS = input.positionCS;

#ifdef _NORMALMAP
    // IMPORTANT! If we ever support Flip on double sided materials ensure bitangent and tangent are NOT flipped.
    float crossSign = (input.tangentWS.w > 0.0 ? 1.0 : -1.0) * GetOddNegativeScale();
    float3 bitangent = crossSign * cross(input.normalWS.xyz, input.tangentWS.xyz);

    inputData.tangentToWorld = half3x3(input.tangentWS.xyz, bitangent.xyz, input.normalWS.xyz);
#if _NORMAL_DROPOFF_TS
    inputData.normalWS = TransformTangentToWorld(surfaceDescription.NormalTS, inputData.tangentToWorld);
#elif _NORMAL_DROPOFF_OS
    inputData.normalWS = TransformObjectToWorldNormal(surfaceDescription.NormalOS);
#elif _NORMAL_DROPOFF_WS
    inputData.normalWS = surfaceDescription.NormalWS;
#endif
#else
    inputData.normalWS = input.normalWS;
#endif
    inputData.normalWS = NormalizeNormalPerPixel(inputData.normalWS);
#if UNITY_VERSION >= 202220
    inputData.viewDirectionWS = GetWorldSpaceNormalizeViewDir(input.positionWS);
#else
    inputData.viewDirectionWS = SafeNormalize(GetWorldSpaceViewDir(input.positionWS));
#endif

#if defined(MAIN_LIGHT_CALCULATE_SHADOWS)
    inputData.shadowCoord = TransformWorldToShadowCoord(inputData.positionWS);
#else
    inputData.shadowCoord = float4(0, 0, 0, 0);
#endif

    inputData.fogCoord = InitializeInputDataFog(float4(input.positionWS, 1.0), input.fogFactorAndVertexLight.x);
    inputData.vertexLighting = input.fogFactorAndVertexLight.yzw;
#if defined(DYNAMICLIGHTMAP_ON)
    inputData.bakedGI = SAMPLE_GI(input.staticLightmapUV, input.dynamicLightmapUV.xy, input.sh, inputData.normalWS);
#else
    inputData.bakedGI = SAMPLE_GI(input.staticLightmapUV, input.sh, inputData.normalWS);
#endif
    inputData.normalizedScreenSpaceUV = GetNormalizedScreenSpaceUV(input.positionCS);
    inputData.shadowMask = SAMPLE_SHADOWMASK(input.staticLightmapUV);

#if defined(DEBUG_DISPLAY)
#if defined(DYNAMICLIGHTMAP_ON)
    inputData.dynamicLightmapUV = input.dynamicLightmapUV.xy;
#endif
#if defined(LIGHTMAP_ON)
    inputData.staticLightmapUV = input.staticLightmapUV;
#else
    inputData.vertexSH = input.sh;
#endif
#endif
}

PackedVaryings vert(Attributes input)
{
    Varyings output = (Varyings)0;
    output = BuildVaryings(input);
    PackedVaryings packedOutput = (PackedVaryings)0;
    packedOutput = PackVaryings(output);
    return packedOutput;
}

FragmentOutput frag(PackedVaryings packedInput)
{
    Varyings unpacked = UnpackVaryings(packedInput);
    UNITY_SETUP_INSTANCE_ID(unpacked);
    UNITY_SETUP_STEREO_EYE_INDEX_POST_VERTEX(unpacked);
    SurfaceDescription surfaceDescription = BuildSurfaceDescription(unpacked);

#if _ALPHATEST_ON
    half alpha = surfaceDescription.Alpha;
    clip(alpha - surfaceDescription.AlphaClipThreshold);
#elif _SURFACE_TYPE_TRANSPARENT
    half alpha = surfaceDescription.Alpha;
#else
    half alpha = 1;
#endif

#if UNITY_VERSION >= 202220
#if defined(LOD_FADE_CROSSFADE) && USE_UNITY_CROSSFADE
    LODFadeCrossFade(unpacked.positionCS);
#endif
#endif

    InputData inputData;
    InitializeInputData(unpacked, surfaceDescription, inputData);

#ifdef _SPECULAR_COLOR
    float3 specular = surfaceDescription.Specular;
#else
    float3 specular = 0;
#endif

    half3 normalTS = half3(0, 0, 0);
#if defined(_NORMALMAP) && defined(_NORMAL_DROPOFF_TS)
    normalTS = surfaceDescription.NormalTS;
#endif

#ifdef _DBUFFER
    float throwaway = 0.0;
    ApplyDecal(unpacked.positionCS,
        surfaceDescription.BaseColor,
        specular,
        inputData.normalWS,
        throwaway,
        throwaway,
        surfaceDescription.Smoothness);
#endif

    SurfaceData surface;
    surface.albedo = surfaceDescription.BaseColor;
    surface.metallic = 0.0;
    surface.specular = specular;
    surface.smoothness = saturate(surfaceDescription.Smoothness);
    surface.occlusion = 1.0;
    surface.emission = surfaceDescription.Emission;
    surface.alpha = saturate(alpha);
    surface.normalTS = normalTS;
    surface.clearCoatMask = 0;
    surface.clearCoatSmoothness = 1;

#if UNITY_VERSION >= 202210
    surface.albedo = AlphaModulate(surface.albedo, surface.alpha);
#endif

    Light mainLight = GetMainLight(inputData.shadowCoord, inputData.positionWS, inputData.shadowMask);
    MixRealtimeAndBakedGI(mainLight, inputData.normalWS, inputData.bakedGI, inputData.shadowMask);
    half3 gi = inputData.bakedGI;  // Use baked GI for deferred
    half4 color = half4(gi * surface.albedo + surface.emission, surface.alpha);

    uint materialFlags = kLightingSimpleLit;  // SimpleLit flag
    FragmentOutput output = SurfaceDataToGbuffer(surface, inputData, gi, materialFlags);

#ifdef _WRITE_RENDERING_LAYERS
    output.GBUFFER3.a = (float)GetMeshRenderingLayer();  // Store rendering layers in GBUFFER3.a
#endif

    return output;
}
#endif