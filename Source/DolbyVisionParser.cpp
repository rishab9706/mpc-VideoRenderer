#include "stdafx.h"
#include "DolbyVisionParser.h"

CDolbyVisionParser::CDolbyVisionParser(const MediaSideDataDOVIMetadata* pMetadata)
    : m_pMetadata(pMetadata) {
}

float CDolbyVisionParser::PqToLinearNits(float x) {
    x = powf(x, 1.0f / PQ_M2);
    x = fmaxf(x - PQ_C1, 0.0f) / (PQ_C2 - PQ_C3 * x);
    x = powf(x, 1.0f / PQ_M1);
    return x * 10000.0f;
}

float CDolbyVisionParser::LinearNitsToPq(float y) {
    y /= 10000.0f;
    y = fmaxf(y, 0.0f);
    y = powf(y, PQ_M1);
    y = (PQ_C1 + PQ_C2 * y) / (1.0f + PQ_C3 * y);
    return powf(y, PQ_M2);
}

float CDolbyVisionParser::GetMasteringMaxNits() const {
    if (!m_pMetadata) return 1000.0f;
    return PqToLinearNits(m_pMetadata->ColorMetadata.source_max_pq / 4095.0f);
}

float CDolbyVisionParser::GetMasteringMinNits() const {
    if (!m_pMetadata) return 0.0f;
    return PqToLinearNits(m_pMetadata->ColorMetadata.source_min_pq / 4095.0f);
}

DoViFrameLuminance CDolbyVisionParser::GetFrameLuminance() const {
    DoViFrameLuminance result;
    if (!m_pMetadata) return result;

    uint16_t frame_max_pq = 0, frame_min_pq = 0, frame_avg_pq = 0;
    int frame_max_pq_offset = 0, frame_min_pq_offset = 0, frame_avg_pq_offset = 0;

    for (int i = 0; i < 32; ++i) {
        const auto& ext = m_pMetadata->Extensions[i];
        if (ext.level == 1) {
            frame_max_pq = ext.Level1.max_pq;
            frame_min_pq = ext.Level1.min_pq;
            frame_avg_pq = ext.Level1.avg_pq;
            result.hasL1 = true;
        }
        else if (ext.level == 3) {
            frame_max_pq_offset = ext.Level3.max_pq_offset - 2048;
            frame_min_pq_offset = ext.Level3.min_pq_offset - 2048;
            frame_avg_pq_offset = ext.Level3.avg_pq_offset - 2048;
            result.hasL3 = true;
        }
    }

    if (result.hasL1) {
        result.maxNits = PqToLinearNits((frame_max_pq + frame_max_pq_offset) / 4095.f);
        result.minNits = PqToLinearNits((frame_min_pq + frame_min_pq_offset) / 4095.f);
        result.avgNits = PqToLinearNits((frame_avg_pq + frame_avg_pq_offset) / 4095.f);
    }
    return result;
}

DoViInterpolatedTrims CDolbyVisionParser::GetInterpolatedTrims(float displayMaxNits) const {
    DoViInterpolatedTrims result;
    if (!m_pMetadata) return result;

    float display_pq = LinearNitsToPq(displayMaxNits);
    float master_pq = m_pMetadata->ColorMetadata.source_max_pq / 4095.0f;

    int lower_index = -1, upper_index = -1;
    float closest_lower_dist = 1.0f, closest_upper_dist = 1.0f;

    // Find closest targets
    for (int i = 0; i < 32; ++i) {
        const auto& ext = m_pMetadata->Extensions[i];
        if (ext.level == 2) {
            result.isValid = true;
            float target_pq = ext.Level2.target_max_pq / 4095.0f;
            if (target_pq <= display_pq) {
                float dist = display_pq - target_pq;
                if (dist < closest_lower_dist) {
                    closest_lower_dist = dist;
                    lower_index = i;
                }
            }
            else {
                float dist = target_pq - display_pq;
                if (dist < closest_upper_dist) {
                    closest_upper_dist = dist;
                    upper_index = i;
                }
            }
        }
    }

    if (result.isValid) {
        float t_slope = 1.0f, t_offset = 0.0f, t_power = 1.0f;
        float t_chroma = 0.0f, t_sat = 0.0f;

        // SCENARIO A: Display is BETWEEN two targets
        if (lower_index != -1 && upper_index != -1) {
            float lower_pq = m_pMetadata->Extensions[lower_index].Level2.target_max_pq / 4095.0f;
            float upper_pq = m_pMetadata->Extensions[upper_index].Level2.target_max_pq / 4095.0f;

            float weight = (upper_pq != lower_pq) ? (display_pq - lower_pq) / (upper_pq - lower_pq) : 0.0f;
            weight = std::clamp(weight, 0.0f, 1.0f);

            t_slope = std::lerp((float)m_pMetadata->Extensions[lower_index].Level2.trim_slope, (float)m_pMetadata->Extensions[upper_index].Level2.trim_slope, weight);
            t_offset = std::lerp((float)m_pMetadata->Extensions[lower_index].Level2.trim_offset, (float)m_pMetadata->Extensions[upper_index].Level2.trim_offset, weight);
            t_power = std::lerp((float)m_pMetadata->Extensions[lower_index].Level2.trim_power, (float)m_pMetadata->Extensions[upper_index].Level2.trim_power, weight);
            t_chroma = std::lerp((float)m_pMetadata->Extensions[lower_index].Level2.trim_chroma_weight, (float)m_pMetadata->Extensions[upper_index].Level2.trim_chroma_weight, weight);
            t_sat = std::lerp((float)m_pMetadata->Extensions[lower_index].Level2.trim_saturation_gain, (float)m_pMetadata->Extensions[upper_index].Level2.trim_saturation_gain, weight);
        }
        // SCENARIO B: Display is BRIGHTER than all targets (Interpolate towards Master/Neutral)
        else if (lower_index != -1 && upper_index == -1) {
            float lower_pq = m_pMetadata->Extensions[lower_index].Level2.target_max_pq / 4095.0f;
            float weight = (master_pq > lower_pq) ? (display_pq - lower_pq) / (master_pq - lower_pq) : 0.0f;
            weight = std::clamp(weight, 0.0f, 1.0f);

            t_slope = std::lerp((float)m_pMetadata->Extensions[lower_index].Level2.trim_slope, 2048.0f, weight);
            t_offset = std::lerp((float)m_pMetadata->Extensions[lower_index].Level2.trim_offset, 2048.0f, weight);
            t_power = std::lerp((float)m_pMetadata->Extensions[lower_index].Level2.trim_power, 2048.0f, weight);
            t_chroma = std::lerp((float)m_pMetadata->Extensions[lower_index].Level2.trim_chroma_weight, 2048.0f, weight);
            t_sat = std::lerp((float)m_pMetadata->Extensions[lower_index].Level2.trim_saturation_gain, 2048.0f, weight);
        }
        // SCENARIO C: Display is DIMMER than all targets (Clamp to the lowest available target)
        else if (lower_index == -1 && upper_index != -1) {
            t_slope = m_pMetadata->Extensions[upper_index].Level2.trim_slope;
            t_offset = m_pMetadata->Extensions[upper_index].Level2.trim_offset;
            t_power = m_pMetadata->Extensions[upper_index].Level2.trim_power;
            t_chroma = m_pMetadata->Extensions[upper_index].Level2.trim_chroma_weight;
            t_sat = m_pMetadata->Extensions[upper_index].Level2.trim_saturation_gain;
        }

        // Final normalization to floating point coefficients
        result.trimSlope = (t_slope / 4096.0f) + 0.5f;
        result.trimOffset = (t_offset / 4096.0f) - 0.5f;
        result.trimPower = (t_power / 4096.0f) + 0.5f;
        result.trimChromaWeight = (t_chroma / 4096.0f) - 0.5f;
        result.trimSaturationGain = (t_sat / 4096.0f) - 0.5f;
    }
    return result;
}