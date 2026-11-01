#include "screenshot_service.hpp"

#include <app/shared_context.hpp>

#include <ymir/util/thread_name.hpp>

#include <stb_image_write.h>

#include <fmt/chrono.h>
#include <fmt/std.h>

#include <util/std_lib.hpp>

#include <algorithm>
#include <vector>

namespace app::services {

ScreenshotService::~ScreenshotService() {
    Stop();
}

void ScreenshotService::Start(SharedContext &context) {
    m_running = true;
    m_thread = std::thread([&] { ProcessingThread(context); });
}

void ScreenshotService::Stop() {
    m_running = false;
    m_writeEvent.Set();
    if (m_thread.joinable()) {
        m_thread.join();
    }
}

void ScreenshotService::Enqueue(screenshot::Screenshot &&ss) {
    {
        std::unique_lock lock{m_queueMtx};
        m_queue.emplace(std::move(ss));
    }
    m_writeEvent.Set();
}

bool ScreenshotService::WriteThumbnail(const screenshot::Screenshot &ss) {
    if (ss.thumbnailPath.empty() || ss.fbWidth == 0 || ss.fbHeight == 0 ||
        ss.fb.size() < size_t(ss.fbWidth) * ss.fbHeight) {
        return false;
    }

    // The picture as it is shown (the pixels of some modes are wider or taller than others), shrunk to fit this size
    static constexpr uint32 kMaxWidth = 192;
    const uint32 shownWidth = ss.fbWidth * std::max<uint32>(ss.fbScaleX, 1);
    const uint32 shownHeight = ss.fbHeight * std::max<uint32>(ss.fbScaleY, 1);
    const uint32 width = std::min(shownWidth, kMaxWidth);
    const uint32 height = std::max<uint32>(1, (uint64(width) * shownHeight) / shownWidth);

    // Average the source pixels that fall on every thumbnail pixel
    std::vector<uint8> rgb(size_t(width) * height * 3);
    for (uint32 y = 0; y < height; ++y) {
        const uint32 y0 = (uint64(y) * ss.fbHeight) / height;
        const uint32 y1 = std::max(y0 + 1, uint32((uint64(y + 1) * ss.fbHeight) / height));
        for (uint32 x = 0; x < width; ++x) {
            const uint32 x0 = (uint64(x) * ss.fbWidth) / width;
            const uint32 x1 = std::max(x0 + 1, uint32((uint64(x + 1) * ss.fbWidth) / width));
            uint32 r = 0, g = 0, b = 0, count = 0;
            for (uint32 sy = y0; sy < y1 && sy < ss.fbHeight; ++sy) {
                for (uint32 sx = x0; sx < x1 && sx < ss.fbWidth; ++sx) {
                    const uint32 pixel = ss.fb[size_t(sy) * ss.fbWidth + sx];
                    r += pixel & 0xFF;
                    g += (pixel >> 8) & 0xFF;
                    b += (pixel >> 16) & 0xFF;
                    ++count;
                }
            }
            count = std::max<uint32>(count, 1);
            uint8 *out = &rgb[(size_t(y) * width + x) * 3];
            out[0] = static_cast<uint8>(r / count);
            out[1] = static_cast<uint8>(g / count);
            out[2] = static_cast<uint8>(b / count);
        }
    }

    std::error_code error{};
    std::filesystem::create_directories(ss.thumbnailPath.parent_path(), error);
    return stbi_write_jpg(fmt::format("{}", ss.thumbnailPath).c_str(), width, height, 3, rgb.data(), 80) != 0;
}

void ScreenshotService::ProcessingThread(SharedContext &context) {
    util::SetCurrentThreadName("Screenshot processing thread");

    while (m_running) {
        m_writeEvent.Wait();
        m_writeEvent.Reset();
        if (!m_running) {
            break;
        }

        screenshot::Screenshot ss{};
        while (true) {
            {
                std::unique_lock lock{m_queueMtx};
                if (m_queue.empty()) {
                    break;
                }
                std::swap(ss, m_queue.front());
                m_queue.pop();
            }

            if (!ss.thumbnailPath.empty()) {
                WriteThumbnail(ss);
                continue;
            }

            auto localNow = util::to_local_time(ss.timestamp);
            auto fracTime =
                std::chrono::duration_cast<std::chrono::milliseconds>(ss.timestamp.time_since_epoch()).count() % 1000;
            // ISO 8601 + milliseconds
            auto screenshotPath = context.profile.GetPath(ProfilePath::Screenshots) /
                                  fmt::format("{}-{:%Y%m%d}T{:%H%M%S}.{:03d}.png", context.GetGameFileName(), localNow,
                                              localNow, fracTime);

            const int ssScale = ss.ssScale;
            uint32 ssScaleX = ssScale * ss.fbScaleX;
            uint32 ssScaleY = ssScale * ss.fbScaleY;
            uint32 ssWidth = ss.fbWidth * ssScaleX;
            uint32 ssHeight = ss.fbHeight * ssScaleY;

            // Rotate based on display rotation setting
            std::vector<uint32> rotatedFB{};
            using Rot = Settings::Video::DisplayRotation;
            if (ss.rotation != Rot::Normal) {
                rotatedFB.resize(ss.fbWidth * ss.fbHeight);
            }
            if (ss.rotation == Rot::_90CW || ss.rotation == Rot::_90CCW) {
                std::swap(ssWidth, ssHeight);
                std::swap(ssScaleX, ssScaleY);
                std::swap(ss.fbWidth, ss.fbHeight);
            }
            switch (ss.rotation) {
            case Rot::Normal: break;
            case Rot::_90CW:
                for (uint32 y = 0; y < ss.fbHeight; ++y) {
                    for (uint32 x = 0; x < ss.fbWidth; ++x) {
                        rotatedFB[x + y * ss.fbWidth] = ss.fb[y + (ss.fbWidth - 1 - x) * ss.fbHeight];
                    }
                }
                break;
            case Rot::_180:
                for (uint32 y = 0; y < ss.fbHeight; ++y) {
                    for (uint32 x = 0; x < ss.fbWidth; ++x) {
                        rotatedFB[x + y * ss.fbWidth] =
                            ss.fb[(ss.fbWidth - 1 - x) + (ss.fbHeight - 1 - y) * ss.fbWidth];
                    }
                }
                break;
            case Rot::_90CCW:
                for (uint32 y = 0; y < ss.fbHeight; ++y) {
                    for (uint32 x = 0; x < ss.fbWidth; ++x) {
                        rotatedFB[x + y * ss.fbWidth] = ss.fb[(ss.fbHeight - 1 - y) + x * ss.fbHeight];
                    }
                }
                break;
            }
            if (ss.rotation != Rot::Normal) {
                ss.fb.swap(rotatedFB);
            }

            // Scale up with nearest neighbor interpolation
            std::vector<uint32> scaledFB{};
            scaledFB.resize(ssWidth * ssHeight);
            auto &srcFB = ss.fb;
            for (uint32 y = 0; y < ss.fbHeight; ++y) {
                uint32 *line = &scaledFB[(y * ssScaleY) * ssWidth];
                if (ssScaleX == 1) {
                    std::copy_n(&srcFB[y * ss.fbWidth], ss.fbWidth, line);
                } else {
                    for (uint32 x = 0; x < ss.fbWidth; ++x) {
                        std::fill_n(&line[x * ssScaleX], ssScaleX, srcFB[y * ss.fbWidth + x]);
                    }
                }
                for (uint32 py = 1; py < ssScaleY; ++py) {
                    std::copy_n(line, ssWidth, &line[py * ssWidth]);
                }
            }

            stbi_write_png(fmt::format("{}", screenshotPath).c_str(), ssWidth, ssHeight, 4, scaledFB.data(),
                           ssWidth * sizeof(uint32));

            context.DisplayMessage(fmt::format("Screenshot saved to {}", screenshotPath));
        }
    }
}

} // namespace app::services
