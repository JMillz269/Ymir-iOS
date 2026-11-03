#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// Objective-C facade over the emulator frontend, used by the Swift user interface.
/// All methods must be called from the main thread.
@interface YmirHost : NSObject

/// The UIWindow that hosts the emulator's SDL view, or nil before the emulator window exists.
@property(class, nonatomic, weak, nullable) UIWindow *gameWindow;

/// Whether the emulator frontend is up and accepting commands.
@property(class, nonatomic, readonly) BOOL isRunning;
@property(class, nonatomic, readonly) BOOL isDiscLoaded;
@property(class, nonatomic, readonly) BOOL hasBIOS;
@property(class, nonatomic, readonly) NSString *biosName;
@property(class, nonatomic, readonly, nullable) NSString *loadedGamePath;
@property(class, nonatomic, readonly) NSString *documentsPath;

/// Whether the process can obtain executable memory for the recompiler (JIT), and a short explanation for the user.
/// Re-evaluated on every access: it changes once a JIT enabler attaches to the app.
@property(class, nonatomic, readonly) BOOL jitAvailable;
@property(class, nonatomic, readonly) NSString *jitStatus;
/// Counters of the recompiler (blocks compiled, cache flushes, ...), for diagnosing slowdowns.
@property(class, nonatomic, readonly) NSString *jitReport;

@property(class, nonatomic) BOOL paused;
@property(class, nonatomic) BOOL fastForward;

+ (void)launchGameAtPath:(NSString *)path NS_SWIFT_NAME(launchGame(path:));
/// Launches a game and loads the save state of one of its slots once it is up.
+ (void)launchGameAtPath:(NSString *)path loadStateFromSlot:(NSInteger)slot NS_SWIFT_NAME(launchGame(path:loadSlot:));
+ (void)softReset NS_SWIFT_NAME(softReset());
+ (void)hardReset NS_SWIFT_NAME(hardReset());
+ (void)openCloseTray NS_SWIFT_NAME(openCloseTray());
+ (void)ejectDisc NS_SWIFT_NAME(ejectDisc());
+ (void)saveStateToSlot:(NSInteger)slot NS_SWIFT_NAME(saveState(slot:));
/// Saves a state of the loaded game into the autosave slot, unless the player turned that off. The completion block is
/// called on another thread when it's written, or at once if there was nothing to save.
+ (void)autoSaveWithCompletion:(nullable void (^)(void))completion NS_SWIFT_NAME(autoSave(completion:));
+ (void)loadStateFromSlot:(NSInteger)slot NS_SWIFT_NAME(loadState(slot:));
+ (void)deleteStateInSlot:(NSInteger)slot NS_SWIFT_NAME(deleteState(slot:));
/// The file holding the save state of a slot of the loaded game, or nil if there is none.
+ (nullable NSString *)pathForSaveStateSlot:(NSInteger)slot NS_SWIFT_NAME(saveStatePath(slot:));
+ (void)quitGame NS_SWIFT_NAME(quitGame());
+ (void)takeScreenshot NS_SWIFT_NAME(takeScreenshot());

/// Whether this build can convert disc images to CHD files.
@property(class, nonatomic, readonly) BOOL chdConversionAvailable;

/// Converts a disc image (CUE, ISO, CCD, MDS) to a CHD file, on a background thread; the emulator isn't involved and may
/// be running. `progress` is called from that thread with the steps done and their total (converting, then checking the
/// new file); returning NO cancels. `completion` is called from that thread when it's over: `status` is 0 when it worked,
/// 1 when it was cancelled and 2 when it failed (`message` says why), with the size of the CHD file and of the disc data
/// it holds. A file that was started is removed again if the conversion doesn't succeed.
+ (void)convertDiscImageAtPath:(NSString *)source
                   toCHDAtPath:(NSString *)destination
              compressionLevel:(NSInteger)level
                      progress:(BOOL (^)(uint64_t done, uint64_t total))progress
                    completion:(void (^)(NSInteger status, NSString *message, uint64_t outputBytes,
                                         uint64_t rawBytes))completion
    NS_SWIFT_NAME(convertDiscImage(at:toCHDAt:level:progress:completion:));

/// Rescans the BIOS folder and loads an IPL ROM. Returns an error message, or nil on success.
+ (nullable NSString *)reloadBIOS NS_SWIFT_NAME(reloadBIOS());

/// The BIOS images in the BIOS folder: dictionaries with "path", "name" (the file name), "detail" and "selected".
+ (NSArray<NSDictionary<NSString *, id> *> *)biosList NS_SWIFT_NAME(biosList());
/// Whether the emulator picks the BIOS itself (by the region of the game) instead of the user's choice.
@property(class, nonatomic, readonly) BOOL biosIsAutomatic;
/// Uses this BIOS image (nil: let the emulator pick), reloads it and restarts the system.
/// Returns an error message, or nil on success.
+ (nullable NSString *)selectBIOSAtPath:(nullable NSString *)path NS_SWIFT_NAME(selectBIOS(path:));

/// Returns an array of dictionaries with keys "index" (NSNumber), "present" (NSNumber) and "text" (NSString).
+ (NSArray<NSDictionary<NSString *, id> *> *)saveSlots NS_SWIFT_NAME(saveSlots());

+ (BOOL)boolForKey:(NSString *)key defaultValue:(BOOL)defaultValue NS_SWIFT_NAME(boolValue(key:default:));
+ (void)setBool:(BOOL)value forKey:(NSString *)key NS_SWIFT_NAME(setBoolValue(_:key:));
+ (NSString *)pathForKey:(NSString *)key NS_SWIFT_NAME(pathValue(key:));
+ (void)setPath:(NSString *)path forKey:(NSString *)key NS_SWIFT_NAME(setPathValue(_:key:));
+ (NSInteger)intForKey:(NSString *)key defaultValue:(NSInteger)defaultValue NS_SWIFT_NAME(intValue(key:default:));
+ (void)setInt:(NSInteger)value forKey:(NSString *)key NS_SWIFT_NAME(setIntValue(_:key:));
+ (float)floatForKey:(NSString *)key defaultValue:(float)defaultValue NS_SWIFT_NAME(floatValue(key:default:));
+ (void)setFloat:(float)value forKey:(NSString *)key NS_SWIFT_NAME(setFloatValue(_:key:));

@end

/// RetroAchievements. The settings are kept by the app; the emulator side (rc_client) is set up when the emulator starts.
@interface YmirHost (Achievements)

/// Whether the achievements service of the emulator is up.
@property(class, nonatomic, readonly) BOOL achievementsAvailable;
@property(class, nonatomic) BOOL achievementsEnabled;
/// Hardcore mode: no loading of save states, no rewinding (turning it on with a game running restarts the game).
@property(class, nonatomic) BOOL achievementsHardcore;

/// What there is to show about the user, the loaded game and the progress (see AchievementsStatus in host_interface.hpp).
+ (NSDictionary<NSString *, id> *)achievementsStatus NS_SWIFT_NAME(achievementsStatus());
/// The achievements of the loaded game, as dictionaries (see AchievementEntry in host_interface.hpp).
+ (NSArray<NSDictionary<NSString *, id> *> *)achievementsList NS_SWIFT_NAME(achievementsList());

+ (void)achievementsLoginWithUser:(NSString *)user
                         password:(NSString *)password
                       completion:(void (^)(BOOL success, NSString *message))completion
    NS_SWIFT_NAME(achievementsLogin(user:password:completion:));
+ (void)achievementsLogout NS_SWIFT_NAME(achievementsLogout());

/// Receives what happens (an achievement unlocked, the game identified, problems...), on the main thread. A dictionary
/// with "kind", "title", "description", "badgeUrl", "message", "points" and "id".
+ (void)setAchievementsEventHandler:(nullable void (^)(NSDictionary<NSString *, id> *))handler
    NS_SWIFT_NAME(setAchievementsEventHandler(_:));

@end

NS_ASSUME_NONNULL_END
