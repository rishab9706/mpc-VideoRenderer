#include "../convert/st2084.hlsl"

Texture2D tex : register(t0);
SamplerState samp : register(s0);

struct PS_INPUT
{
    float4 Pos : SV_POSITION;
    float2 Tex : TEXCOORD;
};

cbuffer RootConstants : register(b0)
{
    float MasteringMinLuminanceNits;
    float MasteringMaxLuminanceNits;
    float maxCLL;
    float maxFALL;
    float displayMaxNits;
    float selection;
};

cbuffer DolbyConstants : register(b1)
{
    float ChromaWeight;
    float SaturationGain;
    float TrimSlope;
    float TrimOffset;
    float TrimPower;
};

// ==============================================================================
// LINEAR RGB (BT.2020) TO IPTPQc2 (Dolby ST 2094-10 Space)
// ==============================================================================
float3 RGB_to_IPT(float3 rgb_nits)
{
    // 1. Libplacebo RGB->LMS (HPE)
    float3 lms;
    lms.x = 0.40024f * rgb_nits.r + 0.70760f * rgb_nits.g - 0.08081f * rgb_nits.b;
    lms.y = -0.22630f * rgb_nits.r + 1.16532f * rgb_nits.g + 0.04570f * rgb_nits.b;
    lms.z = 0.00000f * rgb_nits.r + 0.00000f * rgb_nits.g + 0.91822f * rgb_nits.b;

    // 2. Signed PQ Encoding (Preserves negative out-of-gamut values)
    float L_PQ = sign(lms.x) * LinearToST2084(abs(lms.x), 10000.0f);
    float M_PQ = sign(lms.y) * LinearToST2084(abs(lms.y), 10000.0f);
    float S_PQ = sign(lms.z) * LinearToST2084(abs(lms.z), 10000.0f);

    // 3. Ebner & Fairchild 1998 LMS->IPT Matrix
    float3 ipt;
    ipt.x = 0.4000f * L_PQ + 0.4000f * M_PQ + 0.2000f * S_PQ;
    ipt.y = 4.4550f * L_PQ - 4.8510f * M_PQ + 0.3960f * S_PQ;
    ipt.z = 0.8056f * L_PQ + 0.3572f * M_PQ - 1.1628f * S_PQ;
    return ipt;
}

float3 IPT_to_RGB(float3 ipt)
{
    // 1. Ebner & Fairchild 1998 IPT->LMS Matrix (Numerically Inverted)
    float3 lmspq;
    lmspq.x = 1.0f * ipt.x + 0.0975689f * ipt.y + 0.205226f * ipt.z;
    lmspq.y = 1.0f * ipt.x - 0.1138760f * ipt.y + 0.133217f * ipt.z;
    lmspq.z = 1.0f * ipt.x + 0.0326151f * ipt.y - 0.676887f * ipt.z;

    // 2. Signed exact PQ Decoding
    float3 lms;
    lms.x = sign(lmspq.x) * ST2084ToLinear(abs(lmspq.x), 10000.0f);
    lms.y = sign(lmspq.y) * ST2084ToLinear(abs(lmspq.y), 10000.0f);
    lms.z = sign(lmspq.z) * ST2084ToLinear(abs(lmspq.z), 10000.0f);

    // 3. Libplacebo LMS->RGB Matrix (Inverted Crosstalk matrix)
    float3 rgb_nits;
    rgb_nits.r = 1.859936f * lms.x - 1.129382f * lms.y + 0.219897f * lms.z;
    rgb_nits.g = 0.361191f * lms.x + 0.638812f * lms.y - 0.000006f * lms.z;
    rgb_nits.b = 0.000000f * lms.x + 0.000000f * lms.y + 1.089064f * lms.z;

    return rgb_nits;
}

float3 hullDesat(float3 ipt, float i_orig)
{
    float2 hull = float2(i_orig, ipt.x);

    // Libplacebo's custom polynomial smoothing curve
    hull = ((hull - 6.0f) * hull + 9.0f) * hull;

    // Calculate ratios safely to avoid NaN on pure black (0.0) pixels
    float ratio_orig = i_orig / max(1e-6f, ipt.x);
    float ratio_hull = hull.y / max(1e-6f, hull.x);

    // Scale the chroma (Y and Z) channels
    ipt.y *= min(ratio_orig, ratio_hull);
    ipt.z *= min(ratio_orig, ratio_hull);
    
    return ipt;
}

float3 applyDolbyChromaSat(float3 ipt)
{
    if (abs(ChromaWeight) > 0.0001f || abs(SaturationGain - 1.0f) > 0.0001f)
    {

        // SATURATION GAIN: Manually scale the color volume up or down based on the colorist's intent.
        ipt.y *= SaturationGain;
        ipt.z *= SaturationGain;
    }
    
    return ipt;
}

float3 applyDolbyTrim(float3 ipt)
{
    // TRIM CURVE: Apply a custom curve to the intensity channel to fine-tune the overall contrast and brightness response.
    ipt.x = pow(ipt.x * TrimSlope + TrimOffset, TrimPower);
    
    return ipt;
}

// ✅ ACES RRT + ODT Implementation
float3 RRTAndODTFit(float3 color)
{
    // Constants used in the ACES Filmic tone mapping
    float A = 2.51f; // Constant A
    float B = 0.03f; // Constant B
    float C = 2.43f; // Constant C
    float D = 0.59f; // Constant D
    float E = 0.14f; // Constant E

    // Apply the ACES RRT + ODT
    color = (color * (A * color + B)) / (color * (C * color + D) + E);
    
    return color;
}

float pl_smoothstep(float edge0, float edge1, float x)
{
    float t = clamp((x - edge0) / (edge1 - edge0), 0.0f, 1.0f);
    return t * t * (3.0f - 2.0f * t);
}

// --- ST 2094-10 EETF Tone Mapping Function
float3 ST209410Tonemap(float ipt_i)
{
    if (displayMaxNits >= maxCLL)
        return ipt_i;
   
    float src_min = LinearToST2084(MasteringMinLuminanceNits, 10000.0f);
    float src_max = LinearToST2084(maxCLL, 10000.0f);
    float src_avg = LinearToST2084(maxFALL, 10000.0f);
    float dst_min = LinearToST2084(0.0f, 10000.0f);
    float dst_max = LinearToST2084(displayMaxNits, 10000.0f);

    const float min_knee = 0.1f;
    const float max_knee = 0.8f;
    const float def_knee = 0.4f;
    const float knee_adaptation = 0.4f;

    const float src_knee_min = lerp(src_min, src_max, min_knee);
    const float src_knee_max = lerp(src_min, src_max, max_knee);
    const float dst_knee_min = lerp(dst_min, dst_max, min_knee);
    const float dst_knee_max = lerp(dst_min, dst_max, max_knee);

    float src_knee = (maxFALL > 0.0f) ? src_avg : lerp(src_min, src_max, def_knee);
    src_knee = clamp(src_knee, src_knee_min, src_knee_max);

    float target = (src_knee - src_min) / (src_max - src_min);
    float adapted = lerp(dst_min, dst_max, target);

    float tuning = 1.0f - pl_smoothstep(max_knee, def_knee, target) * pl_smoothstep(min_knee, def_knee, target);
    float adaptation = lerp(knee_adaptation, 1.0f, tuning);
    
    float dst_knee = lerp(src_knee, adapted, adaptation);
    dst_knee = clamp(dst_knee, dst_knee_min, dst_knee_max);

    float out_src_knee = ST2084ToLinear(src_knee, 10000.0f);
    float out_dst_knee = ST2084ToLinear(dst_knee, 10000.0f);

    float x1 = MasteringMinLuminanceNits;
    float x3 = maxCLL;
    float x2 = out_src_knee;

    float y1 = 0.0f;
    float y3 = displayMaxNits;
    float y2 = out_dst_knee;

    // Build the 3x3 cmat array
    float m00 = x2 * x3 * (y2 - y3);
    float m01 = x1 * x3 * (y3 - y1);
    float m02 = x1 * x2 * (y1 - y2);
    float m10 = x3 * y3 - x2 * y2;
    float m11 = x1 * y1 - x3 * y3;
    float m12 = x2 * y2 - x1 * y1;
    float m20 = x3 - x2;
    float m21 = x1 - x3;
    float m22 = x2 - x1;

    float coef0 = m00 * y1 + m01 * y2 + m02 * y3;
    float coef1 = m10 * y1 + m11 * y2 + m12 * y3;
    float coef2 = m20 * y1 + m21 * y2 + m22 * y3;

    float k = 1.0f / (x3 * y3 * (x1 - x2) + x2 * y2 * (x3 - x1) + x1 * y1 * (x2 - x3));
    
    float c1 = k * coef0;
    float c2 = k * coef1;
    float c3 = k * coef2;

    // Transform PQ Intensity to Linear Nits
    float I_nits = ST2084ToLinear(ipt_i, 10000.0f);
    
    // Apply libplacebo's rational polynomial curve
    float I_mapped_nits = (c1 + c2 * I_nits) / (1.0f + c3 * I_nits);
    return LinearToST2084(I_mapped_nits, 10000.0f);
}

// --- BT.2390 EETF Tone Mapping Function ---
float3 BT2390Tonemap(float3 color)
{
    //Safe Metadata Fallbacks (Fixes black screens on bad video files)
    float safeMaxCLL = maxCLL;
    if (safeMaxCLL <= 10.0f)
        safeMaxCLL = MasteringMaxLuminanceNits;
    if (safeMaxCLL <= 10.0f)
        safeMaxCLL = 1000.0f; // Ultimate safety fallback
    // Optimization: Skip processing if display is brighter than the content
    if (displayMaxNits >= safeMaxCLL)
        return color;

    // Find the average RGB component to preserve hue and saturation
    float avgRGB = 0.2627 * color.r + 0.6780 * color.g + 0.0593 * color.b; // Use average instead of max to better preserve color balance)
    
    // Avoid division by zero on pure black pixels
    if (avgRGB <= 0.000001)
        return color;

    // Convert peaks and current pixel luminance to PQ space
    float maxCLL_PQ = LinearToST2084(safeMaxCLL, 10000.0f);
    float target_PQ = LinearToST2084(displayMaxNits,10000.0f);
    float E1 = LinearToST2084(avgRGB, 10000.0f);

    // Calculate BT.2390 Knee Start (KS) point
    float KS = 1.5 * target_PQ - 0.5 * maxCLL_PQ;
    KS = max(0.0, KS); // Knee Start cannot be negative

    float E2 = E1;

    // Apply the Hermite Spline roll-off if the pixel is brighter than the Knee
    if (E1 > KS)
    {
        // max(1e-6, ...) prevents division by zero if maxCLL_PQ happens to equal KS
        float T = (E1 - KS) / max(1e-6, maxCLL_PQ - KS);
        float T2 = T * T;
        float T3 = T2 * T;
        
        E2 = (2.0 * T3 - 3.0 * T2 + 1.0) * KS +
             (T3 - 2.0 * T2 + T) * (maxCLL_PQ - KS) +
             (-2.0 * T3 + 3.0 * T2) * target_PQ;
    }

    // Convert the tone-mapped PQ value back to linear light
    float linearMapped = ST2084ToLinear(E2, 10000.0f);

    // 8. Scale the original RGB channels equally to preserve the exact color hue
    float3 mappedColor = color * (linearMapped / avgRGB);

    return mappedColor;
}

// ✅ ACES Tone Mapping
float3 ACESFilmTonemap(float3 color) {
    return RRTAndODTFit(color);
}

// ✅ Reinhard Tone Mapping
float3 ReinhardTonemap(float3 color) {
    return color / (1.0 + color);
}

// ✅ Habel Tone Mapping
float3 HabelTonemap(float3 color) {
    float A = 0.15, B = 0.50, C = 0.10, D = 0.20, E = 0.02, F = 0.30;
    return ((color * (A * color + C * B) + D * E) / (color * (A * color + B) + D * F)) - E / F;
}

// ✅ Möbius Tone Mapping
float3 MobiusTonemap(float3 color) {
    float epsilon = 1e-6;
    float maxL = displayMaxNits;
    return color / (1.0 + color / (maxL + epsilon));
}

// ✅ Main Shader Entry Point
float4 main(PS_INPUT input) : SV_Target {
    // Sample texture and convert from PQ to linear
    float4 color = tex.Sample(samp, input.Tex);
    color = ST2084ToLinear(color, 10000.0f); // Convert PQ to Linear space
    float4 colorBT = color; // Keep a copy for BT.2390 processing

    float effectiveMaxLum = min(MasteringMaxLuminanceNits, maxCLL);
    float fallAdjustment = min(MasteringMaxLuminanceNits / maxFALL, 1.0);

    if (displayMaxNits > MasteringMaxLuminanceNits) {
        effectiveMaxLum = min(displayMaxNits, maxCLL);
        fallAdjustment = min(displayMaxNits / maxFALL, 1.0);
    }
    
    // Apply global normalization **before tone mapping**
    color.rgb *= (1.0f / effectiveMaxLum);
    color.rgb = saturate(color.rgb);
    color.rgb *= fallAdjustment;

    int sel = (int) selection;
    // Select the tone mapping function based on `selection`
    if (sel == 1) {
        color.rgb = ACESFilmTonemap(color.rgb);  // Apply ACES Tone Mapping
    }
    else if (sel == 2) {
        color.rgb = ReinhardTonemap(color.rgb);  // Apply Reinhard Tone Mapping
    }
    else if (sel == 3) {
        color.rgb = HabelTonemap(color.rgb);  // Apply Habel Tone Mapping
    }
    else if (sel == 4) {
        color.rgb = MobiusTonemap(color.rgb);  // Apply Möbius Tone Mapping
    }
    else if (sel == 5) {
        colorBT.rgb = BT2390Tonemap(colorBT.rgb);
    }
    else if (sel == 6)
    {
        float3 ipt = RGB_to_IPT(colorBT.rgb);
        float i_orig = ipt.x;

        ipt.x = ST209410Tonemap(i_orig);
        
        float3 iptTrimmed = applyDolbyTrim(ipt);
        
        float3 iptDesat = hullDesat(iptTrimmed, i_orig);

        colorBT.rgb = IPT_to_RGB(iptDesat);
    }
    else
    {
        color.rgb = ACESFilmTonemap(color.rgb); // Default to ACES if selection is invalid
    }

    // Scale to display peak brightness after tone mapping
    color.rgb *= displayMaxNits;

    // Convert back from linear to PQ color space
    color = LinearToST2084(color, 10000.0f);  // Convert Linear to PQ
    colorBT = LinearToST2084(colorBT, 10000.0f); // Convert original for BT.2390
    
    if (sel == 5 || sel == 6)
    {
        return float4(colorBT.rgb, colorBT.a); // Output BT.2390 result
    }

    return float4(color.rgb, color.a); // Final output
}
