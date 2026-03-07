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
    float selection; // 1 = ACES, 2 = Reinhard, 3 = Habel, 4 = Möbius
};

// ✅ ACES RRT + ODT Implementation
float3 RRTAndODTFit(float3 color) {
    // Constants used in the ACES Filmic tone mapping
    float A = 2.51f;  // Constant A
    float B = 0.03f;  // Constant B
    float C = 2.43f;  // Constant C
    float D = 0.59f;  // Constant D
    float E = 0.14f;  // Constant E

    // Apply the ACES RRT + ODT
    color = (color * (A * color + B)) / (color * (C * color + D) + E);
    
    return color;
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
        colorBT.rgb = BT2390Tonemap(colorBT.rgb);  // Apply BT.2390 EETF Tone Mapping
    }
    else {
        color.rgb = ACESFilmTonemap(color.rgb);  // Default to ACES if selection is invalid
    }

    // Scale to display peak brightness after tone mapping
    color.rgb *= displayMaxNits;

    // Convert back from linear to PQ color space
    color = LinearToST2084(color, 10000.0f);  // Convert Linear to PQ
    colorBT = LinearToST2084(colorBT, 10000.0f); // Convert original for BT.2390
    
    if (sel == 5)
    {
        return float4(colorBT.rgb, colorBT.a); // Output BT.2390 result
    }

    return float4(color.rgb, color.a); // Final output
}
