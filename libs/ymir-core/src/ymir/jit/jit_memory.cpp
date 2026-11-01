#include <ymir/jit/jit_memory.hpp>

#include <algorithm>
#include <cstdint>
#include <cstdio>
#include <cctype>
#include <cstdlib>
#include <cstring>
#include <string>

#if defined(__aarch64__) || defined(_M_ARM64)
    #define YMIR_JIT_ARCH_SUPPORTED 1
#else
    #define YMIR_JIT_ARCH_SUPPORTED 0
#endif

#if defined(__APPLE__)
    #include <TargetConditionals.h>
    #include <libkern/OSCacheControl.h>
    #include <pthread.h>
    #include <sys/mman.h>
    #include <sys/sysctl.h>
    #include <sys/utsname.h>
    #include <unistd.h>
    #include <dirent.h>
    #if TARGET_OS_IPHONE && !TARGET_OS_SIMULATOR
        #include <mach/mach.h>
        #include <mach/vm_map.h>
        #define YMIR_JIT_IOS_DEVICE 1
        extern "C" int csops(pid_t pid, unsigned int ops, void *useraddr, size_t usersize);
    #endif
#elif defined(__unix__)
    #include <sys/mman.h>
    #include <unistd.h>
#endif

#ifndef YMIR_JIT_IOS_DEVICE
    #define YMIR_JIT_IOS_DEVICE 0
#endif

namespace ymir::jit {

namespace {

    bool g_testingMode = false;
    std::string g_chipName;
    bool g_forceTxm = false;

#if YMIR_JIT_IOS_DEVICE
    constexpr unsigned kCsOpsStatus = 0;
    constexpr unsigned kCsDebugged = 0x10000000;

    struct OsVersion {
        int major = 0;
        int minor = 0;
    };

    OsVersion GetOsVersion() {
        OsVersion v;
        char version[64] = {};
        size_t versionLen = sizeof(version);
        if (sysctlbyname("kern.osproductversion", version, &versionLen, nullptr, 0) == 0) {
            std::sscanf(version, "%d.%d", &v.major, &v.minor);
        }
        return v;
    }

    // Same rules as StosDebug's ProcessInfo.detectedTXM, using only the hardware model and the OS version. Works
    // without Metal, so it is the last resort.
    bool ModelRuleHasTXM(const char *hw, int osMajor) {
        if (osMajor >= 27) {
            return std::strcmp(hw, "iPad8,11") != 0 && std::strcmp(hw, "iPad8,12") != 0;
        }
        if (osMajor >= 26) {
            const bool isPad = std::strncmp(hw, "iPad", 4) == 0;
            const bool isPhone = std::strncmp(hw, "iPhone", 6) == 0;
            if (!isPad && !isPhone) {
                return false;
            }
            int major = 0, minor = 0;
            if (std::sscanf(hw + (isPad ? 4 : 6), "%d,%d", &major, &minor) != 2) {
                return false;
            }
            double scale = 10.0;
            for (int m = minor; m >= 10; m /= 10) {
                scale *= 10.0;
            }
            const double hwVersion = major + static_cast<double>(minor) / scale;
            return isPad ? (hwVersion >= 14.5) : (hwVersion >= 14.2);
        }
        return false;
    }

    // The first entry of a directory whose name has the given length (the Preboot volume names are hashes).
    std::string EntryWithLength(const std::string &dir, size_t length) {
        std::string found;
        if (DIR *d = opendir(dir.c_str())) {
            while (const dirent *e = readdir(d)) {
                if (std::strlen(e->d_name) == length) {
                    found = dir + "/" + e->d_name;
                    break;
                }
            }
            closedir(d);
        }
        return found;
    }

    // The TXM image is present in the Preboot volume on TXM devices (the approach MeloCafe uses).
    bool TxmFirmwarePresent() {
        const char *img = "usr/standalone/firmware/FUD/Ap,TrustedExecutionMonitor.img4";
        const std::string boot = EntryWithLength("/System/Volumes/Preboot", 36);
        if (!boot.empty()) {
            const std::string file = EntryWithLength(boot + "/boot", 96);
            if (!file.empty()) {
                return access((file + "/" + img).c_str(), F_OK) == 0;
            }
        }
        const std::string file = EntryWithLength("/private/preboot", 96);
        if (!file.empty()) {
            return access((file + "/" + img).c_str(), F_OK) == 0;
        }
        return false;
    }

    // "Apple A15 GPU" -> ('A', 15). False if the name is unknown.
    bool ChipInfo(char &letter, int &number) {
        std::string name = g_chipName;
        for (char &c : name) {
            c = static_cast<char>(std::toupper(static_cast<unsigned char>(c)));
        }
        const size_t pos = name.find("APPLE ");
        if (pos == std::string::npos) {
            return false;
        }
        char l = 0;
        int n = 0;
        if (std::sscanf(name.c_str() + pos, "APPLE %c%d", &l, &n) == 2 && (l == 'A' || l == 'M')) {
            letter = l;
            number = n;
            return true;
        }
        return false;
    }

    // Decides whether the device has TXM, and says how in `info`. In order: a manual override, the TXM firmware image
    // in Preboot, the chip generation (A15/M2 and newer on iOS 26.6, newer than the A12 on iOS 27), and finally the
    // model identifier.
    bool DetectTXM(std::string &info) {
        struct utsname un;
        if (uname(&un) != 0) {
            info = "uname failed";
            return false;
        }
        if (g_forceTxm) {
            info = "forceTXM is set";
            return true;
        }
        const OsVersion os = GetOsVersion();
        char letter = 0;
        int number = 0;
        const bool haveChip = ChipInfo(letter, number);
        const bool firmware = TxmFirmwarePresent();
        const bool modelRule = ModelRuleHasTXM(un.machine, os.major);

        bool result;
        const char *why;
        if (os.major >= 27) {
            result = (haveChip && letter == 'A') ? number > 12 : modelRule || haveChip;
            why = "iOS 27+: chip rule";
        } else if (firmware) {
            result = true;
            why = "TrustedExecutionMonitor firmware found in Preboot";
        } else if ((os.major > 26 || (os.major == 26 && os.minor >= 6)) && haveChip) {
            result = (letter == 'M') ? number >= 2 : number >= 15;
            why = "iOS 26.6+: chip rule (firmware not found)";
        } else if (os.major >= 26) {
            result = modelRule;
            why = "model identifier rule (firmware not found)";
        } else {
            result = false;
            why = "iOS older than 26";
        }
        char buffer[256];
        std::snprintf(buffer, sizeof(buffer), "model=%s os=%d.%d chip=%c%d(valid=%d) firmware=%d modelRule=%d -> %s (%s)",
                      un.machine, os.major, os.minor, haveChip ? letter : '?', number, static_cast<int>(haveChip),
                      static_cast<int>(firmware), static_cast<int>(modelRule), result ? "TXM" : "no TXM", why);
        info = buffer;
        return result;
    }

    // Plain naked functions, with nothing from the compiler between the register setup and the brk: the JIT enabler's
    // script (universal.js) reads x16 (the command) and x0/x1 (the arguments) when it stops on the brk, moves the pc
    // past it and, for the prepare command, writes the address of the region into x0.
    // Command 1 prepares a JIT region. With a NULL address the enabler allocates the region itself and returns it
    // (NULL on failure); otherwise it prepares the existing mapping at `addr`.
    __attribute__((noinline, optnone, naked)) void *TxmPrepareRegion([[maybe_unused]] void *addr, [[maybe_unused]] size_t len) {
        __asm__ volatile("mov x16, #1\n"
                         "brk #0xf00d\n"
                         "ret");
    }

    // Command 0 detaches the debugger.
    __attribute__((noinline, optnone, naked)) void TxmDetach() {
        __asm__ volatile("mov x16, #0\n"
                         "brk #0xf00d\n"
                         "ret");
    }

    bool ProcessIsDebugged() {
        int flags = 0;
        if (csops(getpid(), kCsOpsStatus, &flags, sizeof(flags)) != 0) {
            return false;
        }
        return (flags & kCsDebugged) != 0;
    }
#endif

    size_t PageSize() {
#if defined(__APPLE__) || defined(__unix__)
        return static_cast<size_t>(getpagesize());
#else
        return 4096;
#endif
    }

    size_t RoundUp(size_t value, size_t alignment) {
        return (value + alignment - 1) & ~(alignment - 1);
    }

} // namespace

std::string JitStatus::Message() const {
    std::string text = BaseMessage();
    if (!txmDetection.empty()) {
        text += "\nTXM detection: " + txmDetection;
    }
    return text;
}

std::string JitStatus::BaseMessage() const {
    switch (reason) {
    case Reason::Available: return txmDevice ? "Available (TXM mode)" : "Available";
    case Reason::UnsupportedArchitecture: return "Not supported on this device";
    case Reason::NeedsDebugger:
        return "A JIT enabler (StikDebug or StosDebug) must be attached to Ymir. Use \"Enable JIT\" and relaunch if "
               "needed.";
    case Reason::AllocationFailed: return "The system did not allow executable memory";
    }
    return {};
}

void SetJitTestingMode(bool enable) {
    g_testingMode = enable;
}

void SetChipName(const char *name) {
    g_chipName = name != nullptr ? name : "";
}

void SetForceTxm(bool force) {
    g_forceTxm = force;
}

JitStatus ProbeJit() {
    JitStatus status{};
#if !YMIR_JIT_ARCH_SUPPORTED
    status.reason = g_testingMode ? JitStatus::Reason::Available : JitStatus::Reason::UnsupportedArchitecture;
#elif YMIR_JIT_IOS_DEVICE
    static std::string detection;
    static const bool txm = DetectTXM(detection);
    status.txmDevice = txm;
    status.txmDetection = detection;
    status.processDebugged = ProcessIsDebugged();
    status.reason = status.processDebugged ? JitStatus::Reason::Available : JitStatus::Reason::NeedsDebugger;
#else
    status.reason = JitStatus::Reason::Available;
#endif
    return status;
}

JitMemory::~JitMemory() {
    if (m_exec == nullptr) {
        return;
    }
#if defined(__APPLE__) || defined(__unix__)
    // The TXM pool must stay mapped: other code may still be running from it and the debugger is gone. It is a one-time
    // allocation for the lifetime of the process.
    if (m_mode != Mode::PoolTxm) {
        munmap(m_exec, m_size);
    }
#endif
}

bool JitMemory::Initialize(size_t size) {
    if (m_exec != nullptr) {
        return true;
    }

    m_status = ProbeJit();
    if (!m_status.Available()) {
        return false;
    }

    size = RoundUp(size, std::max<size_t>(PageSize(), 16384));

#if !YMIR_JIT_ARCH_SUPPORTED
    if (g_testingMode) {
    #if defined(__APPLE__) || defined(__unix__)
        void *memory = mmap(nullptr, size, PROT_READ | PROT_WRITE | PROT_EXEC, MAP_PRIVATE | MAP_ANON, -1, 0);
        if (memory != MAP_FAILED) {
            m_exec = m_write = static_cast<uint8 *>(memory);
            m_size = size;
            m_mode = Mode::Rwx;
            return true;
        }
    #endif
    }
    return false;
#elif YMIR_JIT_IOS_DEVICE
    if (m_status.txmDevice) {
        if (!InitializeTxmPool(size)) {
            m_status.reason = JitStatus::Reason::AllocationFailed;
            return false;
        }
        return true;
    }

    // Debugged process on a device without TXM: read+write+execute mappings are allowed
    void *memory = mmap(nullptr, size, PROT_READ | PROT_WRITE | PROT_EXEC, MAP_PRIVATE | MAP_ANON, -1, 0);
    if (memory != MAP_FAILED) {
        m_exec = m_write = static_cast<uint8 *>(memory);
        m_size = size;
        m_mode = Mode::Rwx;
        return true;
    }

    // Otherwise flip between writable and executable with mprotect
    memory = mmap(nullptr, size, PROT_READ | PROT_EXEC, MAP_PRIVATE | MAP_ANON, -1, 0);
    if (memory != MAP_FAILED) {
        m_exec = m_write = static_cast<uint8 *>(memory);
        m_size = size;
        m_mode = Mode::MprotectFlip;
        return true;
    }
    m_status.reason = JitStatus::Reason::AllocationFailed;
    return false;
#elif defined(__APPLE__)
    void *memory = mmap(nullptr, size, PROT_READ | PROT_WRITE | PROT_EXEC, MAP_PRIVATE | MAP_ANON | MAP_JIT, -1, 0);
    if (memory == MAP_FAILED) {
        m_status.reason = JitStatus::Reason::AllocationFailed;
        return false;
    }
    m_exec = m_write = static_cast<uint8 *>(memory);
    m_size = size;
    m_mode = Mode::MapJit;
    return true;
#elif defined(__unix__)
    void *memory = mmap(nullptr, size, PROT_READ | PROT_WRITE | PROT_EXEC, MAP_PRIVATE | MAP_ANON, -1, 0);
    if (memory == MAP_FAILED) {
        m_status.reason = JitStatus::Reason::AllocationFailed;
        return false;
    }
    m_exec = m_write = static_cast<uint8 *>(memory);
    m_size = size;
    m_mode = Mode::Rwx;
    return true;
#else
    return false;
#endif
}

bool JitMemory::InitializeTxmPool(size_t size) {
#if YMIR_JIT_IOS_DEVICE
    // 1. Let the enabler allocate and prepare the read+execute region itself: with a NULL address it returns the region
    // it prepared (the way MeloCafe does it). This also avoids handing it an address it can't handle.
    void *rx = TxmPrepareRegion(nullptr, size);
    if (rx == nullptr) {
        // 2. The enabler didn't allocate one (an older script, say): reserve the region here and have it prepared.
        rx = mmap(nullptr, size, PROT_READ | PROT_EXEC, MAP_ANON | MAP_PRIVATE, -1, 0);
        if (rx == MAP_FAILED) {
            return false;
        }
        // The enabler's prepare step only understands addresses below 2^36
        if (reinterpret_cast<uintptr_t>(rx) + size > (1ull << 36)) {
            std::fprintf(stderr, "[ymir-jit] TXM region %p is above 2^36; the JIT enabler may not prepare it\n", rx);
        }
        TxmPrepareRegion(rx, size);
    }

    // 3. Map a writable alias of the same pages
    vm_address_t rw = 0;
    vm_prot_t curProt = 0, maxProt = 0;
    const kern_return_t kr = vm_remap(mach_task_self(), &rw, size, 0, VM_FLAGS_ANYWHERE, mach_task_self(),
                                      reinterpret_cast<vm_address_t>(rx), FALSE, &curProt, &maxProt, VM_INHERIT_NONE);
    if (kr != KERN_SUCCESS) {
        munmap(rx, size);
        return false;
    }
    if (mprotect(reinterpret_cast<void *>(rw), size, PROT_READ | PROT_WRITE) != 0) {
        munmap(rx, size);
        munmap(reinterpret_cast<void *>(rw), size);
        return false;
    }

    m_exec = static_cast<uint8 *>(rx);
    m_write = reinterpret_cast<uint8 *>(rw);
    m_size = size;
    m_mode = Mode::PoolTxm;

    // 4. The region is prepared: let go of the debugger (universal script: x16 = 0). Only one pool may do this per
    // process, since a second handshake after detaching would crash the app.
    TxmDetach();
    return true;
#else
    (void)size;
    return false;
#endif
}

size_t JitMemory::Allocate(size_t size) {
    const size_t offset = RoundUp(m_used, 16);
    const size_t end = offset + RoundUp(size, 16);
    if (m_exec == nullptr || end > m_size) {
        return SIZE_MAX;
    }
    m_used = end;
    return offset;
}

void JitMemory::BeginWrite() {
#if defined(__APPLE__) && !YMIR_JIT_IOS_DEVICE
    if (m_mode == Mode::MapJit) {
        pthread_jit_write_protect_np(0);
    }
#endif
#if YMIR_JIT_IOS_DEVICE
    if (m_mode == Mode::MprotectFlip) {
        mprotect(m_write, m_size, PROT_READ | PROT_WRITE);
    }
#endif
}

void JitMemory::EndWrite(size_t offset, size_t size) {
#if defined(__APPLE__) && !YMIR_JIT_IOS_DEVICE
    if (m_mode == Mode::MapJit) {
        pthread_jit_write_protect_np(1);
    }
#endif
#if YMIR_JIT_IOS_DEVICE
    if (m_mode == Mode::MprotectFlip) {
        mprotect(m_write, m_size, PROT_READ | PROT_EXEC);
    }
#endif
    if (size == 0) {
        return;
    }
#if defined(__APPLE__)
    sys_icache_invalidate(m_exec + offset, size);
#elif defined(__aarch64__) && defined(__GNUC__)
    __builtin___clear_cache(reinterpret_cast<char *>(m_exec + offset), reinterpret_cast<char *>(m_exec + offset + size));
#endif
}

} // namespace ymir::jit
