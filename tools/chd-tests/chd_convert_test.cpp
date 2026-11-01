// Tests the CHD converter on discs made up here: converts them, loads the original and the CHD file with the
// emulator's own loaders and compares the layout of the disc and every sector. See build.sh.

#include <ymir/media/chd_convert.hpp>
#include <ymir/media/loader/loader.hpp>

extern "C" {
#include <libchdr/cdrom.h>
}
#include <libchdr/chd.h>

#include <algorithm>
#include <array>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <random>
#include <string>
#include <vector>

using namespace ymir;
using namespace ymir::media;
namespace fs = std::filesystem;

static int g_failures = 0;
#define CHECK(cond, ...)                                                                                               \
    do {                                                                                                               \
        if (!(cond)) {                                                                                                 \
            std::printf("  FAIL (line %d): %s  ", __LINE__, #cond);                                                    \
            std::printf(__VA_ARGS__);                                                                                  \
            std::printf("\n");                                                                                         \
            ++g_failures;                                                                                              \
        }                                                                                                              \
    } while (0)

static const uint8_t kSync[12] = {0x00, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x00};

static std::string Hex2(int v) {
    char buf[8];
    std::snprintf(buf, sizeof(buf), "%02d", v);
    return buf;
}
static std::string CueTime(uint32_t frames) {
    return Hex2(frames / 75 / 60) + ":" + Hex2(frames / 75 % 60) + ":" + Hex2(frames % 75);
}
static uint8_t BCD(int v) {
    return static_cast<uint8_t>(((v / 10) << 4) | (v % 10));
}

static void PutString(uint8_t *dst, size_t size, const char *text) {
    std::memset(dst, ' ', size);
    std::memcpy(dst, text, std::min(size, std::strlen(text)));
}

// A mode 1 sector (2352 bytes) with valid error correction codes around the 2048 bytes of data
static void MakeMode1Sector(uint8_t *sector, uint32_t fad, const uint8_t *data) {
    std::memcpy(sector, kSync, 12);
    sector[12] = BCD(fad / 75 / 60);
    sector[13] = BCD(fad / 75 % 60);
    sector[14] = BCD(fad % 75);
    sector[15] = 1;
    std::memcpy(sector + 16, data, 2048);
    std::memset(sector + 2064, 0, 4 + 8); // EDC (not checked by the converter) and the reserved bytes
    ecc_generate(sector);
}

static void MakeSaturnHeader(uint8_t *data2048) {
    std::memset(data2048, 0, 2048);
    PutString(data2048 + 0x00, 16, "SEGA SEGASATURN");
    PutString(data2048 + 0x10, 16, "SEGA TP T-999");
    PutString(data2048 + 0x20, 10, "T-12345 G");
    PutString(data2048 + 0x2A, 6, "V1.000");
    PutString(data2048 + 0x30, 8, "19970101");
    PutString(data2048 + 0x38, 8, "CD-1/1");
    PutString(data2048 + 0x40, 10, "JTUBKAEL");
    PutString(data2048 + 0x50, 16, "J");
    PutString(data2048 + 0x60, 112, "CHD CONVERTER TEST");
    data2048[0xE0] = 0;
    data2048[0xE1] = 0;
    data2048[0xE2] = 0x20;
    data2048[0xE3] = 0;
}

struct TestDisc {
    std::string name;
    fs::path image; // the .cue or .iso
};

static void WriteFile(const fs::path &path, const std::vector<uint8_t> &data) {
    std::ofstream out(path, std::ios::binary);
    out.write(reinterpret_cast<const char *>(data.data()), static_cast<std::streamsize>(data.size()));
}

// A BIN/CUE disc: a data track, an audio track whose pregap is in the file (INDEX 00) and an audio track with a PREGAP
static TestDisc MakeBinCue(const fs::path &dir, uint32_t dataSectors, uint32_t audio1Sectors, uint32_t audio2Sectors) {
    std::mt19937 rng(1234);
    std::vector<uint8_t> bin;
    auto appendSector = [&](const uint8_t *sector) { bin.insert(bin.end(), sector, sector + 2352); };

    // Track 1: data. Mixed contents: compressible, random (incompressible), and a few sectors without valid ECC
    uint32_t fad = 150;
    for (uint32_t i = 0; i < dataSectors; i++, fad++) {
        std::array<uint8_t, 2048> data{};
        if (i == 0) {
            MakeSaturnHeader(data.data());
        } else if (i % 7 == 3) {
            for (auto &b : data) {
                b = static_cast<uint8_t>(rng());
            }
        } else if (i % 5 == 0) {
            // (all zeros)
        } else {
            for (size_t j = 0; j < data.size(); j++) {
                data[j] = static_cast<uint8_t>((j * 7 + i) / 13);
            }
        }
        std::array<uint8_t, 2352> sector{};
        MakeMode1Sector(sector.data(), fad, data.data());
        if (i % 11 == 9) {
            sector[2352 - 5] ^= 0x5A; // breaks the ECC: this sector can't be stripped
        }
        appendSector(sector.data());
    }

    auto audioSector = [&](uint32_t n, uint32_t seed) {
        std::array<uint8_t, 2352> sector{};
        for (uint32_t s = 0; s < 588; s++) {
            const double t = (n * 588 + s) / 44100.0;
            const int16_t left = static_cast<int16_t>(12000 * std::sin(2 * 3.14159265 * (220 + seed) * t) + (rng() % 64));
            const int16_t right = static_cast<int16_t>(9000 * std::sin(2 * 3.14159265 * (330 + seed) * t) + (rng() % 64));
            sector[s * 4 + 0] = static_cast<uint8_t>(left);
            sector[s * 4 + 1] = static_cast<uint8_t>(left >> 8);
            sector[s * 4 + 2] = static_cast<uint8_t>(right);
            sector[s * 4 + 3] = static_cast<uint8_t>(right >> 8);
        }
        return sector;
    };

    // Track 2: audio with INDEX 00 (2 seconds of pregap, in the file) then the audio
    const uint32_t track2Start = dataSectors; // file position in sectors
    const uint32_t pregap2 = 150;
    for (uint32_t i = 0; i < pregap2 + audio1Sectors; i++) {
        const auto sector = audioSector(i, 1);
        appendSector(sector.data());
    }
    // Track 3: audio, preceded by a PREGAP of 2 seconds that isn't in the file
    for (uint32_t i = 0; i < audio2Sectors; i++) {
        const auto sector = audioSector(i, 2);
        appendSector(sector.data());
    }

    const std::string base = "synthetic";
    WriteFile(dir / (base + ".bin"), bin);
    std::string cue;
    cue += "FILE \"" + base + ".bin\" BINARY\n";
    cue += "  TRACK 01 MODE1/2352\n    INDEX 01 00:00:00\n";
    cue += "  TRACK 02 AUDIO\n    INDEX 00 " + CueTime(track2Start) + "\n    INDEX 01 " + CueTime(track2Start + pregap2) + "\n";
    cue += "  TRACK 03 AUDIO\n    PREGAP 00:02:00\n    INDEX 01 " + CueTime(track2Start + pregap2 + audio1Sectors) + "\n";
    std::ofstream(dir / (base + ".cue")) << cue;
    return {"bin/cue with 3 tracks", dir / (base + ".cue")};
}

static TestDisc MakeIso(const fs::path &dir, uint32_t sectors) {
    std::mt19937 rng(99);
    std::vector<uint8_t> iso(static_cast<size_t>(sectors) * 2048);
    for (size_t i = 0; i < iso.size(); i++) {
        iso[i] = static_cast<uint8_t>((i / 64) ^ (rng() % 8));
    }
    MakeSaturnHeader(iso.data());
    WriteFile(dir / "synthetic.iso", iso);
    return {"iso", dir / "synthetic.iso"};
}

static std::vector<uint8_t> ReadAll(const fs::path &p) {
    std::ifstream in(p, std::ios::binary);
    return std::vector<uint8_t>((std::istreambuf_iterator<char>(in)), std::istreambuf_iterator<char>());
}

// Compares two loaded discs: the layout, and every sector
static void CompareDiscs(const Disc &a, const Disc &b) {
    CHECK(a.sessions.size() == 1 && b.sessions.size() == 1, "sessions %zu %zu", a.sessions.size(), b.sessions.size());
    if (a.sessions.size() != 1 || b.sessions.size() != 1) {
        return;
    }
    const Session &sa = a.sessions[0];
    const Session &sb = b.sessions[0];
    CHECK(sa.numTracks == sb.numTracks, "tracks %u %u", sa.numTracks, sb.numTracks);
    CHECK(sa.firstTrackIndex == sb.firstTrackIndex && sa.lastTrackIndex == sb.lastTrackIndex, "track range");
    CHECK(sa.startFrameAddress == sb.startFrameAddress && sa.endFrameAddress == sb.endFrameAddress,
          "session %u-%u vs %u-%u", sa.startFrameAddress, sa.endFrameAddress, sb.startFrameAddress, sb.endFrameAddress);
    CHECK(sa.tocSize == sb.tocSize, "toc size");
    for (uint32_t i = 0; i < sa.tocSize && i < sb.tocSize; i++) {
        CHECK(std::memcmp(&sa.toc[i], &sb.toc[i], sizeof(sa.toc[i])) == 0, "toc entry %u", i);
    }
    CHECK(a.header.productNumber == b.header.productNumber && a.header.hwID == b.header.hwID, "saturn header");

    uint64_t sectorsCompared = 0, differing = 0, missing = 0;
    for (uint32_t t = sa.firstTrackIndex; t <= sa.lastTrackIndex; t++) {
        const Track &ta = sa.tracks[t];
        const Track &tb = sb.tracks[t];
        std::printf("  track %u: FAD %u..%u (index 01 at %u), %s, sector %u | CHD: FAD %u..%u (index 01 at %u), sector %u\n",
                    t + 1, ta.startFrameAddress, ta.endFrameAddress, ta.index01FrameAddress,
                    ta.controlADR == 1 ? "audio" : ta.mode2 ? "mode 2" : "mode 1", ta.sectorSize, tb.startFrameAddress,
                    tb.endFrameAddress, tb.index01FrameAddress, tb.sectorSize);
        CHECK(ta.startFrameAddress == tb.startFrameAddress, "track %u start", t + 1);
        CHECK(ta.endFrameAddress == tb.endFrameAddress, "track %u end", t + 1);
        CHECK(ta.index01FrameAddress == tb.index01FrameAddress, "track %u index 01", t + 1);
        CHECK(ta.controlADR == tb.controlADR && ta.mode2 == tb.mode2, "track %u type", t + 1);
        CHECK(ta.FindIndex(ta.index01FrameAddress) == 1 && tb.FindIndex(tb.index01FrameAddress) == 1, "track %u index 01", t + 1);
        // (a pregap made with PREGAP has no index at all in the BIN/CUE loader; the CHD loader calls it index 0)
        CHECK(ta.FindIndex(ta.startFrameAddress) == 0xFF || ta.FindIndex(ta.startFrameAddress) == tb.FindIndex(tb.startFrameAddress),
              "track %u first index", t + 1);

        std::array<uint8_t, 2352> sectorA{}, sectorB{};
        for (uint32_t fad = ta.startFrameAddress; fad <= ta.endFrameAddress; fad++) {
            const bool okA = ta.ReadSector(fad, sectorA);
            const bool okB = tb.ReadSector(fad, sectorB);
            if (!okA && okB) {
                // (a sector the image has no data for: the CHD file has zeros there)
                static const std::array<uint8_t, 2352> zeros{};
                CHECK(sectorB == zeros || ta.controlADR != 0x01, "FAD %u, missing in the image, isn't zeros in the CHD", fad);
                ++missing;
                continue;
            }
            if (!okA || !okB) {
                CHECK(okA && okB, "read FAD %u (%d %d)", fad, okA, okB);
                break;
            }
            if (ta.controlADR == 0x01 && !ta.bigEndian && tb.bigEndian) {
                for (size_t i = 0; i + 1 < sectorA.size(); i += 2) {
                    std::swap(sectorA[i], sectorA[i + 1]);
                }
            }
            ++sectorsCompared;
            if (sectorA != sectorB) {
                if (++differing <= 3) {
                    std::printf("  sector at FAD %u differs\n", fad);
                }
            }
            Subheader subA, subB;
            ta.ReadSectorSubheader(fad, subA);
            tb.ReadSectorSubheader(fad, subB);
            CHECK(subA.fileNum == subB.fileNum && subA.submode == subB.submode, "subheader at FAD %u", fad);
        }
    }
    CHECK(differing == 0, "%llu of %llu sectors differ", (unsigned long long)differing,
          (unsigned long long)sectorsCompared);
    std::printf("  compared %llu sectors (%llu not in the image)\n", (unsigned long long)sectorsCompared,
                (unsigned long long)missing);
}

static void RunTest(const TestDisc &test, const fs::path &dir) {
    std::printf("== %s\n", test.name.c_str());

    CHDConvertOptions options;
    options.compressionLevel = 6;
    const fs::path out = dir / "out.chd";
    uint64_t lastDone = 0, lastTotal = 0, calls = 0;
    const CHDConvertResult result = ConvertImageToCHD(test.image, out, options, [&](uint64_t done, uint64_t total) {
        ++calls;
        lastDone = done;
        lastTotal = total;
        return true;
    });
    CHECK(result.Succeeded(), "conversion: %s", result.message.c_str());
    if (!result.Succeeded()) {
        return;
    }
    CHECK(lastDone == lastTotal && lastTotal > 0, "progress ended at %llu of %llu", (unsigned long long)lastDone,
          (unsigned long long)lastTotal);
    const uint64_t fileSize = fs::file_size(out);
    CHECK(fileSize == result.outputBytes, "output size %llu vs %llu", (unsigned long long)fileSize,
          (unsigned long long)result.outputBytes);
    uint64_t sourceSize = 0;
    for (const auto &entry : fs::directory_iterator(test.image.parent_path())) {
        if (entry.path().extension() == ".bin" || entry.path().extension() == ".iso") {
            sourceSize += fs::file_size(entry.path());
        }
    }
    std::printf("  %llu hunks, source %llu bytes -> CHD %llu bytes (%.1f%%), %llu progress calls\n",
                (unsigned long long)result.hunks, (unsigned long long)sourceSize, (unsigned long long)fileSize,
                100.0 * fileSize / std::max<uint64_t>(sourceSize, 1), (unsigned long long)calls);

    // The emulator's loaders on both
    Disc original, converted;
    CHECK(LoadDisc(test.image, original, false, [](MessageType, std::string m) { std::printf("  [original] %s\n", m.c_str()); }),
          "loading the original");
    CHECK(LoadDisc(out, converted, false, [](MessageType, std::string m) { std::printf("  [chd] %s\n", m.c_str()); }),
          "loading the CHD file");
    CompareDiscs(original, converted);

    // Same output however many threads
    const fs::path out1 = dir / "out1.chd";
    options.threads = 1;
    options.verify = false;
    const CHDConvertResult single = ConvertImageToCHD(test.image, out1, options);
    CHECK(single.Succeeded(), "single thread: %s", single.message.c_str());
    CHECK(ReadAll(out) == ReadAll(out1), "files from 1 and 4 threads differ");
    fs::remove(out1);

    // Cancelling removes the file
    const fs::path outCancel = dir / "cancel.chd";
    const CHDConvertResult cancelled =
        ConvertImageToCHD(test.image, outCancel, {}, [](uint64_t, uint64_t) { return false; });
    CHECK(cancelled.status == CHDConvertStatus::Cancelled, "cancel status");
    CHECK(!fs::exists(outCancel), "cancelled file was left");

    // Corrupting the file is noticed
    {
        std::vector<uint8_t> bytes = ReadAll(out);
        const fs::path bad = dir / "bad.chd";
        bytes[bytes.size() / 2] ^= 0xFF;
        WriteFile(bad, bytes);
        const CHDConvertResult verified = VerifyCHD(bad);
        CHECK(!verified.Succeeded(), "a corrupted CHD file passed the check");
        fs::remove(bad);
    }
    if (const char *keep = std::getenv("KEEP_DIR")) {
        // (for checking the file with other tools)
        fs::create_directories(keep);
        fs::copy_file(out, fs::path(keep) / (dir.filename().string() + ".chd"), fs::copy_options::overwrite_existing);
        for (const auto &entry : fs::directory_iterator(test.image.parent_path())) {
            fs::copy_file(entry.path(), fs::path(keep) / (dir.filename().string() + "-src-" + entry.path().filename().string()),
                          fs::copy_options::overwrite_existing);
        }
    }
    fs::remove(out);
}

int main(int argc, char **argv) {
    const fs::path root = fs::temp_directory_path() / "ymir-chd-test";
    fs::remove_all(root);

    {
        const fs::path dir = root / "bincue";
        fs::create_directories(dir);
        RunTest(MakeBinCue(dir, 700, 900, 400), dir);
    }
    {
        // (a size that isn't a multiple of 8 frames)
        const fs::path dir = root / "bincue2";
        fs::create_directories(dir);
        RunTest(MakeBinCue(dir, 151, 333, 77), dir);
    }
    {
        const fs::path dir = root / "iso";
        fs::create_directories(dir);
        RunTest(MakeIso(dir, 500), dir);
    }

    // A real image given on the command line
    for (int i = 1; i < argc; i++) {
        const fs::path dir = root / ("real" + std::to_string(i));
        fs::create_directories(dir);
        RunTest({std::string("image ") + argv[i], argv[i]}, dir);
    }

    fs::remove_all(root);
    std::printf("\n%s (%d failures)\n", g_failures == 0 ? "ALL PASSED" : "FAILED", g_failures);
    return g_failures == 0 ? 0 : 1;
}
