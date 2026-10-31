#include <ymir/media/chd_convert.hpp>

#include <ymir/media/loader/loader.hpp>

extern "C" {
#include <libchdr/cdrom.h>
}
#include <libchdr/chd.h>

#if Ymir_HAS_ZLIB
    #include <zlib.h>
#endif

#include <algorithm>
#include <array>
#include <atomic>
#include <cstdio>
#include <cstring>
#include <fstream>
#include <memory>
#include <string>
#include <thread>
#include <vector>

namespace ymir::media {

bool IsCHDConversionAvailable() {
#if Ymir_HAS_ZLIB
    return true;
#else
    return false;
#endif
}

#if Ymir_HAS_ZLIB

namespace {

// -------------------------------------------------------------------------------------------------------------------
// CHD constants

constexpr uint32 kSectorBytes = CD_MAX_SECTOR_DATA;  // 2352
constexpr uint32 kSubcodeBytes = CD_MAX_SUBCODE_DATA; // 96
constexpr uint32 kFrameBytes = CD_FRAME_SIZE;         // 2448
constexpr uint32 kFramesPerHunk = CD_FRAMES_PER_HUNK; // 8
constexpr uint32 kHunkBytes = kFrameBytes * kFramesPerHunk;
constexpr uint32 kTrackPadding = CD_TRACK_PADDING;
constexpr uint32 kHeaderBytes = CHD_V5_HEADER_SIZE;
constexpr uint32 kMapHeaderBytes = 16;
constexpr uint32 kMetadataHeaderBytes = 16;

// Bits of a compressed map entry in this writer: every hunk has a 4-bit type, the compressed ones a 16-bit length, and
// all of them a 16-bit CRC
constexpr uint32 kLengthBits = 16;
constexpr uint32 kCompressionTypeCodec0 = 0; // the first codec of the header
constexpr uint32 kCompressionTypeNone = 4;   // stored as it is

constexpr uint8 kSyncHeader[12] = {0x00, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x00};

// -------------------------------------------------------------------------------------------------------------------
// Utilities

void PutBE16(uint8 *p, uint32 v) {
    p[0] = static_cast<uint8>(v >> 8);
    p[1] = static_cast<uint8>(v);
}

void PutBE24(uint8 *p, uint32 v) {
    p[0] = static_cast<uint8>(v >> 16);
    p[1] = static_cast<uint8>(v >> 8);
    p[2] = static_cast<uint8>(v);
}

void PutBE32(uint8 *p, uint32 v) {
    p[0] = static_cast<uint8>(v >> 24);
    p[1] = static_cast<uint8>(v >> 16);
    p[2] = static_cast<uint8>(v >> 8);
    p[3] = static_cast<uint8>(v);
}

void PutBE48(uint8 *p, uint64 v) {
    p[0] = static_cast<uint8>(v >> 40);
    p[1] = static_cast<uint8>(v >> 32);
    p[2] = static_cast<uint8>(v >> 24);
    p[3] = static_cast<uint8>(v >> 16);
    p[4] = static_cast<uint8>(v >> 8);
    p[5] = static_cast<uint8>(v);
}

void PutBE64(uint8 *p, uint64 v) {
    PutBE32(p, static_cast<uint32>(v >> 32));
    PutBE32(p + 4, static_cast<uint32>(v));
}

/// CRC-16/CCITT (polynomial 0x1021, initial value 0xFFFF), as CHD files use it
uint16 CRC16(const uint8 *data, size_t length) {
    static const std::array<uint16, 256> table = [] {
        std::array<uint16, 256> t{};
        for (uint32 i = 0; i < 256; i++) {
            uint32 crc = i << 8;
            for (int bit = 0; bit < 8; bit++) {
                crc = (crc & 0x8000) ? ((crc << 1) ^ 0x1021) : (crc << 1);
            }
            t[i] = static_cast<uint16>(crc);
        }
        return t;
    }();
    uint16 crc = 0xFFFF;
    for (size_t i = 0; i < length; i++) {
        crc = static_cast<uint16>((crc << 8) ^ table[(crc >> 8) ^ data[i]]);
    }
    return crc;
}

/// SHA-1, for the checksums in the header
class SHA1 {
public:
    using Digest = std::array<uint8, 20>;

    SHA1() {
        Reset();
    }

    void Reset() {
        m_state = {0x67452301, 0xEFCDAB89, 0x98BADCFE, 0x10325476, 0xC3D2E1F0};
        m_length = 0;
        m_buffered = 0;
    }

    void Append(const uint8 *data, size_t size) {
        m_length += size;
        while (size > 0) {
            const size_t take = std::min<size_t>(size, 64 - m_buffered);
            std::memcpy(&m_buffer[m_buffered], data, take);
            m_buffered += take;
            data += take;
            size -= take;
            if (m_buffered == 64) {
                Block(m_buffer.data());
                m_buffered = 0;
            }
        }
    }

    Digest Finish() {
        const uint64 bits = m_length * 8;
        const uint8 one = 0x80;
        Append(&one, 1);
        const uint8 zero = 0;
        while (m_buffered != 56) {
            Append(&zero, 1);
        }
        std::array<uint8, 8> lengthBytes{};
        PutBE64(lengthBytes.data(), bits);
        Append(lengthBytes.data(), 8);

        Digest digest{};
        for (size_t i = 0; i < 5; i++) {
            PutBE32(&digest[i * 4], m_state[i]);
        }
        return digest;
    }

private:
    static uint32 Rotl(uint32 value, int bits) {
        return (value << bits) | (value >> (32 - bits));
    }

    void Block(const uint8 *block) {
        std::array<uint32, 80> w{};
        for (size_t i = 0; i < 16; i++) {
            w[i] = (uint32(block[i * 4]) << 24) | (uint32(block[i * 4 + 1]) << 16) | (uint32(block[i * 4 + 2]) << 8) |
                   uint32(block[i * 4 + 3]);
        }
        for (size_t i = 16; i < 80; i++) {
            w[i] = Rotl(w[i - 3] ^ w[i - 8] ^ w[i - 14] ^ w[i - 16], 1);
        }
        uint32 a = m_state[0], b = m_state[1], c = m_state[2], d = m_state[3], e = m_state[4];
        for (size_t i = 0; i < 80; i++) {
            uint32 f, k;
            if (i < 20) {
                f = (b & c) | (~b & d);
                k = 0x5A827999;
            } else if (i < 40) {
                f = b ^ c ^ d;
                k = 0x6ED9EBA1;
            } else if (i < 60) {
                f = (b & c) | (b & d) | (c & d);
                k = 0x8F1BBCDC;
            } else {
                f = b ^ c ^ d;
                k = 0xCA62C1D6;
            }
            const uint32 temp = Rotl(a, 5) + f + e + k + w[i];
            e = d;
            d = c;
            c = Rotl(b, 30);
            b = a;
            a = temp;
        }
        m_state[0] += a;
        m_state[1] += b;
        m_state[2] += c;
        m_state[3] += d;
        m_state[4] += e;
    }

    std::array<uint32, 5> m_state{};
    std::array<uint8, 64> m_buffer{};
    size_t m_buffered = 0;
    uint64 m_length = 0;
};

/// Writes bits, most significant first, as the CHD map is packed
class BitWriter {
public:
    void Write(uint32 value, uint32 bits) {
        for (uint32 i = bits; i-- > 0;) {
            m_current = static_cast<uint8>((m_current << 1) | ((value >> i) & 1));
            if (++m_bits == 8) {
                m_bytes.push_back(m_current);
                m_current = 0;
                m_bits = 0;
            }
        }
    }

    /// Fills the rest of the last byte with zero bits and returns the bytes
    std::vector<uint8> Finish() {
        if (m_bits != 0) {
            Write(0, 8 - m_bits);
        }
        return std::move(m_bytes);
    }

private:
    std::vector<uint8> m_bytes;
    uint8 m_current = 0;
    uint32 m_bits = 0;
};

// -------------------------------------------------------------------------------------------------------------------
// Hunk compression ("cdzl": the sector data and the subchannel data each deflated, the ECC of the data sectors left out)

/// Deflates a block into a raw deflate stream (no zlib header)
bool Deflate(const uint8 *data, size_t size, int level, std::vector<uint8> &out) {
    z_stream stream{};
    if (deflateInit2(&stream, level, Z_DEFLATED, -15, 9, Z_DEFAULT_STRATEGY) != Z_OK) {
        return false;
    }
    out.resize(deflateBound(&stream, static_cast<uLong>(size)));
    stream.next_in = const_cast<Bytef *>(data);
    stream.avail_in = static_cast<uInt>(size);
    stream.next_out = out.data();
    stream.avail_out = static_cast<uInt>(out.size());
    const int result = deflate(&stream, Z_FINISH);
    const bool ok = result == Z_STREAM_END;
    out.resize(stream.total_out);
    deflateEnd(&stream);
    return ok;
}

struct HunkResult {
    bool stored = false; ///< not compressed
    uint16 crc = 0;      ///< CRC-16 of the whole (uncompressed) hunk
    std::vector<uint8> data;
};

/// Compresses a hunk of 8 frames of 2448 bytes (2352 of sector data followed by 96 of subchannel data).
/// If the result isn't smaller than the hunk, the hunk is stored as it is.
bool CompressHunk(const uint8 *hunk, int level, HunkResult &result) {
    constexpr uint32 frames = kFramesPerHunk;
    constexpr uint32 eccBytes = (frames + 7) / 8;
    constexpr uint32 complenBytes = 2; // (the hunk is smaller than 64 KiB)
    constexpr uint32 headerBytes = eccBytes + complenBytes;

    result.crc = CRC16(hunk, kHunkBytes);

    // Split the frames into the sector data and the subchannel data. Where a data sector's error correction codes can
    // be generated again from the rest of the sector (the usual case), they are left out: they take space and don't
    // compress.
    std::array<uint8, frames * kSectorBytes> sectors;
    std::array<uint8, frames * kSubcodeBytes> subcode;
    std::array<uint8, eccBytes> eccBitmap{};
    for (uint32 frame = 0; frame < frames; frame++) {
        uint8 *sector = &sectors[frame * kSectorBytes];
        std::memcpy(sector, &hunk[frame * kFrameBytes], kSectorBytes);
        std::memcpy(&subcode[frame * kSubcodeBytes], &hunk[frame * kFrameBytes + kSectorBytes], kSubcodeBytes);

        if (std::memcmp(sector, kSyncHeader, sizeof(kSyncHeader)) == 0 && ecc_verify(sector)) {
            std::array<uint8, kSectorBytes> stripped;
            std::memcpy(stripped.data(), sector, kSectorBytes);
            std::memset(stripped.data(), 0, sizeof(kSyncHeader));
            ecc_clear(stripped.data());

            // Make sure the reader gets exactly the sector back
            std::array<uint8, kSectorBytes> rebuilt = stripped;
            std::memcpy(rebuilt.data(), kSyncHeader, sizeof(kSyncHeader));
            ecc_generate(rebuilt.data());
            if (std::memcmp(rebuilt.data(), sector, kSectorBytes) == 0) {
                eccBitmap[frame / 8] |= static_cast<uint8>(1u << (frame % 8));
                std::memcpy(sector, stripped.data(), kSectorBytes);
            }
        }
    }

    std::vector<uint8> base, sub;
    if (!Deflate(sectors.data(), sectors.size(), level, base) || !Deflate(subcode.data(), subcode.size(), level, sub)) {
        return false;
    }

    const size_t total = headerBytes + base.size() + sub.size();
    if (total >= kHunkBytes || base.size() > 0xFFFF) {
        result.stored = true;
        result.data.assign(hunk, hunk + kHunkBytes);
        return true;
    }

    result.stored = false;
    result.data.resize(total);
    std::memcpy(result.data.data(), eccBitmap.data(), eccBytes);
    PutBE16(&result.data[eccBytes], static_cast<uint32>(base.size()));
    std::memcpy(&result.data[headerBytes], base.data(), base.size());
    std::memcpy(&result.data[headerBytes + base.size()], sub.data(), sub.size());
    return true;
}

// -------------------------------------------------------------------------------------------------------------------
// Layout of the disc

struct TrackPlan {
    const Track *track = nullptr;
    uint32 number = 0; // 1-based
    std::string type;  // CHD track type
    uint32 readBytes = 0;
    uint32 frames = 0; // in the file, the pregap included
    uint32 pregap = 0;
    bool swapAudio = false; // samples are little endian in the source; CHD files hold audio in big endian
};

/// The CHD track type for a track of the loaded disc, or an empty string if there is none
std::string TrackTypeName(const Track &track) {
    if (track.controlADR == 0x01) {
        return track.sectorSize == 2352 ? "AUDIO" : "";
    }
    if (!track.mode2) {
        switch (track.sectorSize) {
        case 2048: return "MODE1";
        case 2352: return "MODE1_RAW";
        default: return "";
        }
    }
    switch (track.sectorSize) {
    case 2048: return "MODE2_FORM1";
    case 2324: return "MODE2_FORM2";
    case 2336: return "MODE2";
    case 2352: return "MODE2_RAW";
    default: return "";
    }
}

/// Produces the frames of the CHD file in order: the tracks one after the other, each padded to a multiple of 4 frames
class FrameSource {
public:
    explicit FrameSource(const std::vector<TrackPlan> &plans)
        : m_plans(plans) {}

    /// Fills the next frame (2448 bytes). Returns false if reading the source failed; `error` says where.
    bool Next(uint8 *frame, std::string &error) {
        std::memset(frame, 0, kFrameBytes);
        while (m_plan < m_plans.size() && m_frame >= PaddedFrames(m_plans[m_plan])) {
            ++m_plan;
            m_frame = 0;
        }
        if (m_plan >= m_plans.size()) {
            return true; // (the end of the last hunk: zeros)
        }
        const TrackPlan &plan = m_plans[m_plan];
        const uint32 current = m_frame++;
        if (current >= plan.frames) {
            return true; // padding
        }

        const Track &track = *plan.track;
        const uintmax_t offset = static_cast<uintmax_t>(current) * track.unitSize;
        if (offset >= track.binaryReader->Size()) {
            // The track has more frames than the image has data for (the loaders of some formats count a frame or a gap
            // at the end that isn't in the file): the emulator can't read those sectors either, they become zeros
            return true;
        }
        const uintmax_t got = track.binaryReader->Read(offset, plan.readBytes, std::span<uint8>{frame, plan.readBytes});
        if (got != plan.readBytes) {
            error = "The disc image ended early (track " + std::to_string(plan.number) + ", frame " +
                    std::to_string(current) + ").";
            return false;
        }
        if (plan.swapAudio) {
            for (uint32 i = 0; i + 1 < plan.readBytes; i += 2) {
                std::swap(frame[i], frame[i + 1]);
            }
        }
        return true;
    }

    static uint32 PaddedFrames(const TrackPlan &plan) {
        return (plan.frames + kTrackPadding - 1) / kTrackPadding * kTrackPadding;
    }

private:
    const std::vector<TrackPlan> &m_plans;
    size_t m_plan = 0;
    uint32 m_frame = 0;
};

CHDConvertResult Fail(CHDConvertStatus status, std::string message) {
    CHDConvertResult result;
    result.status = status;
    result.message = std::move(message);
    return result;
}

uint32 BitsFor(uint64 value) {
    uint32 bits = 0;
    while (value > 0) {
        ++bits;
        value >>= 1;
    }
    return bits;
}

} // namespace

CHDConvertResult ConvertDiscToCHD(const Disc &disc, const std::filesystem::path &output,
                                  const CHDConvertOptions &options, const CHDProgressCallback &progress) {
    // ---------------------------------------------------------------------------------------------------------------
    // Work out the layout

    if (disc.sessions.empty()) {
        return Fail(CHDConvertStatus::NotSupported, "The disc image has no tracks.");
    }
    if (disc.sessions.size() > 1) {
        return Fail(CHDConvertStatus::NotSupported, "Discs with more than one session can't be stored as CHD files.");
    }
    const Session &session = disc.sessions.front();

    std::vector<TrackPlan> plans;
    uint32 nextFAD = 150;
    for (uint32 i = session.firstTrackIndex; i <= session.lastTrackIndex && i < session.tracks.size(); i++) {
        const Track &track = session.tracks[i];
        if (track.controlADR == 0x00 || track.binaryReader == nullptr) {
            continue;
        }
        TrackPlan plan;
        plan.track = &track;
        plan.number = i + 1;
        plan.type = TrackTypeName(track);
        if (plan.type.empty()) {
            return Fail(CHDConvertStatus::NotSupported,
                        "Track " + std::to_string(plan.number) + " has a sector format that can't be stored.");
        }
        if (track.startFrameAddress != nextFAD || track.endFrameAddress < track.startFrameAddress ||
            track.index01FrameAddress < track.startFrameAddress || track.index01FrameAddress > track.endFrameAddress ||
            track.unitSize == 0) {
            return Fail(CHDConvertStatus::NotSupported,
                        "Track " + std::to_string(plan.number) + " isn't laid out in a way CHD files can hold.");
        }
        plan.readBytes = std::min<uint32>(track.sectorSize, kSectorBytes);
        plan.frames = track.endFrameAddress - track.startFrameAddress + 1;
        plan.pregap = track.index01FrameAddress - track.startFrameAddress;
        plan.swapAudio = track.controlADR == 0x01 && !track.bigEndian;
        nextFAD = track.endFrameAddress + 1;
        plans.push_back(std::move(plan));
    }
    if (plans.empty()) {
        return Fail(CHDConvertStatus::NotSupported, "The disc image has no tracks.");
    }

    uint64 totalFrames = 0;
    for (const TrackPlan &plan : plans) {
        totalFrames += FrameSource::PaddedFrames(plan);
    }
    const uint64 hunkCount = (totalFrames + kFramesPerHunk - 1) / kFramesPerHunk;
    const uint64 logicalBytes = totalFrames * kFrameBytes;

    // The map goes right after the header. It's packed as: the 16 codes of a Huffman code that gives all of them 4 bits,
    // the 4-bit type of every hunk, then the length and CRC of every hunk. Its size depends on how many hunks end up
    // stored as they are (no length), so room is made for the most it can take, which is at most a few bytes more than it
    // needs: the hunks follow the map at an offset the map itself gives.
    const uint64 mapBitsMax = 16 * 4 + hunkCount * (4 + kLengthBits + 16);
    const uint32 mapBytes = static_cast<uint32>((mapBitsMax + 7) / 8) + 4;
    const uint64 firstHunkOffset = kHeaderBytes + kMapHeaderBytes + mapBytes;

    // ---------------------------------------------------------------------------------------------------------------
    // Write the hunks

    std::error_code fsError;
    std::filesystem::remove(output, fsError);
    std::fstream file(output, std::ios::binary | std::ios::in | std::ios::out | std::ios::trunc);
    if (!file.is_open()) {
        return Fail(CHDConvertStatus::WriteFailed, "The CHD file couldn't be created.");
    }
    bool keepFile = false;
    auto cleanUp = [&] {
        if (file.is_open()) {
            file.close();
        }
        if (!keepFile) {
            std::filesystem::remove(output, fsError);
        }
    };
    auto fail = [&](CHDConvertStatus status, std::string message) {
        cleanUp();
        return Fail(status, std::move(message));
    };
    auto seekTo = [&](uint64 offset) {
        file.clear();
        file.seekp(static_cast<std::streamoff>(offset));
        return file.good();
    };
    auto writeBytes = [&](const void *data, size_t size) {
        file.write(static_cast<const char *>(data), static_cast<std::streamsize>(size));
        return file.good();
    };

    if (!seekTo(firstHunkOffset)) {
        return fail(CHDConvertStatus::WriteFailed, "The CHD file couldn't be written.");
    }

    struct HunkInfo {
        bool stored = false;
        uint32 length = 0;
        uint16 crc = 0;
    };
    std::vector<HunkInfo> hunkInfo;
    hunkInfo.reserve(hunkCount);

    SHA1 rawSHA1;
    FrameSource source{plans};

    const uint32 hardware = std::max(1u, std::thread::hardware_concurrency());
    const uint32 threads = options.threads != 0 ? options.threads : std::min(hardware, 4u);
    const uint32 batchHunks = std::max(8u, threads * 8);
    const int level = std::clamp(options.compressionLevel, 1, 9);

    std::array<std::vector<uint8>, 2> batchData;
    std::array<uint32, 2> batchCount{};
    std::vector<HunkResult> results;
    std::string error;
    uint64 hunksRead = 0;

    // Reads the next batch of hunks from the disc into buffer `slot`
    auto readBatch = [&](uint32 slot) -> bool {
        const uint64 count = std::min<uint64>(batchHunks, hunkCount - hunksRead);
        batchData[slot].assign(count * kHunkBytes, 0);
        for (uint64 h = 0; h < count; h++) {
            for (uint32 f = 0; f < kFramesPerHunk; f++) {
                if (!source.Next(&batchData[slot][h * kHunkBytes + f * kFrameBytes], error)) {
                    return false;
                }
            }
        }
        batchCount[slot] = static_cast<uint32>(count);
        hunksRead += count;
        return true;
    };

    const uint64 stepsTotal = options.verify ? hunkCount * 2 : hunkCount;
    uint64 hunksWritten = 0;
    uint32 current = 0;
    if (!readBatch(current)) {
        return fail(CHDConvertStatus::ReadFailed, error);
    }

    std::atomic<bool> compressionFailed{false};
    while (batchCount[current] > 0) {
        const uint32 count = batchCount[current];
        results.assign(count, HunkResult{});

        // Compress the batch on several threads while the next one is read
        std::atomic<uint32> nextHunk{0};
        auto worker = [&] {
            for (;;) {
                const uint32 h = nextHunk.fetch_add(1);
                if (h >= count) {
                    return;
                }
                if (!CompressHunk(&batchData[current][static_cast<size_t>(h) * kHunkBytes], level, results[h])) {
                    compressionFailed = true;
                }
            }
        };
        std::vector<std::thread> pool;
        for (uint32 t = 0; t < threads; t++) {
            pool.emplace_back(worker);
        }

        const uint32 other = current ^ 1;
        batchCount[other] = 0;
        bool readOk = true;
        if (hunksRead < hunkCount) {
            readOk = readBatch(other);
        }
        for (std::thread &thread : pool) {
            thread.join();
        }
        if (!readOk) {
            return fail(CHDConvertStatus::ReadFailed, error);
        }
        if (compressionFailed) {
            return fail(CHDConvertStatus::WriteFailed, "Compressing the disc data failed.");
        }

        // Write the batch, in order
        for (uint32 h = 0; h < count; h++) {
            const HunkResult &hunk = results[h];
            const uint64 rawOffset = static_cast<uint64>(h) * kHunkBytes;
            const uint64 rawSize = std::min<uint64>(kHunkBytes, logicalBytes - hunksWritten * kHunkBytes);
            rawSHA1.Append(&batchData[current][rawOffset], rawSize);

            if (!writeBytes(hunk.data.data(), hunk.data.size())) {
                return fail(CHDConvertStatus::WriteFailed, "The CHD file couldn't be written (is the storage full?).");
            }
            hunkInfo.push_back({hunk.stored, static_cast<uint32>(hunk.data.size()), hunk.crc});
            ++hunksWritten;
        }

        if (progress && !progress(hunksWritten, stepsTotal)) {
            return fail(CHDConvertStatus::Cancelled, "Cancelled.");
        }
        current = other;
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Metadata: the tracks

    struct MetadataEntry {
        std::vector<uint8> data;
        uint64 offset = 0;
    };
    std::vector<MetadataEntry> metadata;
    for (const TrackPlan &plan : plans) {
        // (a pregap that is in the file is marked by a "V" in front of the type of the pregap)
        char text[256];
        const std::string pregapType = plan.pregap > 0 ? "V" + plan.type : plan.type;
        const int length = std::snprintf(
            text, sizeof(text), "TRACK:%u TYPE:%s SUBTYPE:NONE FRAMES:%u PREGAP:%u PGTYPE:%s PGSUB:NONE POSTGAP:0",
            plan.number, plan.type.c_str(), plan.frames, plan.pregap, pregapType.c_str());
        MetadataEntry entry;
        entry.data.assign(text, text + length + 1); // (with the terminating 0, as other tools write it)
        metadata.push_back(std::move(entry));
    }

    const uint64 metadataStart = firstHunkOffset + [&] {
        uint64 size = 0;
        for (const HunkInfo &info : hunkInfo) {
            size += info.length;
        }
        return size;
    }();
    uint64 metadataOffset = metadataStart;
    for (MetadataEntry &entry : metadata) {
        entry.offset = metadataOffset;
        metadataOffset += kMetadataHeaderBytes + entry.data.size();
    }

    if (!seekTo(metadataStart)) {
        return fail(CHDConvertStatus::WriteFailed, "The CHD file couldn't be written.");
    }
    for (size_t i = 0; i < metadata.size(); i++) {
        const MetadataEntry &entry = metadata[i];
        uint8 header[kMetadataHeaderBytes]{};
        std::memcpy(header, "CHT2", 4);
        header[4] = CHD_MDFLAGS_CHECKSUM;
        PutBE24(&header[5], static_cast<uint32>(entry.data.size()));
        PutBE64(&header[8], i + 1 < metadata.size() ? metadata[i + 1].offset : 0);
        if (!writeBytes(header, sizeof(header)) || !writeBytes(entry.data.data(), entry.data.size())) {
            return fail(CHDConvertStatus::WriteFailed, "The CHD file couldn't be written (is the storage full?).");
        }
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Map

    const SHA1::Digest rawDigest = rawSHA1.Finish();

    // The overall checksum covers the checksum of the data and, sorted, the tag and checksum of each piece of metadata
    SHA1::Digest overallDigest;
    {
        std::vector<std::array<uint8, 24>> metadataHashes;
        for (const MetadataEntry &entry : metadata) {
            SHA1 hash;
            hash.Append(entry.data.data(), entry.data.size());
            const SHA1::Digest digest = hash.Finish();
            std::array<uint8, 24> item{};
            std::memcpy(item.data(), "CHT2", 4);
            std::memcpy(item.data() + 4, digest.data(), 20);
            metadataHashes.push_back(item);
        }
        std::sort(metadataHashes.begin(), metadataHashes.end());
        SHA1 overall;
        overall.Append(rawDigest.data(), rawDigest.size());
        for (const auto &item : metadataHashes) {
            overall.Append(item.data(), item.size());
        }
        overallDigest = overall.Finish();
    }

    // The map as the reader sees it, for its CRC: per hunk 12 bytes of type, length, offset and CRC
    std::vector<uint8> rawMap(hunkCount * 12);
    {
        uint64 offset = firstHunkOffset;
        for (uint64 h = 0; h < hunkCount; h++) {
            const HunkInfo &info = hunkInfo[h];
            uint8 *entry = &rawMap[h * 12];
            entry[0] = static_cast<uint8>(info.stored ? kCompressionTypeNone : kCompressionTypeCodec0);
            PutBE24(&entry[1], info.length);
            PutBE48(&entry[4], offset);
            PutBE16(&entry[10], info.crc);
            offset += info.length;
        }
    }

    BitWriter bits;
    for (uint32 i = 0; i < 16; i++) {
        bits.Write(4, 4); // the Huffman code: all 16 symbols have 4 bits, so symbol n has code n
    }
    for (const HunkInfo &info : hunkInfo) {
        bits.Write(info.stored ? kCompressionTypeNone : kCompressionTypeCodec0, 4);
    }
    for (const HunkInfo &info : hunkInfo) {
        if (!info.stored) {
            bits.Write(info.length, kLengthBits);
        }
        bits.Write(info.crc, 16);
    }
    std::vector<uint8> mapData = bits.Finish();
    if (mapData.size() > mapBytes) {
        return fail(CHDConvertStatus::WriteFailed, "The map of the CHD file doesn't fit its room.");
    }
    mapData.resize(mapBytes, 0);

    uint8 mapHeader[kMapHeaderBytes]{};
    PutBE32(&mapHeader[0], mapBytes);
    PutBE48(&mapHeader[4], firstHunkOffset);
    PutBE16(&mapHeader[10], CRC16(rawMap.data(), rawMap.size()));
    mapHeader[12] = kLengthBits;
    mapHeader[13] = static_cast<uint8>(BitsFor(hunkCount));
    mapHeader[14] = static_cast<uint8>(BitsFor(totalFrames));

    // ---------------------------------------------------------------------------------------------------------------
    // Header

    uint8 header[kHeaderBytes]{};
    std::memcpy(header, "MComprHD", 8);
    PutBE32(&header[8], kHeaderBytes);
    PutBE32(&header[12], 5);
    PutBE32(&header[16], CHD_CODEC_CD_ZLIB);
    PutBE64(&header[32], logicalBytes);
    PutBE64(&header[40], kHeaderBytes);
    PutBE64(&header[48], metadata.empty() ? 0 : metadata.front().offset);
    PutBE32(&header[56], kHunkBytes);
    PutBE32(&header[60], kFrameBytes);
    std::memcpy(&header[64], rawDigest.data(), 20);
    std::memcpy(&header[84], overallDigest.data(), 20);

    if (!seekTo(0) || !writeBytes(header, sizeof(header)) || !writeBytes(mapHeader, sizeof(mapHeader)) ||
        !writeBytes(mapData.data(), mapData.size())) {
        return fail(CHDConvertStatus::WriteFailed, "The CHD file couldn't be written (is the storage full?).");
    }
    file.flush();
    if (!file.good()) {
        return fail(CHDConvertStatus::WriteFailed, "The CHD file couldn't be written (is the storage full?).");
    }
    file.close();
    if (file.fail()) {
        return fail(CHDConvertStatus::WriteFailed, "The CHD file couldn't be written (is the storage full?).");
    }

    CHDConvertResult result;
    result.hunks = hunkCount;
    result.rawBytes = logicalBytes;
    result.outputBytes = metadataOffset;

    // ---------------------------------------------------------------------------------------------------------------
    // Check what was written

    if (options.verify) {
        CHDProgressCallback verifyProgress;
        if (progress) {
            verifyProgress = [&](uint64 done, uint64 total) { return progress(hunkCount + done, hunkCount + total); };
        }
        const CHDConvertResult verified = VerifyCHD(output, verifyProgress);
        if (!verified.Succeeded()) {
            keepFile = false;
            std::filesystem::remove(output, fsError);
            return verified;
        }
    }

    keepFile = true;
    return result;
}

CHDConvertResult VerifyCHD(const std::filesystem::path &path, const CHDProgressCallback &progress) {
    chd_file *chd = nullptr;
    const chd_error openError = chd_open(path.string().c_str(), CHD_OPEN_READ, nullptr, &chd);
    if (openError != CHDERR_NONE) {
        return Fail(CHDConvertStatus::VerifyFailed,
                    std::string("The CHD file couldn't be opened again: ") + chd_error_string(openError));
    }
    struct Closer {
        chd_file *file;
        ~Closer() {
            chd_close(file);
        }
    } closer{chd};

    const chd_header *header = chd_get_header(chd);
    std::vector<uint8> hunk(header->hunkbytes);
    SHA1 raw;
    uint64 remaining = header->logicalbytes;
    for (uint32 h = 0; h < header->hunkcount; h++) {
        const chd_error error = chd_read(chd, h, hunk.data());
        if (error != CHDERR_NONE) {
            return Fail(CHDConvertStatus::VerifyFailed,
                        "Hunk " + std::to_string(h) + " of the CHD file can't be read back: " + chd_error_string(error));
        }
        const uint64 size = std::min<uint64>(header->hunkbytes, remaining);
        raw.Append(hunk.data(), size);
        remaining -= size;
        if (progress && (h % 64 == 0 || h + 1 == header->hunkcount) && !progress(h + 1, header->hunkcount)) {
            return Fail(CHDConvertStatus::Cancelled, "Cancelled.");
        }
    }
    const SHA1::Digest rawDigest = raw.Finish();
    if (std::memcmp(rawDigest.data(), header->rawsha1, 20) != 0) {
        return Fail(CHDConvertStatus::VerifyFailed, "The data of the CHD file doesn't match its checksum.");
    }

    // The overall checksum: the one of the data and the checksums of the metadata
    {
        std::vector<std::array<uint8, 24>> metadataHashes;
        std::vector<char> text(1024);
        for (uint32 index = 0;; index++) {
            uint32 length = 0, tag = 0;
            uint8 flags = 0;
            const chd_error error =
                chd_get_metadata(chd, CHDMETATAG_WILDCARD, index, text.data(), static_cast<uint32>(text.size()), &length,
                                 &tag, &flags);
            if (error == CHDERR_METADATA_NOT_FOUND) {
                break;
            }
            if (error != CHDERR_NONE || length > text.size()) {
                return Fail(CHDConvertStatus::VerifyFailed, "The metadata of the CHD file can't be read back.");
            }
            if (flags & CHD_MDFLAGS_CHECKSUM) {
                SHA1 hash;
                hash.Append(reinterpret_cast<const uint8 *>(text.data()), length);
                const SHA1::Digest digest = hash.Finish();
                std::array<uint8, 24> item{};
                PutBE32(item.data(), tag);
                std::memcpy(item.data() + 4, digest.data(), 20);
                metadataHashes.push_back(item);
            }
        }
        std::sort(metadataHashes.begin(), metadataHashes.end());
        SHA1 overall;
        overall.Append(rawDigest.data(), rawDigest.size());
        for (const auto &item : metadataHashes) {
            overall.Append(item.data(), item.size());
        }
        const SHA1::Digest overallDigest = overall.Finish();
        if (std::memcmp(overallDigest.data(), header->sha1, 20) != 0) {
            return Fail(CHDConvertStatus::VerifyFailed, "The checksum of the CHD file's metadata doesn't match.");
        }
    }

    CHDConvertResult result;
    result.hunks = header->hunkcount;
    result.rawBytes = header->logicalbytes;
    return result;
}

#else // Ymir_HAS_ZLIB

CHDConvertResult ConvertDiscToCHD(const Disc &, const std::filesystem::path &, const CHDConvertOptions &,
                                  const CHDProgressCallback &) {
    CHDConvertResult result;
    result.status = CHDConvertStatus::Unavailable;
    result.message = "This build can't write CHD files.";
    return result;
}

CHDConvertResult VerifyCHD(const std::filesystem::path &, const CHDProgressCallback &) {
    CHDConvertResult result;
    result.status = CHDConvertStatus::Unavailable;
    result.message = "This build can't write CHD files.";
    return result;
}

#endif // Ymir_HAS_ZLIB

CHDConvertResult ConvertImageToCHD(const std::filesystem::path &source, const std::filesystem::path &output,
                                   const CHDConvertOptions &options, const CHDProgressCallback &progress) {
    if (!IsCHDConversionAvailable()) {
        CHDConvertResult result;
        result.status = CHDConvertStatus::Unavailable;
        result.message = "This build can't write CHD files.";
        return result;
    }

    Disc disc;
    std::string messages;
    const bool loaded = LoadDisc(source, disc, false, [&](MessageType type, std::string message) {
        if (type == MessageType::Error || type == MessageType::NotValid) {
            if (!messages.empty()) {
                messages += "\n";
            }
            messages += message;
        }
    });
    if (!loaded) {
        CHDConvertResult result;
        result.status = CHDConvertStatus::LoadFailed;
        result.message = messages.empty() ? "The disc image couldn't be loaded." : messages;
        return result;
    }
    return ConvertDiscToCHD(disc, output, options, progress);
}

} // namespace ymir::media
