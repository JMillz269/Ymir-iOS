#import "YmirHost.h"

#import <Foundation/Foundation.h>
#import <Security/Security.h>

#include <app/ios/host_interface.hpp>

#include <functional>
#include <memory>
#include <string>

// RetroAchievements: the side of it that lives in the user interface layer: the network, the stored sign-in, the
// settings and the events. The achievements themselves are handled by app::services::AchievementsService.

static NSString *const kEnabledKey = @"ymir.ra.enabled";
static NSString *const kHardcoreKey = @"ymir.ra.hardcore";
static NSString *const kUserKey = @"ymir.ra.user";
static NSString *const kKeychainService = @"io.github.jmillz269.ymir.retroachievements";

static void (^s_eventHandler)(NSDictionary<NSString *, id> *) = nil;

static NSString *NS(const std::string &text) {
    NSString *result = [NSString stringWithUTF8String:text.c_str()];
    return result != nil ? result : @"";
}

// -- Keychain (the token the server gives at login; the password is never kept) --

static NSDictionary *KeychainQuery(NSString *account) {
    return @{
        (__bridge id)kSecClass : (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecAttrService : kKeychainService,
        (__bridge id)kSecAttrAccount : account,
    };
}

static void SaveToken(NSString *user, NSString *token) {
    NSMutableDictionary *query = [KeychainQuery(user) mutableCopy];
    SecItemDelete((__bridge CFDictionaryRef)query);
    query[(__bridge id)kSecValueData] = [token dataUsingEncoding:NSUTF8StringEncoding];
    query[(__bridge id)kSecAttrAccessible] = (__bridge id)kSecAttrAccessibleAfterFirstUnlock;
    SecItemAdd((__bridge CFDictionaryRef)query, nullptr);
}

static NSString *LoadToken(NSString *user) {
    NSMutableDictionary *query = [KeychainQuery(user) mutableCopy];
    query[(__bridge id)kSecReturnData] = @YES;
    query[(__bridge id)kSecMatchLimit] = (__bridge id)kSecMatchLimitOne;
    CFTypeRef result = nullptr;
    if (SecItemCopyMatching((__bridge CFDictionaryRef)query, &result) != errSecSuccess || result == nullptr) {
        return nil;
    }
    NSData *data = (__bridge_transfer NSData *)result;
    return [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
}

static void DeleteToken(NSString *user) {
    SecItemDelete((__bridge CFDictionaryRef)KeychainQuery(user));
}

// -- Conversions for the Swift side --

static NSString *KindName(app::ios::AchievementEvent::Kind kind) {
    using Kind = app::ios::AchievementEvent::Kind;
    switch (kind) {
    case Kind::Unlocked: return @"unlocked";
    case Kind::GameLoaded: return @"gameLoaded";
    case Kind::GameUnknown: return @"gameUnknown";
    case Kind::GameCompleted: return @"gameCompleted";
    case Kind::LoginSucceeded: return @"loginSucceeded";
    case Kind::LoginFailed: return @"loginFailed";
    case Kind::Error: return @"error";
    case Kind::Disconnected: return @"disconnected";
    case Kind::Reconnected: return @"reconnected";
    case Kind::ChallengeShow: return @"challengeShow";
    case Kind::ChallengeHide: return @"challengeHide";
    case Kind::ProgressShow: return @"progressShow";
    case Kind::LeaderboardStarted: return @"leaderboardStarted";
    case Kind::LeaderboardFailed: return @"leaderboardFailed";
    case Kind::LeaderboardSubmitted: return @"leaderboardSubmitted";
    }
    return @"error";
}

static void InstallBridge() {
    auto &bridge = app::ios::GetAchievementsBridge();

    bridge.enabled = [] { return [[NSUserDefaults standardUserDefaults] boolForKey:kEnabledKey]; };
    bridge.hardcore = [] { return [[NSUserDefaults standardUserDefaults] boolForKey:kHardcoreKey]; };

    bridge.loadCredentials = [](std::string &user, std::string &token) {
        NSString *name = [[NSUserDefaults standardUserDefaults] stringForKey:kUserKey];
        if (name.length == 0) {
            return false;
        }
        NSString *stored = LoadToken(name);
        if (stored.length == 0) {
            return false;
        }
        user = name.UTF8String;
        token = stored.UTF8String;
        return true;
    };
    bridge.saveCredentials = [](const std::string &user, const std::string &token) {
        NSString *name = NS(user);
        [[NSUserDefaults standardUserDefaults] setObject:name forKey:kUserKey];
        SaveToken(name, NS(token));
    };
    bridge.clearCredentials = [] {
        NSString *name = [[NSUserDefaults standardUserDefaults] stringForKey:kUserKey];
        if (name.length > 0) {
            DeleteToken(name);
        }
        [[NSUserDefaults standardUserDefaults] removeObjectForKey:kUserKey];
    };

    // The server calls. One session for all of them; rc_client makes them one or a few at a time.
    static NSURLSession *session = [] {
        NSURLSessionConfiguration *config = [NSURLSessionConfiguration ephemeralSessionConfiguration];
        config.timeoutIntervalForRequest = 30;
        config.waitsForConnectivity = NO;
        return [NSURLSession sessionWithConfiguration:config];
    }();
    bridge.http = [](const std::string &url, const std::string &postData, const std::string &contentType,
                     std::function<void(int, std::string)> done) {
        NSURL *target = [NSURL URLWithString:NS(url)];
        if (target == nil) {
            done(-1, "");
            return;
        }
        NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:target];
        [request setValue:@"Ymir-iOS rcheevos/12" forHTTPHeaderField:@"User-Agent"];
        if (!postData.empty()) {
            request.HTTPMethod = @"POST";
            request.HTTPBody = [NSData dataWithBytes:postData.data() length:postData.size()];
            [request setValue:(contentType.empty() ? @"application/x-www-form-urlencoded" : NS(contentType))
                forHTTPHeaderField:@"Content-Type"];
        }
        auto callback = std::make_shared<std::function<void(int, std::string)>>(std::move(done));
        NSURLSessionDataTask *task = [session
            dataTaskWithRequest:request
              completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
                  int status = -1;
                  if ([response isKindOfClass:[NSHTTPURLResponse class]]) {
                      status = (int)((NSHTTPURLResponse *)response).statusCode;
                  }
                  std::string body;
                  if (data.length > 0) {
                      body.assign(static_cast<const char *>(data.bytes), data.length);
                  }
                  (*callback)(error != nil && status <= 0 ? -1 : status, std::move(body));
              }];
        [task resume];
    };

    bridge.event = [](const app::ios::AchievementEvent &event) {
        NSDictionary *info = @{
            @"kind" : KindName(event.kind),
            @"title" : NS(event.title),
            @"description" : NS(event.description),
            @"badgeUrl" : NS(event.badgeUrl),
            @"message" : NS(event.message),
            @"points" : @(event.points),
            @"id" : @(event.id),
        };
        dispatch_async(dispatch_get_main_queue(), ^{
            if (s_eventHandler != nil) {
                s_eventHandler(info);
            }
        });
    };
}

// Called when the class is loaded, before the emulator starts and asks for the settings and the stored sign-in
void YmirInstallAchievementsBridge(void) {
    InstallBridge();
}

@implementation YmirHost (Achievements)

+ (BOOL)achievementsAvailable {
    return app::ios::GetAchievementsBridge().status != nullptr;
}

+ (BOOL)achievementsEnabled {
    return [[NSUserDefaults standardUserDefaults] boolForKey:kEnabledKey];
}

+ (void)setAchievementsEnabled:(BOOL)enabled {
    [[NSUserDefaults standardUserDefaults] setBool:enabled forKey:kEnabledKey];
    auto &bridge = app::ios::GetAchievementsBridge();
    if (bridge.settingsChanged) {
        bridge.settingsChanged();
    }
}

+ (BOOL)achievementsHardcore {
    return [[NSUserDefaults standardUserDefaults] boolForKey:kHardcoreKey];
}

+ (void)setAchievementsHardcore:(BOOL)hardcore {
    [[NSUserDefaults standardUserDefaults] setBool:hardcore forKey:kHardcoreKey];
    auto &bridge = app::ios::GetAchievementsBridge();
    if (bridge.settingsChanged) {
        bridge.settingsChanged();
    }
}

+ (NSDictionary<NSString *, id> *)achievementsStatus {
    auto &bridge = app::ios::GetAchievementsBridge();
    app::ios::AchievementsStatus status;
    if (bridge.status) {
        status = bridge.status();
    } else {
        status.enabled = [self achievementsEnabled];
        status.hardcore = [self achievementsHardcore];
    }
    return @{
        @"enabled" : @(status.enabled),
        @"hardcore" : @(status.hardcore),
        @"loggingIn" : @(status.loggingIn),
        @"loggedIn" : @(status.loggedIn),
        @"gameLoading" : @(status.gameLoading),
        @"gameLoaded" : @(status.gameLoaded),
        @"gameUnknown" : @(status.gameUnknown),
        @"hardcoreActive" : @(status.hardcoreActive),
        @"username" : NS(status.username),
        @"displayName" : NS(status.displayName),
        @"avatarUrl" : NS(status.avatarUrl),
        @"score" : @(status.score),
        @"softcoreScore" : @(status.softcoreScore),
        @"gameTitle" : NS(status.gameTitle),
        @"gameBadgeUrl" : NS(status.gameBadgeUrl),
        @"numAchievements" : @(status.numAchievements),
        @"numUnlocked" : @(status.numUnlocked),
        @"points" : @(status.points),
        @"pointsUnlocked" : @(status.pointsUnlocked),
        @"richPresence" : NS(status.richPresence),
        @"message" : NS(status.message),
    };
}

+ (NSArray<NSDictionary<NSString *, id> *> *)achievementsList {
    auto &bridge = app::ios::GetAchievementsBridge();
    NSMutableArray *result = [NSMutableArray array];
    if (!bridge.achievements) {
        return result;
    }
    for (const auto &entry : bridge.achievements()) {
        [result addObject:@{
            @"id" : @(entry.id),
            @"title" : NS(entry.title),
            @"description" : NS(entry.description),
            @"badgeUrl" : NS(entry.badgeUrl),
            @"badgeLockedUrl" : NS(entry.badgeLockedUrl),
            @"points" : @(entry.points),
            @"unlocked" : @(entry.unlocked),
            @"unlockedHardcore" : @(entry.unlockedHardcore),
            @"unsupported" : @(entry.unsupported),
            @"unofficial" : @(entry.unofficial),
            @"progress" : NS(entry.progress),
            @"progressPercent" : @(entry.progressPercent),
            @"unlockTime" : @((double)entry.unlockTime),
        }];
    }
    return result;
}

+ (void)achievementsLoginWithUser:(NSString *)user
                         password:(NSString *)password
                       completion:(void (^)(BOOL, NSString *))completion {
    auto &bridge = app::ios::GetAchievementsBridge();
    void (^done)(BOOL, NSString *) = [completion copy];
    if (!bridge.login) {
        if (done != nil) {
            done(NO, @"Start a game once first: the achievements are set up with the emulator.");
        }
        return;
    }
    bridge.login(user.UTF8String, password.UTF8String, [done](bool ok, const std::string &message) {
        NSString *text = NS(message);
        dispatch_async(dispatch_get_main_queue(), ^{
            if (done != nil) {
                done(ok, text);
            }
        });
    });
}

+ (void)achievementsLogout {
    auto &bridge = app::ios::GetAchievementsBridge();
    if (bridge.logout) {
        bridge.logout();
    } else {
        // (the emulator isn't up yet: just forget the sign-in)
        if (bridge.clearCredentials) {
            bridge.clearCredentials();
        }
    }
}

+ (void)setAchievementsEventHandler:(void (^)(NSDictionary<NSString *, id> *))handler {
    s_eventHandler = [handler copy];
}

@end
