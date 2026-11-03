#include "achievements_service.hpp"

#include <app/shared_context.hpp>

#include <ymir/media/disc.hpp>
#include <ymir/media/loader/loader.hpp>
#include <ymir/sys/saturn.hpp>

#include <rc_consoles.h>
#include <rc_hash.h>

#include <algorithm>
#include <cstdio>
#include <cstring>

namespace app::services {

namespace {

    // -- Disc reader for rcheevos' hashing (the Saturn hash is made from the first sector of the first track) --

    struct DiscTrackHandle {
        ymir::media::Disc disc;
        const ymir::media::Track *track = nullptr;
    };

    // Absolute frame address of the first sector of the disc
    constexpr uint32_t kFADOffset = 150;

    void *CdOpenTrack(const char *path, uint32_t trackNumber) {
        auto handle = std::make_unique<DiscTrackHandle>();
        if (!ymir::media::LoadDisc(std::filesystem::path{path}, handle->disc, false, [](auto, std::string) {})) {
            return nullptr;
        }

        const ymir::media::Track *found = nullptr;
        for (const auto &session : handle->disc.sessions) {
            for (const auto &track : session.tracks) {
                if (track.controlADR == 0x00) {
                    continue; // unused entry
                }
                const bool isData = (track.controlADR & 0x40) != 0;
                if (trackNumber == RC_HASH_CDTRACK_FIRST_DATA) {
                    if (isData && found == nullptr) {
                        found = &track;
                    }
                } else if (trackNumber == RC_HASH_CDTRACK_LAST) {
                    found = &track;
                } else if (track.index == trackNumber) {
                    found = &track;
                }
            }
            if (found != nullptr && trackNumber != RC_HASH_CDTRACK_LAST) {
                break;
            }
        }
        if (found == nullptr) {
            return nullptr;
        }
        handle->track = found;
        return handle.release();
    }

    size_t CdReadSector(void *trackHandle, uint32_t sector, void *buffer, size_t requestedBytes) {
        auto *handle = static_cast<DiscTrackHandle *>(trackHandle);
        if (handle == nullptr || handle->track == nullptr) {
            return 0;
        }
        std::array<uint8_t, 2048> data{};
        if (!handle->track->ReadSectorUserData(sector + kFADOffset, std::span<uint8_t, 2048>{data})) {
            return 0;
        }
        const size_t count = std::min<size_t>(requestedBytes, data.size());
        std::memcpy(buffer, data.data(), count);
        return count;
    }

    void CdCloseTrack(void *trackHandle) {
        delete static_cast<DiscTrackHandle *>(trackHandle);
    }

    uint32_t CdFirstTrackSector(void *trackHandle) {
        auto *handle = static_cast<DiscTrackHandle *>(trackHandle);
        if (handle == nullptr || handle->track == nullptr) {
            return 0;
        }
        const uint32_t fad = handle->track->startFrameAddress;
        return fad >= kFADOffset ? fad - kFADOffset : 0;
    }

    std::string Str(const char *text) {
        return text != nullptr ? std::string{text} : std::string{};
    }

    AchievementsService *Service(const rc_client_t *client) {
        return static_cast<AchievementsService *>(rc_client_get_userdata(client));
    }

} // namespace

AchievementsService::AchievementsService(SharedContext &context)
    : m_context(context) {}

AchievementsService::~AchievementsService() {
    auto &bridge = ios::GetAchievementsBridge();
    bridge.status = {};
    bridge.achievements = {};
    bridge.login = {};
    bridge.logout = {};
    bridge.settingsChanged = {};

    std::lock_guard lock{m_mutex};
    if (m_client != nullptr) {
        rc_client_destroy(m_client);
        m_client = nullptr;
    }
}

void AchievementsService::Initialize() {
    std::lock_guard lock{m_mutex};
    if (m_client != nullptr) {
        return;
    }

    m_client = rc_client_create(&AchievementsService::ReadMemory, &AchievementsService::ServerCall);
    rc_client_set_userdata(m_client, this);
    rc_client_set_event_handler(m_client, &AchievementsService::HandleEvent);
    rc_client_enable_logging(m_client, RC_CLIENT_LOG_LEVEL_ERROR, &AchievementsService::LogMessage);

    rc_hash_callbacks_t hashCallbacks{};
    hashCallbacks.cdreader.open_track = &CdOpenTrack;
    hashCallbacks.cdreader.read_sector = &CdReadSector;
    hashCallbacks.cdreader.close_track = &CdCloseTrack;
    hashCallbacks.cdreader.first_track_sector = &CdFirstTrackSector;
    rc_client_set_hash_callbacks(m_client, &hashCallbacks);

    auto &bridge = ios::GetAchievementsBridge();
    bridge.status = [this] { return GetStatus(); };
    bridge.achievements = [this] { return GetAchievements(); };
    bridge.settingsChanged = [this] { ApplySettings(); };
    bridge.logout = [this] {
        std::lock_guard lock{m_mutex};
        if (m_client != nullptr) {
            rc_client_logout(m_client);
        }
        m_message.clear();
        if (auto &b = ios::GetAchievementsBridge(); b.clearCredentials) {
            b.clearCredentials();
        }
    };
    bridge.login = [this](const std::string &user, const std::string &password,
                          std::function<void(bool, const std::string &)> done) {
        std::lock_guard lock{m_mutex};
        if (m_client == nullptr) {
            if (done) {
                done(false, "Achievements aren't available.");
            }
            return;
        }
        m_loggingIn = true;
        m_message.clear();
        m_loginUser = user;
        m_loginCallback = std::move(done);
        rc_client_begin_login_with_password(m_client, user.c_str(), password.c_str(), &AchievementsService::LoginDone,
                                            this);
    };

    ApplySettings();
    LoginWithStoredToken();
}

void AchievementsService::ApplySettings() {
    std::lock_guard lock{m_mutex};
    if (m_client == nullptr) {
        return;
    }
    auto &bridge = ios::GetAchievementsBridge();
    const bool hardcore = bridge.hardcore ? bridge.hardcore() : false;
    if (static_cast<bool>(rc_client_get_hardcore_enabled(m_client)) != hardcore) {
        // (turning it on with a game running asks for a reset through the event handler)
        rc_client_set_hardcore_enabled(m_client, hardcore ? 1 : 0);
    }

    const bool enabled = bridge.enabled ? bridge.enabled() : false;
    if (enabled) {
        LoginWithStoredToken();
        // A game loaded while the achievements were off is identified now
        if (!m_pendingGame.empty() && !m_gameRequested && !rc_client_is_game_loaded(m_client)) {
            const auto path = m_pendingGame;
            m_pendingGame.clear();
            LoadGame(path);
        }
    } else if (rc_client_is_game_loaded(m_client)) {
        rc_client_unload_game(m_client);
        m_gameRequested = false;
        m_gameUnknown = false;
    }
}

void AchievementsService::LoginWithStoredToken() {
    std::lock_guard lock{m_mutex};
    if (m_client == nullptr || m_loggingIn || rc_client_get_user_info(m_client) != nullptr) {
        return;
    }
    auto &bridge = ios::GetAchievementsBridge();
    if (!(bridge.enabled && bridge.enabled()) || !bridge.loadCredentials) {
        return;
    }
    std::string user, token;
    if (!bridge.loadCredentials(user, token) || user.empty() || token.empty()) {
        return;
    }
    m_loggingIn = true;
    m_loginUser = user;
    m_loginCallback = {};
    rc_client_begin_login_with_token(m_client, user.c_str(), token.c_str(), &AchievementsService::LoginDone, this);
}

void AchievementsService::LoadGame(const std::filesystem::path &path) {
    std::lock_guard lock{m_mutex};
    if (m_client == nullptr) {
        return;
    }
    auto &bridge = ios::GetAchievementsBridge();
    if (!(bridge.enabled && bridge.enabled())) {
        m_pendingGame = path; // identified when the achievements are turned on
        return;
    }
    if (rc_client_is_game_loaded(m_client)) {
        rc_client_unload_game(m_client);
    }
    m_pendingGame = path;
    m_gameRequested = true;
    m_gameLoading = true;
    m_gameUnknown = false;
    const std::string utf8 = path.string(); // (UTF-8 on this platform)
    rc_client_begin_identify_and_load_game(m_client, RC_CONSOLE_SATURN, utf8.c_str(), nullptr, 0,
                                           &AchievementsService::LoadGameDone, this);
}

void AchievementsService::UnloadGame() {
    std::lock_guard lock{m_mutex};
    m_pendingGame.clear();
    m_gameRequested = false;
    m_gameLoading = false;
    m_gameUnknown = false;
    if (m_client != nullptr) {
        rc_client_unload_game(m_client);
    }
}

void AchievementsService::Reset() {
    std::lock_guard lock{m_mutex};
    if (m_client != nullptr) {
        rc_client_reset(m_client);
    }
}

void AchievementsService::DoFrame() {
    std::lock_guard lock{m_mutex};
    if (m_client != nullptr && rc_client_is_game_loaded(m_client)) {
        rc_client_do_frame(m_client);
    }
}

void AchievementsService::Idle() {
    std::lock_guard lock{m_mutex};
    if (m_client != nullptr) {
        rc_client_idle(m_client);
    }
}

bool AchievementsService::IsHardcoreActive() {
    std::lock_guard lock{m_mutex};
    return m_client != nullptr && rc_client_get_hardcore_enabled(m_client) && rc_client_is_game_loaded(m_client);
}

// -- Callbacks from rc_client --

uint32_t AchievementsService::ReadMemory(uint32_t address, uint8_t *buffer, uint32_t numBytes, rc_client_t *client) {
    auto *self = Service(client);
    if (self == nullptr || !self->m_context.saturn.instance) {
        return 0;
    }
    // The addresses are the ones of RetroAchievements' memory map for the Saturn: 1 MiB of Low Work RAM (at 0x200000 in
    // the Saturn's address space), then 1 MiB of High Work RAM (at 0x6000000). The RAM is kept in the Saturn's byte
    // order (big endian), which is what the achievements are written for.
    auto &mem = self->m_context.saturn.instance->mem;
    constexpr uint32_t kRegionSize = 0x100000;

    uint32_t done = 0;
    while (done < numBytes) {
        const uint32_t addr = address + done;
        const uint8_t *source = nullptr;
        uint32_t available = 0;
        if (addr < kRegionSize) {
            source = mem.WRAMLow.data() + addr;
            available = kRegionSize - addr;
        } else if (addr < 2 * kRegionSize) {
            source = mem.WRAMHigh.data() + (addr - kRegionSize);
            available = 2 * kRegionSize - addr;
        } else {
            break;
        }
        const uint32_t count = std::min(available, numBytes - done);
        std::memcpy(buffer + done, source, count);
        done += count;
    }
    return done;
}

void AchievementsService::ServerCall(const rc_api_request_t *request, rc_client_server_callback_t callback,
                                     void *callbackData, rc_client_t *client) {
    auto *self = Service(client);
    auto &bridge = ios::GetAchievementsBridge();
    if (self == nullptr || !bridge.http) {
        rc_api_server_response_t response{};
        response.http_status_code = RC_API_SERVER_RESPONSE_CLIENT_ERROR;
        response.body = "No network access";
        response.body_length = std::strlen(response.body);
        callback(&response, callbackData);
        return;
    }

    const std::string url = Str(request->url);
    const std::string postData = Str(request->post_data);
    const std::string contentType = Str(request->content_type);
    bridge.http(url, postData, contentType, [self, client, callback, callbackData](int status, std::string body) {
        std::lock_guard lock{self->m_mutex};
        if (self->m_client != client) {
            return; // the client is gone
        }
        rc_api_server_response_t response{};
        response.body = body.c_str();
        response.body_length = body.size();
        // A failure to connect (-1) is retried by rc_client
        response.http_status_code = status > 0 ? status : RC_API_SERVER_RESPONSE_RETRYABLE_CLIENT_ERROR;
        callback(&response, callbackData);
    });
}

void AchievementsService::LogMessage(const char *message, const rc_client_t *) {
    std::fprintf(stderr, "[rcheevos] %s\n", message != nullptr ? message : "");
}

void AchievementsService::LoginDone(int result, const char *errorMessage, rc_client_t *client, void *userdata) {
    auto *self = static_cast<AchievementsService *>(userdata);
    (void)client;

    std::function<void(bool, const std::string &)> done;
    ios::AchievementEvent event;
    {
        std::lock_guard lock{self->m_mutex};
        self->m_loggingIn = false;
        done = std::move(self->m_loginCallback);
        self->m_loginCallback = {};

        if (result == RC_OK) {
            self->m_message.clear();
            if (const rc_client_user_t *user = rc_client_get_user_info(self->m_client)) {
                // Keep the sign-in for the next time (the token, never the password)
                if (auto &bridge = ios::GetAchievementsBridge(); bridge.saveCredentials && user->token != nullptr) {
                    bridge.saveCredentials(Str(user->username), Str(user->token));
                }
                event.title = Str(user->display_name);
            }
            event.kind = ios::AchievementEvent::Kind::LoginSucceeded;
        } else {
            self->m_message = Str(errorMessage);
            if (self->m_message.empty()) {
                self->m_message = "Couldn't log in.";
            }
            event.kind = ios::AchievementEvent::Kind::LoginFailed;
            event.message = self->m_message;
            // A rejected stored token is no good any more
            if (result == RC_INVALID_CREDENTIALS || result == RC_EXPIRED_TOKEN || result == RC_ACCESS_DENIED) {
                if (auto &bridge = ios::GetAchievementsBridge(); bridge.clearCredentials && !done) {
                    bridge.clearCredentials();
                }
            }
        }
    }
    self->Emit(event);
    if (done) {
        done(result == RC_OK, event.message);
    }
}

void AchievementsService::LoadGameDone(int result, const char *errorMessage, rc_client_t *client, void *userdata) {
    auto *self = static_cast<AchievementsService *>(userdata);
    ios::AchievementEvent event;
    {
        std::lock_guard lock{self->m_mutex};
        self->m_gameLoading = false;
        if (result == RC_OK) {
            self->m_gameUnknown = false;
            event.kind = ios::AchievementEvent::Kind::GameLoaded;
            if (const rc_client_game_t *game = rc_client_get_game_info(client)) {
                event.title = Str(game->title);
                if (char url[256]; rc_client_game_get_image_url(game, url, sizeof(url)) == RC_OK) {
                    event.badgeUrl = url;
                }
            }
            rc_client_user_game_summary_t summary{};
            rc_client_get_user_game_summary(client, &summary);
            event.points = summary.points_core;
            event.id = summary.num_core_achievements;
            if (summary.num_core_achievements == 0) {
                event.message = "This game doesn't have any achievements yet";
            } else {
                event.message = "You have unlocked " + std::to_string(summary.num_unlocked_achievements) + " of " +
                                std::to_string(summary.num_core_achievements) + " achievements";
            }
        } else if (result == RC_NO_GAME_LOADED) {
            // The game isn't known to RetroAchievements
            self->m_gameUnknown = true;
            event.kind = ios::AchievementEvent::Kind::GameUnknown;
            event.message = "No achievements for this game: RetroAchievements doesn't know this disc";
        } else if (result == RC_ABORTED) {
            return;
        } else {
            event.kind = ios::AchievementEvent::Kind::Error;
            event.message = Str(errorMessage);
        }
    }
    self->Emit(event);
}

void AchievementsService::HandleEvent(const rc_client_event_t *event, rc_client_t *client) {
    auto *self = Service(client);
    if (self == nullptr) {
        return;
    }

    ios::AchievementEvent out;
    auto fillAchievement = [&](const rc_client_achievement_t *achievement) {
        if (achievement == nullptr) {
            return;
        }
        out.id = achievement->id;
        out.title = Str(achievement->title);
        out.description = Str(achievement->description);
        out.points = achievement->points;
        char url[256];
        if (rc_client_achievement_get_image_url(achievement, RC_CLIENT_ACHIEVEMENT_STATE_UNLOCKED, url, sizeof(url)) ==
            RC_OK) {
            out.badgeUrl = url;
        }
    };

    switch (event->type) {
    case RC_CLIENT_EVENT_ACHIEVEMENT_TRIGGERED:
        out.kind = ios::AchievementEvent::Kind::Unlocked;
        fillAchievement(event->achievement);
        break;
    case RC_CLIENT_EVENT_GAME_COMPLETED:
        out.kind = ios::AchievementEvent::Kind::GameCompleted;
        if (const rc_client_game_t *game = rc_client_get_game_info(client)) {
            out.title = Str(game->title);
        }
        break;
    case RC_CLIENT_EVENT_SERVER_ERROR:
        out.kind = ios::AchievementEvent::Kind::Error;
        if (event->server_error != nullptr) {
            out.message = Str(event->server_error->error_message);
        }
        break;
    case RC_CLIENT_EVENT_DISCONNECTED: out.kind = ios::AchievementEvent::Kind::Disconnected; break;
    case RC_CLIENT_EVENT_RECONNECTED: out.kind = ios::AchievementEvent::Kind::Reconnected; break;
    case RC_CLIENT_EVENT_ACHIEVEMENT_CHALLENGE_INDICATOR_SHOW:
        out.kind = ios::AchievementEvent::Kind::ChallengeShow;
        fillAchievement(event->achievement);
        break;
    case RC_CLIENT_EVENT_ACHIEVEMENT_CHALLENGE_INDICATOR_HIDE:
        out.kind = ios::AchievementEvent::Kind::ChallengeHide;
        fillAchievement(event->achievement);
        break;
    case RC_CLIENT_EVENT_ACHIEVEMENT_PROGRESS_INDICATOR_SHOW: [[fallthrough]];
    case RC_CLIENT_EVENT_ACHIEVEMENT_PROGRESS_INDICATOR_UPDATE:
        out.kind = ios::AchievementEvent::Kind::ProgressShow;
        fillAchievement(event->achievement);
        if (event->achievement != nullptr) {
            out.message = Str(event->achievement->measured_progress);
        }
        break;
    case RC_CLIENT_EVENT_LEADERBOARD_STARTED:
        out.kind = ios::AchievementEvent::Kind::LeaderboardStarted;
        if (event->leaderboard != nullptr) {
            out.title = Str(event->leaderboard->title);
            out.description = Str(event->leaderboard->description);
        }
        break;
    case RC_CLIENT_EVENT_LEADERBOARD_FAILED:
        out.kind = ios::AchievementEvent::Kind::LeaderboardFailed;
        if (event->leaderboard != nullptr) {
            out.title = Str(event->leaderboard->title);
        }
        break;
    case RC_CLIENT_EVENT_LEADERBOARD_SUBMITTED:
        out.kind = ios::AchievementEvent::Kind::LeaderboardSubmitted;
        if (event->leaderboard != nullptr) {
            out.title = Str(event->leaderboard->title);
        }
        if (event->leaderboard_scoreboard != nullptr) {
            out.message = Str(event->leaderboard_scoreboard->submitted_score);
        }
        break;
    case RC_CLIENT_EVENT_RESET:
        // Hardcore was turned on with a game running: the game starts over
        if (self->requestReset) {
            self->requestReset();
        }
        return;
    default: return;
    }
    self->Emit(out);
}

void AchievementsService::Emit(const ios::AchievementEvent &event) {
    if (auto &bridge = ios::GetAchievementsBridge(); bridge.event) {
        bridge.event(event);
    }
}

// -- What the user interface shows --

ios::AchievementsStatus AchievementsService::GetStatus() {
    std::lock_guard lock{m_mutex};
    ios::AchievementsStatus status;
    auto &bridge = ios::GetAchievementsBridge();
    status.enabled = bridge.enabled ? bridge.enabled() : false;
    status.hardcore = bridge.hardcore ? bridge.hardcore() : false;
    status.message = m_message;
    if (m_client == nullptr) {
        return status;
    }

    status.loggingIn = m_loggingIn;
    if (const rc_client_user_t *user = rc_client_get_user_info(m_client)) {
        status.loggedIn = true;
        status.username = Str(user->username);
        status.displayName = Str(user->display_name);
        status.score = user->score;
        status.softcoreScore = user->score_softcore;
        if (char url[256]; rc_client_user_get_image_url(user, url, sizeof(url)) == RC_OK) {
            status.avatarUrl = url;
        }
    }

    status.gameLoading = m_gameLoading;
    status.gameUnknown = m_gameUnknown;
    if (rc_client_is_game_loaded(m_client)) {
        if (const rc_client_game_t *game = rc_client_get_game_info(m_client); game != nullptr && game->id != 0) {
            status.gameLoaded = true;
            status.gameTitle = Str(game->title);
            if (char url[256]; rc_client_game_get_image_url(game, url, sizeof(url)) == RC_OK) {
                status.gameBadgeUrl = url;
            }
            rc_client_user_game_summary_t summary{};
            rc_client_get_user_game_summary(m_client, &summary);
            status.numAchievements = summary.num_core_achievements;
            status.numUnlocked = summary.num_unlocked_achievements;
            status.points = summary.points_core;
            status.pointsUnlocked = summary.points_unlocked;
        }
        status.hardcoreActive = rc_client_get_hardcore_enabled(m_client) != 0;
        if (rc_client_has_rich_presence(m_client)) {
            char text[256];
            if (rc_client_get_rich_presence_message(m_client, text, sizeof(text)) > 0) {
                status.richPresence = text;
            }
        }
    }
    return status;
}

std::vector<ios::AchievementEntry> AchievementsService::GetAchievements() {
    std::lock_guard lock{m_mutex};
    std::vector<ios::AchievementEntry> entries;
    if (m_client == nullptr || !rc_client_is_game_loaded(m_client)) {
        return entries;
    }

    rc_client_achievement_list_t *list = rc_client_create_achievement_list(
        m_client, RC_CLIENT_ACHIEVEMENT_CATEGORY_CORE_AND_UNOFFICIAL, RC_CLIENT_ACHIEVEMENT_LIST_GROUPING_LOCK_STATE);
    if (list == nullptr) {
        return entries;
    }
    for (uint32_t b = 0; b < list->num_buckets; ++b) {
        const rc_client_achievement_bucket_t &bucket = list->buckets[b];
        for (uint32_t i = 0; i < bucket.num_achievements; ++i) {
            const rc_client_achievement_t *achievement = bucket.achievements[i];
            ios::AchievementEntry entry;
            entry.id = achievement->id;
            entry.title = Str(achievement->title);
            entry.description = Str(achievement->description);
            entry.points = achievement->points;
            entry.unlocked = achievement->unlocked != RC_CLIENT_ACHIEVEMENT_UNLOCKED_NONE;
            entry.unlockedHardcore = (achievement->unlocked & RC_CLIENT_ACHIEVEMENT_UNLOCKED_HARDCORE) != 0;
            entry.unsupported = bucket.bucket_type == RC_CLIENT_ACHIEVEMENT_BUCKET_UNSUPPORTED;
            entry.unofficial = bucket.bucket_type == RC_CLIENT_ACHIEVEMENT_BUCKET_UNOFFICIAL;
            entry.progress = Str(achievement->measured_progress);
            entry.progressPercent = achievement->measured_percent;
            entry.unlockTime = achievement->unlock_time;
            char url[256];
            if (rc_client_achievement_get_image_url(achievement, RC_CLIENT_ACHIEVEMENT_STATE_UNLOCKED, url,
                                                    sizeof(url)) == RC_OK) {
                entry.badgeUrl = url;
            }
            if (rc_client_achievement_get_image_url(achievement, RC_CLIENT_ACHIEVEMENT_STATE_ACTIVE, url,
                                                    sizeof(url)) == RC_OK) {
                entry.badgeLockedUrl = url;
            }
            entries.push_back(std::move(entry));
        }
    }
    rc_client_destroy_achievement_list(list);
    return entries;
}

} // namespace app::services
