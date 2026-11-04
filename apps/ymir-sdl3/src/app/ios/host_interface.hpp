#pragma once

// Interface between the emulator frontend and the native iOS (Swift) user interface.
//
// The emulator fills in the callbacks once it is up and running and clears them when it shuts down. All callbacks are
// invoked from the main thread, the same one that runs the SDL event loop, so they can safely enqueue events and touch
// frontend state. Only standard library types are used so that this header can be included from Objective-C++.

#include <cstdint>
#include <ctime>
#include <filesystem>
#include <functional>
#include <string>
#include <vector>

namespace app::ios {

struct SaveSlotInfo {
    int index = 0;
    bool present = false;
    std::string description; // e.g. date and time; empty if the slot is empty
};

/// A BIOS (IPL ROM) image found in the BIOS folder.
struct BiosEntry {
    std::string path;     // absolute path
    std::string fileName;
    std::string detail;   // what the image is (version and date), or that it isn't a known image
    bool selected = false; // the one in use
};

struct HostInterface {
    // -- State queries --
    std::function<bool()> isPaused;
    std::function<bool()> isFastForward;
    std::function<bool()> isDiscLoaded;
    std::function<std::filesystem::path()> loadedDiscPath;
    std::function<bool()> hasIPLROM;      // true if an IPL ROM is loaded into the emulator
    std::function<std::string()> iplName; // human readable name of the loaded IPL ROM
    std::function<std::vector<SaveSlotInfo>()> saveSlots;
    std::function<std::filesystem::path(int)> saveStatePath; // file of a slot's save state; empty if there's none

    // -- Actions --
    std::function<void(const std::filesystem::path &)> launchGame;
    std::function<void(const std::filesystem::path &, int)> launchGameAndLoadState; // path, slot of that game's states
    std::function<void(bool)> setPaused;
    std::function<void(bool)> setFastForward;
    std::function<void()> softReset;
    std::function<void()> hardReset;
    std::function<void()> openCloseTray;
    std::function<void()> ejectDisc;
    std::function<void()> quitGame; // unloads the game and leaves the emulator idle
    std::function<void(int)> saveState;
    // Saves a state of the game into the autosave slot (if the setting is on); calls the function on the emulator
    // thread when that's done, or right away if there was nothing to do
    std::function<void(std::function<void()>)> autoSave;
    std::function<void(int)> loadState;
    std::function<void(int)> deleteState;
    std::function<void()> takeScreenshot;
    std::function<std::string()> reloadIPLROM; // rescans the IPL ROM folder; returns an error message or "" on success
    std::function<std::vector<BiosEntry>()> listIPLROMs; // scans the folder; the images found, the one in use marked
    std::function<bool()> iplIsAutomatic;                // the image is picked by the emulator (by region), not by the user
    // Uses this image (an empty path: let the emulator pick by region), reloads it and restarts the system.
    // Returns an error message or "" on success.
    std::function<std::string(const std::string &)> selectIPLROM;
    // Deletes an image from the BIOS folder. If it was the one in use, another one is loaded and the system restarts.
    // Returns an error message or "" on success.
    std::function<std::string(const std::string &)> deleteIPLROM;

    // -- Settings --
    std::function<bool(const std::string &, bool)> getBool;    // key, default
    std::function<void(const std::string &, bool)> setBool;    // key, value
    std::function<float(const std::string &, float)> getFloat; // key, default
    std::function<void(const std::string &, float)> setFloat;  // key, value
    std::function<std::string(const std::string &)> getPath;   // key
    std::function<void(const std::string &, const std::string &)> setPath; // key, absolute path
    std::function<int(const std::string &, int)> getInt;       // key, default (also used for enumerations)
    std::function<void(const std::string &, int)> setInt;      // key, value
};

// -- RetroAchievements --

/// One achievement of the game that is loaded.
struct AchievementEntry {
    uint32_t id = 0;
    std::string title;
    std::string description;
    std::string badgeUrl;       // picture when unlocked
    std::string badgeLockedUrl; // picture while locked
    uint32_t points = 0;
    bool unlocked = false;
    bool unlockedHardcore = false;
    bool unsupported = false;   // can't be earned with this version of the runtime
    bool unofficial = false;
    std::string progress; // e.g. "12/50" for achievements that measure something; empty otherwise
    float progressPercent = 0.0f;
    std::time_t unlockTime = 0;
};

/// What the user interface shows about the state of RetroAchievements.
struct AchievementsStatus {
    bool enabled = false;      // the setting
    bool hardcore = false;     // the setting
    bool loggingIn = false;
    bool loggedIn = false;
    bool gameLoading = false;
    bool gameLoaded = false;   // a game that RetroAchievements knows
    bool gameUnknown = false;  // a game is loaded but RetroAchievements doesn't know it
    bool hardcoreActive = false; // hardcore is on for the loaded game: save states can't be loaded, no rewind
    std::string username;
    std::string displayName;
    std::string avatarUrl;
    uint32_t score = 0;
    uint32_t softcoreScore = 0;
    std::string gameTitle;
    std::string gameBadgeUrl;
    uint32_t numAchievements = 0;
    uint32_t numUnlocked = 0;
    uint32_t points = 0;
    uint32_t pointsUnlocked = 0;
    std::string richPresence;
    std::string message; // last problem to tell the user about (login failed and so on); empty if none
};

/// Something the user interface should show.
struct AchievementEvent {
    enum class Kind {
        Unlocked,        // an achievement was earned
        GameLoaded,      // the loaded game is known: title, number of achievements
        GameUnknown,     // RetroAchievements doesn't know the loaded game (it has no achievements, or this disc isn't one of theirs)
        GameCompleted,   // every achievement of the game was earned
        LoginSucceeded,
        LoginFailed,     // message
        Error,           // message
        Disconnected,    // unlocks couldn't be sent and are kept for later
        Reconnected,
        ChallengeShow,   // an indicator for a challenge achievement
        ChallengeHide,
        ProgressShow,    // progress of a measured achievement: title, progress
        LeaderboardStarted,
        LeaderboardFailed,
        LeaderboardSubmitted,
    };
    Kind kind = Kind::Error;
    std::string title;
    std::string description;
    std::string badgeUrl;
    std::string message;
    uint32_t points = 0;
    uint32_t id = 0;
};

/// Connects the achievements service of the emulator and the native user interface. The first group is filled in by the
/// emulator, the second by the user interface (before the emulator starts).
struct AchievementsBridge {
    // -- Filled in by the emulator --
    std::function<AchievementsStatus()> status;
    std::function<std::vector<AchievementEntry>()> achievements;
    // Logs in with a user name and password; reports whether it worked, and the message if not
    std::function<void(const std::string &, const std::string &, std::function<void(bool, const std::string &)>)> login;
    std::function<void()> logout;
    // Tells the service that the settings changed (enabled, hardcore)
    std::function<void()> settingsChanged;

    // -- Filled in by the user interface --
    // Sends a request to the server. The response function takes the HTTP status (or -1 on a failure to connect) and the body;
    // it may be called from any thread.
    std::function<void(const std::string &url, const std::string &postData, const std::string &contentType,
                       std::function<void(int, std::string)> done)>
        http;
    std::function<void(const AchievementEvent &)> event; // may be called from any thread
    std::function<bool()> enabled;
    std::function<bool()> hardcore;
    // Stored sign-in (the user name and the token the server gave, not the password)
    std::function<bool(std::string &user, std::string &token)> loadCredentials;
    std::function<void(const std::string &user, const std::string &token)> saveCredentials;
    std::function<void()> clearCredentials;
};

inline AchievementsBridge &GetAchievementsBridge() {
    static AchievementsBridge bridge{};
    return bridge;
}

/// @brief Gets the global host interface. Callbacks are empty while the emulator isn't running.
inline HostInterface &GetHost() {
    static HostInterface host{};
    return host;
}

} // namespace app::ios
