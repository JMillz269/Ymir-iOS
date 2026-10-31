#pragma once

/**
@file
@brief Converts disc images (CUE/BIN, ISO, CCD, MDS) to MAME CHD files, which are smaller and read by the emulator
(and other emulators and tools that use libchdr or MAME's code).
*/

#include <ymir/core/types.hpp>

#include <ymir/media/disc.hpp>

#include <cstdint>
#include <filesystem>
#include <functional>
#include <string>

namespace ymir::media {

/// @brief Whether this build can write CHD files (it needs a deflate compressor).
bool IsCHDConversionAvailable();

struct CHDConvertOptions {
    /// Deflate compression level, 1 (fastest) to 9 (smallest).
    int compressionLevel = 9;

    /// Number of threads to compress with. 0 picks a number from the CPU (at most 4).
    uint32 threads = 0;

    /// Read the new file back, checking every hunk and the checksums, before reporting success.
    bool verify = true;
};

enum class CHDConvertStatus {
    Ok,
    Cancelled,    ///< The progress callback asked to stop
    Unavailable,  ///< This build can't write CHD files
    NotSupported, ///< The disc has a layout CHD files can't hold (several sessions, gaps between tracks...)
    LoadFailed,   ///< The source image could not be loaded
    ReadFailed,   ///< Reading the source image failed (the image is truncated?)
    WriteFailed,  ///< Writing the CHD file failed (the storage is full?)
    VerifyFailed, ///< The CHD file was written but reading it back gave something else
};

struct CHDConvertResult {
    CHDConvertStatus status = CHDConvertStatus::Ok;
    std::string message; ///< what went wrong, for the user

    uint64 hunks = 0;       ///< number of hunks the file has
    uint64 outputBytes = 0; ///< size of the CHD file
    uint64 rawBytes = 0;    ///< size of the disc data before compression

    [[nodiscard]] bool Succeeded() const {
        return status == CHDConvertStatus::Ok;
    }
};

/// @brief Progress callback: `done` of `total` steps are finished. Return `false` to cancel.
/// The steps are the hunks of the CHD file, followed by the same number of steps for verifying it when that is on.
using CHDProgressCallback = std::function<bool(uint64 done, uint64 total)>;

/// @brief Converts a loaded disc to a CHD file. The file is removed again if the conversion fails or is cancelled.
/// The CHD file holds the raw sectors of the tracks and the layout of the disc (pregaps, track types); the subchannel
/// data is not carried over (the emulator doesn't use it).
CHDConvertResult ConvertDiscToCHD(const Disc &disc, const std::filesystem::path &output,
                                  const CHDConvertOptions &options = {}, const CHDProgressCallback &progress = {});

/// @brief Loads a disc image of any supported format and converts it to a CHD file.
CHDConvertResult ConvertImageToCHD(const std::filesystem::path &source, const std::filesystem::path &output,
                                   const CHDConvertOptions &options = {}, const CHDProgressCallback &progress = {});

/// @brief Checks a CHD file: reads every hunk (which checks their CRCs and the map's) and compares the checksum of the
/// data and the overall checksum with the ones in the header.
CHDConvertResult VerifyCHD(const std::filesystem::path &path, const CHDProgressCallback &progress = {});

} // namespace ymir::media
