#pragma once
#include <algorithm>
#include <cmath>
#include "MediaSampleSideData.h"

struct DoViFrameLuminance {
    bool hasL1 = false;
    bool hasL3 = false;
    float maxNits = 0.0f;
    float minNits = 0.0f;
    float avgNits = 0.0f;
};

struct DoViInterpolatedTrims {
    bool isValid = false;
    float trimSlope = 1.0f;
    float trimOffset = 0.0f;
    float trimPower = 1.0f;
    float trimChromaWeight = 0.0f;
    float trimSaturationGain = 0.0f;
};

class CDolbyVisionParser {
public:
    // Initialize with the raw metadata struct
    explicit CDolbyVisionParser(const MediaSideDataDOVIMetadata* pMetadata);

    float GetMasteringMaxNits() const;
    float GetMasteringMinNits() const;

    // Parses L1 and applies L3 offsets automatically
    DoViFrameLuminance GetFrameLuminance() const;

    // Parses L2 and interpolates based on the user's specific TV
    DoViInterpolatedTrims GetInterpolatedTrims(float displayMaxNits) const;

private:
    const MediaSideDataDOVIMetadata* m_pMetadata;

    // Internal Math Constants
    static constexpr float PQ_M1 = 2610.f / (4096.f * 4.f);
    static constexpr float PQ_M2 = 2523.f / 4096.f * 128.f;
    static constexpr float PQ_C1 = 3424.f / 4096.f;
    static constexpr float PQ_C2 = 2413.f / 4096.f * 32.f;
    static constexpr float PQ_C3 = 2392.f / 4096.f * 32.f;

    static float PqToLinearNits(float x);
    static float LinearNitsToPq(float y);
};