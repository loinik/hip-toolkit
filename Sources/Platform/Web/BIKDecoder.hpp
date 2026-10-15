#pragma once

#include <cstdint>
#include <functional>
#include <string>
#include <vector>

namespace HIPWeb {

enum class BIKImageFormat { PNG, JPEG };

struct BIKResult {
    int width = 0;
    int height = 0;
    bool hasAlpha = false;                    ///< CNV conversations (yuva)
    std::vector<std::vector<uint8_t>> frames; ///< encoded images, in order
};

/// Decodes a Bink video into still images: the first frame only, or every
/// frame. PNG keeps alpha; JPEG (quality 92) drops it.
BIKResult decodeBIK(const std::string& path, BIKImageFormat format, bool allFrames,
                    const std::function<void(int, int)>& progress = nullptr);

} // namespace HIPWeb
