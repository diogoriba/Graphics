#ifndef UNIVERSAL_LIGHTING_INCLUDED
#define UNIVERSAL_LIGHTING_INCLUDED

#include "Packages/com.unity.render-pipelines.core/ShaderLibrary/Common.hlsl"
#include "Packages/com.unity.render-pipelines.core/ShaderLibrary/EntityLighting.hlsl"
#include "Packages/com.unity.render-pipelines.core/ShaderLibrary/ImageBasedLighting.hlsl"
#include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Core.hlsl"
#include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Shadows.hlsl"

// If lightmap is not defined than we evaluate GI (ambient + probes) from SH
// We might do it fully or partially in vertex to save shader ALU
#if !defined(LIGHTMAP_ON)
    #if defined (_SHADER_QUALITY_LOW) || !defined(_NORMALMAP)
        // Evaluates SH fully in vertex
        #define EVALUATE_SH_VERTEX
    #elif defined (_SHADER_QUALITY_MEDIUM)
        // Evaluates L2 SH in vertex and L0L1 in pixel
        #define EVALUATE_SH_MIXED
    #endif
        // Otherwise evaluate SH fully per-pixel
#endif


#ifdef LIGHTMAP_ON
    #define DECLARE_LIGHTMAP_OR_SH(lmName, shName, index) float2 lmName : TEXCOORD##index
    #define OUTPUT_LIGHTMAP_UV(lightmapUV, lightmapScaleOffset, OUT) OUT.xy = lightmapUV.xy * lightmapScaleOffset.xy + lightmapScaleOffset.zw;
    #define OUTPUT_SH(normalWS, OUT)
#else
    #define DECLARE_LIGHTMAP_OR_SH(lmName, shName, index) half3 shName : TEXCOORD##index
    #define OUTPUT_LIGHTMAP_UV(lightmapUV, lightmapScaleOffset, OUT)
    #define OUTPUT_SH(normalWS, OUT) OUT.xyz = SampleSHVertex(normalWS)
#endif

///////////////////////////////////////////////////////////////////////////////
//                          Light Helpers                                    //
///////////////////////////////////////////////////////////////////////////////

// Abstraction over Light shading data.
struct Light
{
    half3   direction;
    half3   color;
    half    distanceAttenuation;
    half    shadowAttenuation;
};

///////////////////////////////////////////////////////////////////////////////
//                        Attenuation Functions                               /
///////////////////////////////////////////////////////////////////////////////

// Matches Unity Vanila attenuation
// Attenuation smoothly decreases to light range.
float DistanceAttenuation(float distanceSqr, half2 distanceAttenuation)
{
    // We use a shared distance attenuation for additional directional and puctual lights
    // for directional lights attenuation will be 1
    float lightAtten = rcp(distanceSqr);

#if defined (_SHADER_QUALITY_HIGH)
    // Use the smoothing factor also used in the Unity lightmapper.
    half factor = distanceSqr * distanceAttenuation.x;
    half smoothFactor = saturate(1.0h - factor * factor);
    smoothFactor = smoothFactor * smoothFactor;
#else
    // We need to smoothly fade attenuation to light range. We start fading linearly at 80% of light range
    // Therefore:
    // fadeDistance = (0.8 * 0.8 * lightRangeSq)
    // smoothFactor = (lightRangeSqr - distanceSqr) / (lightRangeSqr - fadeDistance)
    // We can rewrite that to fit a MAD by doing
    // distanceSqr * (1.0 / (fadeDistanceSqr - lightRangeSqr)) + (-lightRangeSqr / (fadeDistanceSqr - lightRangeSqr)
    // distanceSqr *        distanceAttenuation.y            +             distanceAttenuation.z
    half smoothFactor = saturate(distanceSqr * distanceAttenuation.x + distanceAttenuation.y);
#endif

    return lightAtten * smoothFactor;
}

half AngleAttenuation(half3 spotDirection, half3 lightDirection, half2 spotAttenuation)
{
    // Spot Attenuation with a linear falloff can be defined as
    // (SdotL - cosOuterAngle) / (cosInnerAngle - cosOuterAngle)
    // This can be rewritten as
    // invAngleRange = 1.0 / (cosInnerAngle - cosOuterAngle)
    // SdotL * invAngleRange + (-cosOuterAngle * invAngleRange)
    // SdotL * spotAttenuation.x + spotAttenuation.y

    // If we precompute the terms in a MAD instruction
    half SdotL = dot(spotDirection, lightDirection);
    half atten = saturate(SdotL * spotAttenuation.x + spotAttenuation.y);
    return atten * atten;
}

///////////////////////////////////////////////////////////////////////////////
//                      Light Abstraction                                    //
///////////////////////////////////////////////////////////////////////////////

Light GetMainLight()
{
    Light light;
    light.direction = _MainLightPosition.xyz;
    // unity_LightData.z is 1 when not culled by the culling mask, otherwise 0.
    light.distanceAttenuation = unity_LightData.z;
#if defined(LIGHTMAP_ON) || defined(_MIXED_LIGHTING_SUBTRACTIVE)
    // unity_ProbesOcclusion.x is the mixed light probe occlusion data
    light.distanceAttenuation *= unity_ProbesOcclusion.x;
#endif
    light.shadowAttenuation = 1.0;
    light.color = _MainLightColor.rgb;

    return light;
}

Light GetMainLight(float4 shadowCoord)
{
    Light light = GetMainLight();
    light.shadowAttenuation = MainLightRealtimeShadow(shadowCoord);
    return light;
}

// Fills a light struct given a perObjectLightIndex
Light GetAdditionalPerObjectLight(int perObjectLightIndex, float3 positionWS)
{
    // Abstraction over Light input constants
#if USE_STRUCTURED_BUFFER_FOR_LIGHT_DATA
    float4 lightPositionWS = _AdditionalLightsBuffer[perObjectLightIndex].position;
    half3 color = _AdditionalLightsBuffer[perObjectLightIndex].color.rgb;
    half4 distanceAndSpotAttenuation = _AdditionalLightsBuffer[perObjectLightIndex].attenuation;
    half4 spotDirection = _AdditionalLightsBuffer[perObjectLightIndex].spotDirection;
    half4 lightOcclusionProbeInfo = _AdditionalLightsBuffer[perObjectLightIndex].occlusionProbeChannels;
#else
    float4 lightPositionWS = _AdditionalLightsPosition[perObjectLightIndex];
    half3 color = _AdditionalLightsColor[perObjectLightIndex].rgb;
    half4 distanceAndSpotAttenuation = _AdditionalLightsAttenuation[perObjectLightIndex];
    half4 spotDirection = _AdditionalLightsSpotDir[perObjectLightIndex];
    half4 lightOcclusionProbeInfo = _AdditionalLightsOcclusionProbes[perObjectLightIndex];
#endif

    // Directional lights store direction in lightPosition.xyz and have .w set to 0.0.
    // This way the following code will work for both directional and punctual lights.
    float3 lightVector = lightPositionWS.xyz - positionWS * lightPositionWS.w;
    float distanceSqr = max(dot(lightVector, lightVector), HALF_MIN);

    half3 lightDirection = half3(lightVector * rsqrt(distanceSqr));
    half attenuation = DistanceAttenuation(distanceSqr, distanceAndSpotAttenuation.xy) * AngleAttenuation(spotDirection.xyz, lightDirection, distanceAndSpotAttenuation.zw);

    Light light;
    light.direction = lightDirection;
    light.distanceAttenuation = attenuation;
    light.shadowAttenuation = AdditionalLightRealtimeShadow(perObjectLightIndex, positionWS);
    light.color = color;

    // In case we're using light probes, we can sample the attenuation from the `unity_ProbesOcclusion`
#if defined(LIGHTMAP_ON) || defined(_MIXED_LIGHTING_SUBTRACTIVE)
    // First find the probe channel from the light.
    // Then sample `unity_ProbesOcclusion` for the baked occlusion.
    // If the light is not baked, the channel is -1, and we need to apply no occlusion.

    // probeChannel is the index in 'unity_ProbesOcclusion' that holds the proper occlusion value.
    int probeChannel = lightOcclusionProbeInfo.x;

    // lightProbeContribution is set to 0 if we are indeed using a probe, otherwise set to 1.
    half lightProbeContribution = lightOcclusionProbeInfo.y;

    half probeOcclusionValue = unity_ProbesOcclusion[probeChannel];
    light.distanceAttenuation *= max(probeOcclusionValue, lightProbeContribution);
#endif

    return light;
}

ReflectionProbeData GetAdditionalPerObjectReflectionProbe(int perObjectReflectionProbeIndex)
{
#if defined(USE_STRUCTURED_BUFFER_FOR_REFLECTION_PROBE_DATA)
    float4 probePositionWS = _ReflectionProbesBuffer[perObjectReflectionProbeIndex].position;
    float4 probeBoxMin = _ReflectionProbesBuffer[perObjectReflectionProbeIndex].boxMin;
    float4 probeBoxMax = _ReflectionProbesBuffer[perObjectReflectionProbeIndex].boxMax;
#else
// #note todo UBO implementation
    float4 probePositionWS = float4(0);
    float4 probeBoxMin = float4(0);
    float4 probeBoxMax  = float4(0);
#endif

    ReflectionProbeData probe;
    probe.position = probePositionWS;
    probe.boxMin = probeBoxMin;
    probe.boxMax = probeBoxMax;
    return probe;
}

uint GetPerObjectLightIndexOffset()
{
#if USE_STRUCTURED_BUFFER_FOR_LIGHT_DATA
    return unity_LightData.x;
#else
    return 0;
#endif
}

uint GetPerObjectReflectionProbeIndexOffset()
{
#if defined(USE_STRUCTURED_BUFFER_FOR_REFLECTION_PROBE_DATA)
    return unity_ReflectionProbeData.x;
#else
    return 0;
#endif
}

// Returns a per-object index given a loop index.
// This abstract the underlying data implementation for storing lights/light indices
int GetPerObjectLightIndex(uint index)
{
/////////////////////////////////////////////////////////////////////////////////////////////
// Structured Buffer Path                                                                   /
//                                                                                          /
// Lights and light indices are stored in StructuredBuffer. We can just index them.         /
// Currently all non-mobile platforms take this path :(                                     /
// There are limitation in mobile GPUs to use SSBO (performance / no vertex shader support) /
/////////////////////////////////////////////////////////////////////////////////////////////
#if USE_STRUCTURED_BUFFER_FOR_LIGHT_DATA
    uint offset = unity_LightData.x;
    return _AdditionalLightsIndices[offset + index];

/////////////////////////////////////////////////////////////////////////////////////////////
// UBO path                                                                                 /
//                                                                                          /
// We store 8 light indices in float4 unity_LightIndices[2];                                /
// Due to memory alignment unity doesn't support int[] or float[]                           /
// Even trying to reinterpret cast the unity_LightIndices to float[] won't work             /
// it will cast to float4[] and create extra register pressure. :(                          /
/////////////////////////////////////////////////////////////////////////////////////////////
#elif !defined(SHADER_API_GLES)
    // since index is uint shader compiler will implement
    // div & mod as bitfield ops (shift and mask).
    
    // TODO: Can we index a float4? Currently compiler is
    // replacing unity_LightIndicesX[i] with a dp4 with identity matrix.
    // u_xlat16_40 = dot(unity_LightIndices[int(u_xlatu13)], ImmCB_0_0_0[u_xlati1]);
    // This increases both arithmetic and register pressure.
    return unity_LightIndices[index / 4][index % 4];
#else
    // Fallback to GLES2. No bitfield magic here :(.
    // We limit to 4 indices per object and only sample unity_4LightIndices0.
    // Conditional moves are branch free even on mali-400
    // small arithmetic cost but no extra register pressure from ImmCB_0_0_0 matrix.
    half2 lightIndex2 = (index < 2.0h) ? unity_LightIndices[0].xy : unity_LightIndices[0].zw;
    half i_rem = (index < 2.0h) ? index : index - 2.0h;
    return (i_rem < 1.0h) ? lightIndex2.x : lightIndex2.y;
#endif
}

int GetPerObjectReflectionProbeIndex(uint index)
{
#if defined(USE_STRUCTURED_BUFFER_FOR_REFLECTION_PROBE_DATA)
    uint offset = unity_ReflectionProbeData.x;
    return _ReflectionProbeIndices[offset + index];
#else
// #note todo UBO implementation
    return -1;
#endif
}

// Fills a light struct given a loop i index. This will convert the i
// index to a perObjectLightIndex
Light GetAdditionalLight(uint i, float3 positionWS)
{
    int perObjectLightIndex = GetPerObjectLightIndex(i);
    return GetAdditionalPerObjectLight(perObjectLightIndex, positionWS);
}

ReflectionProbeData GetReflectionProbe(uint i)
{
    int perObjectReflectionProbeIndex = GetPerObjectReflectionProbeIndex(i);
    return GetAdditionalPerObjectReflectionProbe(perObjectReflectionProbeIndex);
}

int GetAdditionalLightsCount()
{
    // TODO: we need to expose in SRP api an ability for the pipeline cap the amount of lights
    // in the culling. This way we could do the loop branch with an uniform
    // This would be helpful to support baking exceeding lights in SH as well
    return min(_AdditionalLightsCount.x, unity_LightData.y);
}

int GetReflectionProbesCount()
{
    return min(_ReflectionProbesCount.x, unity_ReflectionProbeData.y);
}

///////////////////////////////////////////////////////////////////////////////
//                         BRDF Functions                                    //
///////////////////////////////////////////////////////////////////////////////

#define kDieletricSpec half4(0.04, 0.04, 0.04, 1.0 - 0.04) // standard dielectric reflectivity coef at incident angle (= 4%)

struct BRDFData
{
    half3 diffuse;
    half3 specular;
    half perceptualRoughness;
    half roughness;
    half roughness2;
    half grazingTerm;

    // We save some light invariant BRDF terms so we don't have to recompute
    // them in the light loop. Take a look at DirectBRDF function for detailed explaination.
    half normalizationTerm;     // roughness * 4.0 + 2.0
    half roughness2MinusOne;    // roughness^2 - 1.0
};

half ReflectivitySpecular(half3 specular)
{
#if defined(SHADER_API_GLES)
    return specular.r; // Red channel - because most metals are either monocrhome or with redish/yellowish tint
#else
    return max(max(specular.r, specular.g), specular.b);
#endif
}

half OneMinusReflectivityMetallic(half metallic)
{
    // We'll need oneMinusReflectivity, so
    //   1-reflectivity = 1-lerp(dielectricSpec, 1, metallic) = lerp(1-dielectricSpec, 0, metallic)
    // store (1-dielectricSpec) in kDieletricSpec.a, then
    //   1-reflectivity = lerp(alpha, 0, metallic) = alpha + metallic*(0 - alpha) =
    //                  = alpha - metallic * alpha
    half oneMinusDielectricSpec = kDieletricSpec.a;
    return oneMinusDielectricSpec - metallic * oneMinusDielectricSpec;
}

inline void InitializeBRDFData(half3 albedo, half metallic, half3 specular, half smoothness, half alpha, out BRDFData outBRDFData)
{
#ifdef _SPECULAR_SETUP
    half reflectivity = ReflectivitySpecular(specular);
    half oneMinusReflectivity = 1.0 - reflectivity;

    outBRDFData.diffuse = albedo * (half3(1.0h, 1.0h, 1.0h) - specular);
    outBRDFData.specular = specular;
#else

    half oneMinusReflectivity = OneMinusReflectivityMetallic(metallic);
    half reflectivity = 1.0 - oneMinusReflectivity;

    outBRDFData.diffuse = albedo * oneMinusReflectivity;
    outBRDFData.specular = lerp(kDieletricSpec.rgb, albedo, metallic);
#endif

    outBRDFData.grazingTerm = saturate(smoothness + reflectivity);
    outBRDFData.perceptualRoughness = PerceptualSmoothnessToPerceptualRoughness(smoothness);
    outBRDFData.roughness = max(PerceptualRoughnessToRoughness(outBRDFData.perceptualRoughness), HALF_MIN);
    outBRDFData.roughness2 = outBRDFData.roughness * outBRDFData.roughness;

    outBRDFData.normalizationTerm = outBRDFData.roughness * 4.0h + 2.0h;
    outBRDFData.roughness2MinusOne = outBRDFData.roughness2 - 1.0h;

#ifdef _ALPHAPREMULTIPLY_ON
    outBRDFData.diffuse *= alpha;
    alpha = alpha * oneMinusReflectivity + reflectivity;
#endif
}

half3 EnvironmentBRDF(BRDFData brdfData, half3 indirectDiffuse, half3 indirectSpecular, half fresnelTerm)
{
    half3 c = indirectDiffuse * brdfData.diffuse;
    float surfaceReduction = 1.0 / (brdfData.roughness2 + 1.0);
    c += surfaceReduction * indirectSpecular * lerp(brdfData.specular, brdfData.grazingTerm, fresnelTerm);
    return c;
}

// Based on Minimalist CookTorrance BRDF
// Implementation is slightly different from original derivation: http://www.thetenthplanet.de/archives/255
//
// * NDF [Modified] GGX
// * Modified Kelemen and Szirmay-Kalos for Visibility term
// * Fresnel approximated with 1/LdotH
half3 DirectBDRF(BRDFData brdfData, half3 normalWS, half3 lightDirectionWS, half3 viewDirectionWS)
{
#ifndef _SPECULARHIGHLIGHTS_OFF
    float3 halfDir = SafeNormalize(float3(lightDirectionWS) + float3(viewDirectionWS));

    float NoH = saturate(dot(normalWS, halfDir));
    half LoH = saturate(dot(lightDirectionWS, halfDir));

    // GGX Distribution multiplied by combined approximation of Visibility and Fresnel
    // BRDFspec = (D * V * F) / 4.0
    // D = roughness^2 / ( NoH^2 * (roughness^2 - 1) + 1 )^2
    // V * F = 1.0 / ( LoH^2 * (roughness + 0.5) )
    // See "Optimizing PBR for Mobile" from Siggraph 2015 moving mobile graphics course
    // https://community.arm.com/events/1155

    // Final BRDFspec = roughness^2 / ( NoH^2 * (roughness^2 - 1) + 1 )^2 * (LoH^2 * (roughness + 0.5) * 4.0)
    // We further optimize a few light invariant terms
    // brdfData.normalizationTerm = (roughness + 0.5) * 4.0 rewritten as roughness * 4.0 + 2.0 to a fit a MAD.
    float d = NoH * NoH * brdfData.roughness2MinusOne + 1.00001f;

    half LoH2 = LoH * LoH;
    half specularTerm = brdfData.roughness2 / ((d * d) * max(0.1h, LoH2) * brdfData.normalizationTerm);

    // On platforms where half actually means something, the denominator has a risk of overflow
    // clamp below was added specifically to "fix" that, but dx compiler (we convert bytecode to metal/gles)
    // sees that specularTerm have only non-negative terms, so it skips max(0,..) in clamp (leaving only min(100,...))
#if defined (SHADER_API_MOBILE) || defined (SHADER_API_SWITCH)
    specularTerm = specularTerm - HALF_MIN;
    specularTerm = clamp(specularTerm, 0.0, 100.0); // Prevent FP16 overflow on mobiles
#endif

    half3 color = specularTerm * brdfData.specular + brdfData.diffuse;
    return color;
#else
    return brdfData.diffuse;
#endif
}

///////////////////////////////////////////////////////////////////////////////
//                      Global Illumination                                  //
///////////////////////////////////////////////////////////////////////////////

// Samples SH L0, L1 and L2 terms
half3 SampleSH(half3 normalWS)
{
    // LPPV is not supported in Ligthweight Pipeline
    real4 SHCoefficients[7];
    SHCoefficients[0] = unity_SHAr;
    SHCoefficients[1] = unity_SHAg;
    SHCoefficients[2] = unity_SHAb;
    SHCoefficients[3] = unity_SHBr;
    SHCoefficients[4] = unity_SHBg;
    SHCoefficients[5] = unity_SHBb;
    SHCoefficients[6] = unity_SHC;

    return max(half3(0, 0, 0), SampleSH9(SHCoefficients, normalWS));
}

// SH Vertex Evaluation. Depending on target SH sampling might be
// done completely per vertex or mixed with L2 term per vertex and L0, L1
// per pixel. See SampleSHPixel
half3 SampleSHVertex(half3 normalWS)
{
#if defined(EVALUATE_SH_VERTEX)
    return max(half3(0, 0, 0), SampleSH(normalWS));
#elif defined(EVALUATE_SH_MIXED)
    // no max since this is only L2 contribution
    return SHEvalLinearL2(normalWS, unity_SHBr, unity_SHBg, unity_SHBb, unity_SHC);
#endif

    // Fully per-pixel. Nothing to compute.
    return half3(0.0, 0.0, 0.0);
}

// SH Pixel Evaluation. Depending on target SH sampling might be done
// mixed or fully in pixel. See SampleSHVertex
half3 SampleSHPixel(half3 L2Term, half3 normalWS)
{
#if defined(EVALUATE_SH_VERTEX)
    return L2Term;
#elif defined(EVALUATE_SH_MIXED)
    half3 L0L1Term = SHEvalLinearL0L1(normalWS, unity_SHAr, unity_SHAg, unity_SHAb);
    return max(half3(0, 0, 0), L2Term + L0L1Term);
#endif

    // Default: Evaluate SH fully per-pixel
    return SampleSH(normalWS);
}

// Sample baked lightmap. Non-Direction and Directional if available.
// Realtime GI is not supported.
half3 SampleLightmap(float2 lightmapUV, half3 normalWS)
{
#ifdef UNITY_LIGHTMAP_FULL_HDR
    bool encodedLightmap = false;
#else
    bool encodedLightmap = true;
#endif

    half4 decodeInstructions = half4(LIGHTMAP_HDR_MULTIPLIER, LIGHTMAP_HDR_EXPONENT, 0.0h, 0.0h);

    // The shader library sample lightmap functions transform the lightmap uv coords to apply bias and scale.
    // However, universal pipeline already transformed those coords in vertex. We pass half4(1, 1, 0, 0) and
    // the compiler will optimize the transform away.
    half4 transformCoords = half4(1, 1, 0, 0);

#ifdef DIRLIGHTMAP_COMBINED
    return SampleDirectionalLightmap(TEXTURE2D_ARGS(unity_Lightmap, samplerunity_Lightmap),
        TEXTURE2D_ARGS(unity_LightmapInd, samplerunity_Lightmap),
        lightmapUV, transformCoords, normalWS, encodedLightmap, decodeInstructions);
#elif defined(LIGHTMAP_ON)
    return SampleSingleLightmap(TEXTURE2D_ARGS(unity_Lightmap, samplerunity_Lightmap), lightmapUV, transformCoords, encodedLightmap, decodeInstructions);
#else
    return half3(0.0, 0.0, 0.0);
#endif
}

// We either sample GI from baked lightmap or from probes.
// If lightmap: sampleData.xy = lightmapUV
// If probe: sampleData.xyz = L2 SH terms
#ifdef UNITY_DOTS_SHADER
half3 HackSampleSH(half3 normalWS)
{
    // Hack SH so that is is valid for hybrid V1
    real4 SHCoefficients[7];
    SHCoefficients[0] = float4(-0.02611f, -0.11903f, -0.02472f, 0.55319f);
    SHCoefficients[1] = float4(-0.04123, 0.0369, -0.03903, 0.62641);
    SHCoefficients[2] = float4(-0.06967, 0.23016, -0.06596, 0.81901);
    SHCoefficients[3] = float4(-0.02041, -0.01933, 0.07292, 0.05023);
    SHCoefficients[4] = float4(-0.03278, -0.03104, 0.0992, 0.07219);
    SHCoefficients[5] = float4(-0.05806, -0.05496, 0.10764, 0.09859);
    SHCoefficients[6] = float4(0.07564, 0.10311, 0.11301, 1.00);
    return max(half3(0, 0, 0), SampleSH9(SHCoefficients, normalWS));
}
#define SAMPLE_GI(lmName, shName, normalWSName) HackSampleSH(normalWSName);
#elif defined(LIGHTMAP_ON)
#define SAMPLE_GI(lmName, shName, normalWSName) SampleLightmap(lmName, normalWSName)
#else
#define SAMPLE_GI(lmName, shName, normalWSName) SampleSHPixel(shName, normalWSName)
#endif

half3 BoxProjectedCubemapDirection(half3 reflectVector, half3 positionWS, real4 cubemapCenter, real4 boxMin, real4 boxMax)
{    
    float3 boxMinMax = (reflectVector > 0.0f) ? boxMax.xyz : boxMin.xyz;
    float3 rbMinMax = (boxMinMax - positionWS) / reflectVector;

    float fa = min(min(rbMinMax.x, rbMinMax.y), rbMinMax.z);

    half3 pos = positionWS - cubemapCenter.xyz;
    return pos + reflectVector * fa;
}

float getWeight(half3 positionWS, real4 boxMin, real4 boxMax)
{
    float blendDist = 1.0;//boxMin.w;
    float3 weightDir =  min(positionWS + blendDist - boxMin.xyz, boxMax.xyz + blendDist - positionWS) / blendDist;
    return saturate(min(weightDir.x, min(weightDir.y, weightDir.z)));
}



half3 getIrradianceFromReflectionProbes(half3 reflectVector, half3 positionWS, ReflectionProbeData reflectionProbes[2], half perceptualRoughness)
{
    //This is not like for the builtin:
    //Get a sorted list form largest reflection probe to the smallest and the smallest being rendered on top if they all have the same importance.
    //To fade reach out by 1 on each direction (The same for the deferred builtin implementation).

    //But reverse the order such the the highest priority and smallest reflection probes is first.
    float blendFactor = 1.0;
    half3 irradiance = half3(0,0,0);
/*
    // First Probe
    float weight = min(getWeight(positionWS, unity_SpecCube0_BoxMin, unity_SpecCube0_BoxMax), blendFactor);
    blendFactor = saturate(blendFactor - weight);


    half3 originalReflectVector = reflectVector;
    reflectVector = (1 - unity_SpecCube0_ProbePosition.w) * originalReflectVector
        + unity_SpecCube0_ProbePosition.w * BoxProjectedCubemapDirection(reflectVector, positionWS, unity_SpecCube0_ProbePosition, unity_SpecCube0_BoxMin, unity_SpecCube0_BoxMax);
    half mip = PerceptualRoughnessToMipmapLevel(perceptualRoughness);
    half4 encodedIrradiance = SAMPLE_TEXTURECUBE_LOD(unity_SpecCube0, samplerunity_SpecCube0, reflectVector, mip);
#if !defined(UNITY_USE_NATIVE_HDR)
    irradiance += weight * DecodeHDREnvironment(encodedIrradiance, unity_SpecCube0_HDR);
#else
    irradiance += weight * encodedIrradiance.rbg;
#endif

    // Second Probe
    
    weight = min(getWeight(positionWS, unity_SpecCube1_BoxMin, unity_SpecCube1_BoxMax), blendFactor);
    blendFactor = saturate(blendFactor - weight);


    originalReflectVector = reflectVector;
    reflectVector = (1 - unity_SpecCube1_ProbePosition.w) * originalReflectVector
        + unity_SpecCube1_ProbePosition.w * BoxProjectedCubemapDirection(reflectVector, positionWS, unity_SpecCube1_ProbePosition, unity_SpecCube1_BoxMin, unity_SpecCube1_BoxMax);
    mip = PerceptualRoughnessToMipmapLevel(perceptualRoughness);
    encodedIrradiance = SAMPLE_TEXTURECUBE_LOD(unity_SpecCube1, samplerunity_SpecCube1, reflectVector, mip);
#if !defined(UNITY_USE_NATIVE_HDR)
    irradiance += weight * DecodeHDREnvironment(encodedIrradiance, unity_SpecCube1_HDR);
#else
    irradiance += weight * encodedIrradiance.rbg;
#endif
*/

    // #note use GetReflectionProbesCount() to determine how many reflection probes we should loop over
    //    use 0 to GetReflectionProbesCount() in GetReflectionProbe(i) to get the probes

    for (int i = 0; i < 2; i++)
    {
        float weight = min(getWeight(positionWS, reflectionProbes[i].boxMin, reflectionProbes[i].boxMax), blendFactor);
        blendFactor = saturate(blendFactor - weight);


        half3 originalReflectVector = reflectVector;
        reflectVector = (1 - reflectionProbes[i].position.w) * originalReflectVector
            + reflectionProbes[i].position.w * BoxProjectedCubemapDirection(reflectVector, positionWS, reflectionProbes[i].position, reflectionProbes[i].boxMin, reflectionProbes[i].boxMax);
        half mip = PerceptualRoughnessToMipmapLevel(perceptualRoughness);
        half4 encodedIrradiance;
        // #note to do Sample TextureCubeArray
        //half4 encodedIrradiance1 = SAMPLE_TEXTURECUBE_ARRAY_LOD_ABSTRACT(_ReflectionProbeTextures, s_trilinear_clamp_sampler, reflectVector, 0, mip);
        if(i == 0)
            encodedIrradiance = SAMPLE_TEXTURECUBE_LOD(unity_SpecCube0, samplerunity_SpecCube0, reflectVector, mip);
        else
            encodedIrradiance = SAMPLE_TEXTURECUBE_LOD(unity_SpecCube1, samplerunity_SpecCube1, reflectVector, mip);
#if !defined(UNITY_USE_NATIVE_HDR)
        // #note include HDR in ReflectionProbeData buffer?
        if(i == 0)
            irradiance += weight * DecodeHDREnvironment(encodedIrradiance, unity_SpecCube0_HDR);
        else
            irradiance += weight * DecodeHDREnvironment(encodedIrradiance, unity_SpecCube1_HDR);
#else
        irradiance += weight * encodedIrradiance.rbg;
#endif
    }
    
    return irradiance;
}

half3 GlossyEnvironmentReflection(half3 reflectVector, half3 positionWS, half perceptualRoughness, half occlusion)
{
#if !defined(_ENVIRONMENTREFLECTIONS_OFF)
    ReflectionProbeData reflectionProbes[2];
    reflectionProbes[0] = GetReflectionProbe(0);
    reflectionProbes[1] = GetReflectionProbe(1);
    half3 irradiance = getIrradianceFromReflectionProbes(reflectVector, positionWS, reflectionProbes, perceptualRoughness);
    return irradiance * occlusion;
#endif // GLOSSY_REFLECTIONS
    return _GlossyEnvironmentColor.rgb * occlusion;
}
    /*
    half3 blend = unity_SpecCube0_BoxMin.w;
    //blend = getBlend();
#if !defined(_ENVIRONMENTREFLECTIONS_OFF)
#if REFLECTION_PROBE
    half3 originalReflectVector = reflectVector;
    reflectVector = (1 - unity_SpecCube0_ProbePosition.w) * originalReflectVector
                        + unity_SpecCube0_ProbePosition.w * BoxProjectedCubemapDirection(reflectVector, positionWS, unity_SpecCube0_ProbePosition, unity_SpecCube0_BoxMin, unity_SpecCube0_BoxMax);
    half mip = PerceptualRoughnessToMipmapLevel(perceptualRoughness);
    half4 encodedIrradiance0 = SAMPLE_TEXTURECUBE_LOD(unity_SpecCube0, samplerunity_SpecCube0, reflectVector, mip);

#if 0//BLEND_REFLECTION_PROBE

    reflectVector = (1 - unity_SpecCube1_ProbePosition.w) * originalReflectVector
                        + unity_SpecCube1_ProbePosition.w * BoxProjectedCubemapDirection(originalReflectVector, positionWS, unity_SpecCube1_ProbePosition, unity_SpecCube1_BoxMin, unity_SpecCube1_BoxMax);

    half4 encodedIrradiance1 = SAMPLE_TEXTURECUBE_LOD(unity_SpecCube1, samplerunity_SpecCube1, reflectVector, mip);
#if !defined(UNITY_USE_NATIVE_HDR)
    half3 irradiance0 = DecodeHDREnvironment(encodedIrradiance0, unity_SpecCube0_HDR);
    half3 irradiance1 = DecodeHDREnvironment(encodedIrradiance1, unity_SpecCube1_HDR);
    half3 irradiance = irradiance0 * blend + irradiance1 * (1 - blend);
#else
    half4 encodedIrradiance = encodedIrradiance0 * blend + encodedIrradiance1 * (1 - blend);
    half3 irradiance = encodedIrradiance.rbg;
#endif
#else
#if !defined(UNITY_USE_NATIVE_HDR)
    half3 irradiance = DecodeHDREnvironment(encodedIrradiance0, unity_SpecCube0_HDR);
#else
    half3 irradiance = encodedIrradiance0.rbg;
#endif
#endif // BLEND_REFLECTION_PROBE
    return irradiance * occlusion;
#endif // REFLECTION_PROBE
#endif // GLOSSY_REFLECTIONS
    return _GlossyEnvironmentColor.rgb * occlusion;
}
    */

half3 SubtractDirectMainLightFromLightmap(Light mainLight, half3 normalWS, half3 bakedGI)
{
    // Let's try to make realtime shadows work on a surface, which already contains
    // baked lighting and shadowing from the main sun light.
    // Summary:
    // 1) Calculate possible value in the shadow by subtracting estimated light contribution from the places occluded by realtime shadow:
    //      a) preserves other baked lights and light bounces
    //      b) eliminates shadows on the geometry facing away from the light
    // 2) Clamp against user defined ShadowColor.
    // 3) Pick original lightmap value, if it is the darkest one.


    // 1) Gives good estimate of illumination as if light would've been shadowed during the bake.
    // We only subtract the main direction light. This is accounted in the contribution term below.
    half shadowStrength = GetMainLightShadowStrength();
    half contributionTerm = saturate(dot(mainLight.direction, normalWS));
    half3 lambert = mainLight.color * contributionTerm;
    half3 estimatedLightContributionMaskedByInverseOfShadow = lambert * (1.0 - mainLight.shadowAttenuation);
    half3 subtractedLightmap = bakedGI - estimatedLightContributionMaskedByInverseOfShadow;

    // 2) Allows user to define overall ambient of the scene and control situation when realtime shadow becomes too dark.
    half3 realtimeShadow = max(subtractedLightmap, _SubtractiveShadowColor.xyz);
    realtimeShadow = lerp(bakedGI, realtimeShadow, shadowStrength);

    // 3) Pick darkest color
    return min(bakedGI, realtimeShadow);
}

half3 GlobalIllumination(BRDFData brdfData, half3 bakedGI, half occlusion, half3 positionWS, half3 normalWS, half3 viewDirectionWS)
{
    half3 reflectVector = reflect(-viewDirectionWS, normalWS);
    half fresnelTerm = Pow4(1.0 - saturate(dot(normalWS, viewDirectionWS)));

    half3 indirectDiffuse = bakedGI * occlusion;
    half3 indirectSpecular = GlossyEnvironmentReflection(reflectVector, positionWS, brdfData.perceptualRoughness, occlusion);

    return EnvironmentBRDF(brdfData, indirectDiffuse, indirectSpecular, fresnelTerm);
}

void MixRealtimeAndBakedGI(inout Light light, half3 normalWS, inout half3 bakedGI, half4 shadowMask)
{
#if defined(_MIXED_LIGHTING_SUBTRACTIVE) && defined(LIGHTMAP_ON)
    bakedGI = SubtractDirectMainLightFromLightmap(light, normalWS, bakedGI);
#endif
}

///////////////////////////////////////////////////////////////////////////////
//                      Lighting Functions                                   //
///////////////////////////////////////////////////////////////////////////////
half3 LightingLambert(half3 lightColor, half3 lightDir, half3 normal)
{
    half NdotL = saturate(dot(normal, lightDir));
    return lightColor * NdotL;
}

half3 LightingSpecular(half3 lightColor, half3 lightDir, half3 normal, half3 viewDir, half4 specular, half smoothness)
{
    float3 halfVec = SafeNormalize(float3(lightDir) + float3(viewDir));
    half NdotH = saturate(dot(normal, halfVec));
    half modifier = pow(NdotH, smoothness);
    half3 specularReflection = specular.rgb * modifier;
    return lightColor * specularReflection;
}

half3 LightingPhysicallyBased(BRDFData brdfData, half3 lightColor, half3 lightDirectionWS, half lightAttenuation, half3 normalWS, half3 viewDirectionWS)
{
    half NdotL = saturate(dot(normalWS, lightDirectionWS));
    half3 radiance = lightColor * (lightAttenuation * NdotL);
    return DirectBDRF(brdfData, normalWS, lightDirectionWS, viewDirectionWS) * radiance;
}

half3 LightingPhysicallyBased(BRDFData brdfData, Light light, half3 normalWS, half3 viewDirectionWS)
{
    return LightingPhysicallyBased(brdfData, light.color, light.direction, light.distanceAttenuation * light.shadowAttenuation, normalWS, viewDirectionWS);
}

half3 VertexLighting(float3 positionWS, half3 normalWS)
{
    half3 vertexLightColor = half3(0.0, 0.0, 0.0);

#ifdef _ADDITIONAL_LIGHTS_VERTEX
    uint lightsCount = GetAdditionalLightsCount();
    for (uint lightIndex = 0u; lightIndex < lightsCount; ++lightIndex)
    {
        Light light = GetAdditionalLight(lightIndex, positionWS);
        half3 lightColor = light.color * light.distanceAttenuation;
        vertexLightColor += LightingLambert(lightColor, light.direction, normalWS);
    }
#endif

    return vertexLightColor;
}

///////////////////////////////////////////////////////////////////////////////
//                      Fragment Functions                                   //
//       Used by ShaderGraph and others builtin renderers                    //
///////////////////////////////////////////////////////////////////////////////
half4 UniversalFragmentPBR(InputData inputData, half3 albedo, half metallic, half3 specular,
    half smoothness, half occlusion, half3 emission, half alpha)
{
    BRDFData brdfData;
    InitializeBRDFData(albedo, metallic, specular, smoothness, alpha, brdfData);
    
    Light mainLight = GetMainLight(inputData.shadowCoord);
    mainLight.shadowAttenuation = ApplyShadowFade(mainLight.shadowAttenuation, inputData.positionWS);
    MixRealtimeAndBakedGI(mainLight, inputData.normalWS, inputData.bakedGI, half4(0, 0, 0, 0));

    half3 color = GlobalIllumination(brdfData, inputData.bakedGI, occlusion, inputData.positionWS, inputData.normalWS, inputData.viewDirectionWS);
    color += LightingPhysicallyBased(brdfData, mainLight, inputData.normalWS, inputData.viewDirectionWS);

#ifdef _ADDITIONAL_LIGHTS
    uint pixelLightCount = GetAdditionalLightsCount();
    for (uint lightIndex = 0u; lightIndex < pixelLightCount; ++lightIndex)
    {
        Light light = GetAdditionalLight(lightIndex, inputData.positionWS);
        light.shadowAttenuation = ApplyShadowFade(light.shadowAttenuation, inputData.positionWS);
        color += LightingPhysicallyBased(brdfData, light, inputData.normalWS, inputData.viewDirectionWS);
    }
#endif

#ifdef _ADDITIONAL_LIGHTS_VERTEX
    color += inputData.vertexLighting * brdfData.diffuse;
#endif

    color += emission;
    return half4(color, alpha);
}

half4 UniversalFragmentBlinnPhong(InputData inputData, half3 diffuse, half4 specularGloss, half smoothness, half3 emission, half alpha)
{
    Light mainLight = GetMainLight(inputData.shadowCoord);
    mainLight.shadowAttenuation = ApplyShadowFade(mainLight.shadowAttenuation, inputData.positionWS);
    MixRealtimeAndBakedGI(mainLight, inputData.normalWS, inputData.bakedGI, half4(0, 0, 0, 0));

    half3 attenuatedLightColor = mainLight.color * (mainLight.distanceAttenuation * mainLight.shadowAttenuation);
    half3 diffuseColor = inputData.bakedGI + LightingLambert(attenuatedLightColor, mainLight.direction, inputData.normalWS);
    half3 specularColor = LightingSpecular(attenuatedLightColor, mainLight.direction, inputData.normalWS, inputData.viewDirectionWS, specularGloss, smoothness);

#ifdef _ADDITIONAL_LIGHTS
    uint pixelLightCount = GetAdditionalLightsCount();
    for (uint lightIndex = 0u; lightIndex < pixelLightCount; ++lightIndex)
    {
        Light light = GetAdditionalLight(lightIndex, inputData.positionWS);
        light.shadowAttenuation = ApplyShadowFade(light.shadowAttenuation, inputData.positionWS);
        half3 attenuatedLightColor = light.color * (light.distanceAttenuation * light.shadowAttenuation);
        diffuseColor += LightingLambert(attenuatedLightColor, light.direction, inputData.normalWS);
        specularColor += LightingSpecular(attenuatedLightColor, light.direction, inputData.normalWS, inputData.viewDirectionWS, specularGloss, smoothness);
    }
#endif

#ifdef _ADDITIONAL_LIGHTS_VERTEX
    diffuseColor += inputData.vertexLighting;
#endif

    half3 finalColor = diffuseColor * diffuse + emission;

#if defined(_SPECGLOSSMAP) || defined(_SPECULAR_COLOR)
    finalColor += specularColor;
#endif

    return half4(finalColor, alpha);
}

//LWRP -> Universal Backwards Compatibility
half4 LightweightFragmentPBR(InputData inputData, half3 albedo, half metallic, half3 specular,
    half smoothness, half occlusion, half3 emission, half alpha)
{
    return UniversalFragmentPBR(inputData, albedo, metallic, specular, smoothness, occlusion, emission, alpha);
}

half4 LightweightFragmentBlinnPhong(InputData inputData, half3 diffuse, half4 specularGloss, half smoothness, half3 emission, half alpha)
{
    return UniversalFragmentBlinnPhong(inputData, diffuse, specularGloss, smoothness, emission, alpha);
}
#endif
