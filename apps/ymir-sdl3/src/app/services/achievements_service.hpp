#pragma once

// RetroAchievements support (iOS app): drives rcheevos' rc_client with the emulator's memory and disc.
//
// Threads: the emulator thread calls LoadGame / UnloadGame / Reset / DoFrame; the user interface and the network
// callbacks come from other threads. Every call into rc_client is made with `m_mutex` held, as rc_client isn't thread
// safe.

#include <app/ios/host_interface.hpp>

#include <rc_client.h>

#include <filesystem>
#include <functional>
#include <memory>
#include <mutex>
#include <string>
#include <vector>

namespace app {
struct SharedContext;
}

namespace app::services {

class AchievementsService {
public:
    explicit AchievementsService(SharedContext &context);
    ~AchievementsService();

    AchievementsService(const AchievementsService &) = delete;
    AchievementsService &operator=(const AchievementsService &) = delete;

    /// Hooks the service up to the user interface bridge and logs in with the stored sign-in, if there is one.
    void Initialize();

    /// Called when a disc image is loaded into the emulator (emulator thread).
    void LoadGame(const std::filesystem::path &path);
    /// Called when the disc is ejected, or the game is closed (emulator thread).
    void UnloadGame();
    /// Called when the emulated system is reset (emulator thread).
    void Reset();
    /// Called after every emulated frame (emulator thread).
    void DoFrame();
    /// Called while the emulator is paused, now and then (any thread).
    void Idle();

    /// Hardcore mode is on for the loaded game: no loading of save states, no rewinding, no slow-down.
    bool IsHardcoreActive();

    /// Called when the emulator wants the system reset because hardcore was turned on (set by the app).
    std::function<void()> requestReset;

private:
    // The functions given to rc_client
    static uint32_t ReadMemory(uint32_t address, uint8_t *buffer, uint32_t numBytes, rc_client_t *client);
    static void ServerCall(const rc_api_request_t *request, rc_client_server_callback_t callback, void *callbackData,
                           rc_client_t *client);
    static void HandleEvent(const rc_client_event_t *event, rc_client_t *client);
    static void LogMessage(const char *message, const rc_client_t *client);

    static void LoginDone(int result, const char *errorMessage, rc_client_t *client, void *userdata);
    static void LoadGameDone(int result, const char *errorMessage, rc_client_t *client, void *userdata);

    void ApplySettings();
    void LoginWithStoredToken();
    void Emit(const ios::AchievementEvent &event);
    ios::AchievementsStatus GetStatus();
    std::vector<ios::AchievementEntry> GetAchievements();

    SharedContext &m_context;
    rc_client_t *m_client = nullptr;

    std::recursive_mutex m_mutex;

    // State shown to the user (guarded by m_mutex)
    bool m_loggingIn = false;
    bool m_gameLoading = false;
    bool m_gameUnknown = false;
    std::string m_message;
    std::filesystem::path m_pendingGame; // loaded while not enabled; identified once it is
    bool m_gameRequested = false;
    std::function<void(bool, const std::string &)> m_loginCallback;
    std::string m_loginUser;
};

} // namespace app::services
