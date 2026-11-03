import SwiftUI
import UIKit

// MARK: - State

/// What RetroAchievements has to show: the user, the game that is loaded, and the progress.
struct AchievementsState: Equatable {
    var enabled = false
    var hardcore = false
    var loggingIn = false
    var loggedIn = false
    var gameLoading = false
    var gameLoaded = false
    var gameUnknown = false
    var hardcoreActive = false
    var username = ""
    var displayName = ""
    var avatarURL: URL?
    var score = 0
    var gameTitle = ""
    var gameBadgeURL: URL?
    var numAchievements = 0
    var numUnlocked = 0
    var points = 0
    var pointsUnlocked = 0
    var richPresence = ""
    var message = ""

    init() {}

    init(_ dict: [String: Any]) {
        func flag(_ key: String) -> Bool { (dict[key] as? NSNumber)?.boolValue ?? false }
        func number(_ key: String) -> Int { (dict[key] as? NSNumber)?.intValue ?? 0 }
        func text(_ key: String) -> String { dict[key] as? String ?? "" }
        enabled = flag("enabled")
        hardcore = flag("hardcore")
        loggingIn = flag("loggingIn")
        loggedIn = flag("loggedIn")
        gameLoading = flag("gameLoading")
        gameLoaded = flag("gameLoaded")
        gameUnknown = flag("gameUnknown")
        hardcoreActive = flag("hardcoreActive")
        username = text("username")
        displayName = text("displayName")
        avatarURL = URL(string: text("avatarUrl"))
        score = number("score")
        gameTitle = text("gameTitle")
        gameBadgeURL = URL(string: text("gameBadgeUrl"))
        numAchievements = number("numAchievements")
        numUnlocked = number("numUnlocked")
        points = number("points")
        pointsUnlocked = number("pointsUnlocked")
        richPresence = text("richPresence")
        message = text("message")
    }
}

/// One achievement of the game.
struct AchievementItem: Identifiable, Equatable {
    let id: Int
    let title: String
    let detail: String
    let badgeURL: URL?
    let lockedBadgeURL: URL?
    let points: Int
    let unlocked: Bool
    let hardcore: Bool
    let unsupported: Bool
    let unofficial: Bool
    let progress: String
    let progressFraction: Double
    let unlockTime: Date?

    init(_ dict: [String: Any]) {
        id = (dict["id"] as? NSNumber)?.intValue ?? 0
        title = dict["title"] as? String ?? ""
        detail = dict["description"] as? String ?? ""
        badgeURL = URL(string: dict["badgeUrl"] as? String ?? "")
        lockedBadgeURL = URL(string: dict["badgeLockedUrl"] as? String ?? "")
        points = (dict["points"] as? NSNumber)?.intValue ?? 0
        unlocked = (dict["unlocked"] as? NSNumber)?.boolValue ?? false
        hardcore = (dict["unlockedHardcore"] as? NSNumber)?.boolValue ?? false
        unsupported = (dict["unsupported"] as? NSNumber)?.boolValue ?? false
        unofficial = (dict["unofficial"] as? NSNumber)?.boolValue ?? false
        progress = dict["progress"] as? String ?? ""
        progressFraction = ((dict["progressPercent"] as? NSNumber)?.doubleValue ?? 0) / 100
        let time = (dict["unlockTime"] as? NSNumber)?.doubleValue ?? 0
        unlockTime = time > 0 ? Date(timeIntervalSince1970: time) : nil
    }
}

/// A message shown over the game for a few seconds.
struct AchievementToast: Identifiable, Equatable {
    enum Style {
        case unlocked
        case info
        case problem
    }

    let id = UUID()
    let style: Style
    let title: String
    let subtitle: String
    let badgeURL: URL?
}

// MARK: - Model

@MainActor
final class AchievementsModel: ObservableObject {
    static let shared = AchievementsModel()

    @Published private(set) var state = AchievementsState()
    @Published private(set) var items: [AchievementItem] = []
    @Published private(set) var toast: AchievementToast?

    private var queue: [AchievementToast] = []
    private var started = false
    private var toastWindow: UIWindow?

    /// Hardcore mode is on with the achievements: states of a game can't be loaded.
    static var hardcoreLocksStates: Bool {
        YmirHost.achievementsEnabled && YmirHost.achievementsHardcore
    }

    /// Starts listening to what the emulator reports. Safe to call again.
    func start() {
        guard !started else { return }
        started = true
        Self.install(self)
        refresh()
    }

    /// (made outside of the main actor on purpose: the block is called by Objective-C code, which hops to the main
    /// thread itself)
    nonisolated private static func install(_ model: AchievementsModel) {
        YmirHost.setAchievementsEventHandler { info in
            Task { @MainActor in model.handle(info) }
        }
    }

    func refresh() {
        let new = AchievementsState(YmirHost.achievementsStatus())
        if new != state {
            state = new
        }
    }

    func refreshItems() {
        refresh()
        let list = YmirHost.achievementsList().map(AchievementItem.init)
        if list != items {
            items = list
        }
    }

    private func handle(_ info: [String: Any]) {
        let kind = info["kind"] as? String ?? ""
        let title = info["title"] as? String ?? ""
        let detail = info["description"] as? String ?? ""
        let message = info["message"] as? String ?? ""
        let points = (info["points"] as? NSNumber)?.intValue ?? 0
        let badge = URL(string: info["badgeUrl"] as? String ?? "")
        refresh()

        switch kind {
        case "unlocked":
            enqueue(AchievementToast(style: .unlocked, title: title,
                                     subtitle: "\(detail)\n\(points) point\(points == 1 ? "" : "s")", badgeURL: badge))
        case "gameLoaded":
            enqueue(AchievementToast(style: .info, title: title, subtitle: message, badgeURL: badge))
        case "gameCompleted":
            enqueue(AchievementToast(style: .info, title: "Game Completed", subtitle: title, badgeURL: nil))
        case "loginSucceeded":
            enqueue(AchievementToast(style: .info, title: "Welcome, \(title)",
                                     subtitle: "Connected to RetroAchievements", badgeURL: nil))
        case "loginFailed", "error":
            if !message.isEmpty {
                enqueue(AchievementToast(style: .problem, title: "RetroAchievements", subtitle: message, badgeURL: nil))
            }
        case "disconnected":
            enqueue(AchievementToast(style: .problem, title: "Connection Lost",
                                     subtitle: "Unlocks are kept and sent when you're back online", badgeURL: nil))
        case "reconnected":
            enqueue(AchievementToast(style: .info, title: "Connected Again",
                                     subtitle: "Pending unlocks were sent", badgeURL: nil))
        case "leaderboardStarted":
            enqueue(AchievementToast(style: .info, title: "Leaderboard Started", subtitle: title, badgeURL: nil))
        case "leaderboardFailed":
            enqueue(AchievementToast(style: .problem, title: "Leaderboard Failed", subtitle: title, badgeURL: nil))
        case "leaderboardSubmitted":
            enqueue(AchievementToast(style: .info, title: "Score Submitted", subtitle: "\(title) \(message)",
                                     badgeURL: nil))
        default:
            break
        }
    }

    // MARK: Toasts

    private func enqueue(_ toast: AchievementToast) {
        queue.append(toast)
        showNext()
    }

    private func showNext() {
        guard toast == nil, !queue.isEmpty else { return }
        let next = queue.removeFirst()
        presentWindow()
        withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
            toast = next
        }
        let seconds: Double = next.style == .unlocked ? 5 : 3.5
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            guard let self, self.toast?.id == next.id else { return }
            withAnimation(.easeInOut(duration: 0.3)) {
                self.toast = nil
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
                self?.showNext()
            }
        }
    }

    /// A window of its own above everything, that lets every touch through to what is below.
    private func presentWindow() {
        guard toastWindow == nil,
              let scene = YmirHost.gameWindow?.windowScene
                ?? UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first else { return }
        let window = UIWindow(windowScene: scene)
        window.windowLevel = .alert + 1
        window.backgroundColor = .clear
        window.isUserInteractionEnabled = false
        let host = UIHostingController(rootView: AchievementToastHost(model: self))
        host.view.backgroundColor = .clear
        window.rootViewController = host
        window.isHidden = false
        toastWindow = window
    }
}

// MARK: - Toast

private struct AchievementToastHost: View {
    @ObservedObject var model: AchievementsModel

    var body: some View {
        VStack {
            if let toast = model.toast {
                AchievementToastView(toast: toast)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .padding(.top, 8)
                    .padding(.horizontal, 16)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .allowsHitTesting(false)
    }
}

private struct AchievementToastView: View {
    let toast: AchievementToast

    var body: some View {
        HStack(spacing: 12) {
            if toast.style == .unlocked || toast.badgeURL != nil {
                BadgeImage(url: toast.badgeURL, size: 48)
            } else {
                Image(systemName: toast.style == .problem ? "exclamationmark.triangle.fill" : "trophy.fill")
                    .font(.title2)
                    .foregroundStyle(toast.style == .problem ? Color.orange : Color.yellow)
                    .frame(width: 48, height: 48)
            }
            VStack(alignment: .leading, spacing: 2) {
                if toast.style == .unlocked {
                    Text("Achievement Unlocked")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.yellow)
                }
                Text(toast.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                if !toast.subtitle.isEmpty {
                    Text(toast.subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: 420, alignment: .leading)
        .ymirGlass(in: RoundedRectangle(cornerRadius: 22, style: .continuous), interactive: false)
    }
}

// MARK: - Pieces

/// A badge or a profile picture from RetroAchievements.
struct BadgeImage: View {
    let url: URL?
    var size: CGFloat = 48
    var dimmed = false

    var body: some View {
        AsyncImage(url: url) { phase in
            switch phase {
            case .success(let image):
                image.resizable().scaledToFill()
            default:
                ZStack {
                    Color.secondary.opacity(0.2)
                    Image(systemName: "trophy.fill").foregroundStyle(.secondary)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.2, style: .continuous))
        .saturation(dimmed ? 0 : 1)
        .opacity(dimmed ? 0.6 : 1)
    }
}

// MARK: - Settings

/// Settings > Achievements
struct AchievementsSettingsView: View {
    @ObservedObject private var model = AchievementsModel.shared
    // (the app's own preferences, which the emulator side reads too: the switches show what is stored, and the home of the
    // settings is refreshed when they change)
    @AppStorage("ymir.ra.enabled") private var enabled = false
    @AppStorage("ymir.ra.hardcore") private var hardcore = false
    @State private var username = ""
    @State private var password = ""
    @State private var loginError: String?
    @State private var working = false
    private let timer = Timer.publish(every: 1.5, on: .main, in: .common).autoconnect()

    private var state: AchievementsState { model.state }

    private func login() {
        guard !username.isEmpty, !password.isEmpty else { return }
        working = true
        loginError = nil
        YmirHost.achievementsLogin(user: username, password: password) { success, message in
            working = false
            if success {
                password = ""
                username = ""
            } else {
                loginError = message.isEmpty ? "Couldn't log in." : message
            }
            model.refresh()
        }
    }

    var body: some View {
        GlassForm {
            GlassSection(content: {
                Toggle("RetroAchievements", isOn: $enabled)
                    .onChange(of: enabled) { _ in
                        // (tells the service; the value is already stored)
                        YmirHost.achievementsEnabled = enabled
                        model.refresh()
                    }
            }, footer: {
                WrappedText("Earn achievements in your games and keep track of them on retroachievements.org. You need a free account there. Achievements are only tracked while this is on.")
            })

            if enabled {
                if state.loggedIn {
                    GlassSection(content: {
                        HStack(spacing: 12) {
                            BadgeImage(url: state.avatarURL, size: 44)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(state.displayName.isEmpty ? state.username : state.displayName)
                                    .font(.headline)
                                Text("\(state.score) points")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Button(role: .destructive) {
                            YmirHost.achievementsLogout()
                            model.refresh()
                        } label: {
                            Text("Log Out")
                                .foregroundStyle(.red)
                        }
                        .buttonStyle(.plain)
                    }, header: {
                        Text("Account")
                    })
                } else {
                    GlassSection(content: {
                        TextField("User Name", text: $username)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        SecureField("Password", text: $password)
                        Button {
                            login()
                        } label: {
                            HStack {
                                Text(working || state.loggingIn ? "Logging In…" : "Log In")
                                if working || state.loggingIn {
                                    ProgressView()
                                }
                            }
                        }
                        .disabled(working || username.isEmpty || password.isEmpty)
                        if let loginError {
                            Text(loginError)
                                .font(.footnote)
                                .foregroundStyle(.red)
                        }
                    }, header: {
                        Text("Account")
                    }, footer: {
                        WrappedText("Your password is only sent to RetroAchievements, once. Ymir keeps the token they give back in the iOS keychain, not the password.")
                    })
                }

                GlassSection(content: {
                    Toggle("Hardcore Mode", isOn: $hardcore)
                        .onChange(of: hardcore) { _ in
                            YmirHost.achievementsHardcore = hardcore
                            model.refresh()
                        }
                }, footer: {
                    WrappedText("The way achievements are meant to be earned, and worth more on the site: loading save states and rewinding are turned off (saving still works). Turning it on while a game is running restarts the game.")
                })

                if state.gameLoading {
                    GlassSection(content: {
                        HStack {
                            ProgressView()
                            Text("Looking up the game…")
                        }
                    }, header: {
                        Text("Current Game")
                    })
                } else if state.gameLoaded {
                    GlassSection(content: {
                        HStack(spacing: 12) {
                            BadgeImage(url: state.gameBadgeURL, size: 44)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(state.gameTitle).font(.headline)
                                Text("\(state.numUnlocked) of \(state.numAchievements) achievements · \(state.pointsUnlocked) of \(state.points) points")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        if !state.richPresence.isEmpty {
                            Text(state.richPresence)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        NavigationLink {
                            GameAchievementsView()
                        } label: {
                            Label("Show the Achievements", systemImage: "trophy")
                        }
                    }, header: {
                        Text("Current Game")
                    })
                } else if state.gameUnknown {
                    GlassSection(content: {
                        Text("RetroAchievements doesn't know this game.")
                            .foregroundStyle(.secondary)
                    }, header: {
                        Text("Current Game")
                    })
                } else if !state.loggedIn {
                    GlassSection(content: {
                        Text("Log in, then start a game.")
                            .foregroundStyle(.secondary)
                    }, header: {
                        Text("Current Game")
                    })
                } else {
                    GlassSection(content: {
                        Text("Start a game to see its achievements.")
                            .foregroundStyle(.secondary)
                    }, header: {
                        Text("Current Game")
                    })
                }

                if !state.message.isEmpty && !state.loggedIn {
                    GlassSection(content: {
                        Text(state.message)
                            .font(.footnote)
                            .foregroundStyle(.orange)
                    })
                }
            }
        }
        .navigationTitle("Achievements")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            model.start()
            model.refresh()
        }
        .onReceive(timer) { _ in model.refresh() }
    }
}

// MARK: - The achievements of the game

/// The achievements of the game that is loaded, locked and unlocked.
struct GameAchievementsView: View {
    @ObservedObject private var model = AchievementsModel.shared
    private let timer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    private var unlocked: [AchievementItem] { model.items.filter { $0.unlocked } }
    private var locked: [AchievementItem] { model.items.filter { !$0.unlocked && !$0.unsupported && !$0.unofficial } }
    private var other: [AchievementItem] { model.items.filter { !$0.unlocked && ($0.unsupported || $0.unofficial) } }

    var body: some View {
        GlassForm {
            GlassSection(content: {
                VStack(alignment: .leading, spacing: 8) {
                    Text(model.state.gameTitle).font(.headline)
                    ProgressView(value: Double(model.state.numUnlocked), total: Double(max(1, model.state.numAchievements)))
                    Text("\(model.state.numUnlocked) of \(model.state.numAchievements) achievements · \(model.state.pointsUnlocked) of \(model.state.points) points")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            })

            if !unlocked.isEmpty {
                section("Unlocked", unlocked)
            }
            if !locked.isEmpty {
                section("Locked", locked)
            }
            if !other.isEmpty {
                section("Not Available", other)
            }
            if model.items.isEmpty {
                GlassSection(content: {
                    Text("No achievements to show.")
                        .foregroundStyle(.secondary)
                })
            }
        }
        .navigationTitle("Achievements")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { model.refreshItems() }
        .onReceive(timer) { _ in model.refreshItems() }
    }

    private func section(_ title: String, _ list: [AchievementItem]) -> some View {
        GlassSection(content: {
            ForEach(list) { item in
                AchievementRow(item: item)
            }
        }, header: {
            Text("\(title) (\(list.count))")
        })
    }
}

private struct AchievementRow: View {
    let item: AchievementItem

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            BadgeImage(url: item.unlocked ? item.badgeURL : item.lockedBadgeURL, size: 48, dimmed: !item.unlocked)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.title)
                    .font(.subheadline.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
                Text(item.detail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if !item.unlocked && !item.progress.isEmpty {
                    ProgressView(value: item.progressFraction)
                    Text(item.progress)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                if let time = item.unlockTime, item.unlocked {
                    Text("Unlocked \(time.formatted(date: .abbreviated, time: .shortened))\(item.hardcore ? " · Hardcore" : "")")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text("\(item.points)")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
        }
    }
}
