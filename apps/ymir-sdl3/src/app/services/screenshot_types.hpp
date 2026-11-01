#pragma once

#include <app/settings.hpp>

#include <chrono>
#include <filesystem>
#include <vector>

namespace app::screenshot {

/// @brief Framebuffer screenshot data pending rotation/scaling and writing to disk.
struct Screenshot {
    std::vector<uint32> fb;
    uint32 fbWidth, fbHeight;
    uint32 fbScaleX, fbScaleY;
    int ssScale;
    Settings::Video::DisplayRotation rotation;
    std::chrono::system_clock::time_point timestamp;

    /// If not empty, this is not a screenshot but the thumbnail of a save state, written to this file as a small JPEG.
    std::filesystem::path thumbnailPath{};
};

} // namespace app::screenshot
