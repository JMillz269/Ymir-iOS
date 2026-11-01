import SwiftUI
import UIKit

// MARK: - Model

struct GameEntry: Identifiable, Hashable {
    let url: URL
    let sizeBytes: Int64
    /// Name chosen by the user, if any.
    var customName: String?
    /// Modification time of the cover art file; changes whenever the artwork changes.
    var coverStamp: TimeInterval = 0

    var id: String { url.path }
    /// The file name without extension.
    var stem: String { url.deletingPathExtension().lastPathComponent }
    /// The name shown in the app.
    var title: String { customName ?? stem }
    var format: String { url.pathExtension.uppercased() }

    var subtitle: String {
        let size = ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .file)
        return "\(format) · \(size)"
    }

    /// Path relative to the Documents folder; stable across app reinstalls, unlike the absolute path.
    var relativePath: String {
        let root = AppPaths.documents.path
        let path = url.path
        if path.hasPrefix(root) {
            return String(path.dropFirst(root.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        }
        return path
    }

    /// All files that make up this disc image (the descriptor file plus its data tracks).
    func relatedFiles() -> [URL] {
        let fm = FileManager.default
        let dir = url.deletingLastPathComponent()
        var files = [url]

        switch url.pathExtension.lowercased() {
        case "cue":
            let text = (try? String(contentsOf: url, encoding: .utf8))
                ?? (try? String(contentsOf: url, encoding: .isoLatin1))
                ?? ""
            for line in text.split(whereSeparator: \.isNewline) {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard trimmed.uppercased().hasPrefix("FILE") else { continue }
                let parts = trimmed.split(separator: "\"", omittingEmptySubsequences: false)
                guard parts.count >= 3 else { continue }
                let file = dir.appendingPathComponent(String(parts[1]))
                if fm.fileExists(atPath: file.path) && !files.contains(file) {
                    files.append(file)
                }
            }
        case "ccd":
            for ext in ["img", "sub"] {
                let file = dir.appendingPathComponent(stem + "." + ext)
                if fm.fileExists(atPath: file.path) { files.append(file) }
            }
        case "mds":
            let file = dir.appendingPathComponent(stem + ".mdf")
            if fm.fileExists(atPath: file.path) { files.append(file) }
        default:
            break
        }
        return files
    }

    /// Cover art placed next to the game or in Documents/covers, named like the game. Optional.
    func coverURL() -> URL? {
        let fm = FileManager.default
        // Artwork chosen in the app lives in covers; images next to the game are used as a fallback
        let folders = [AppPaths.covers, url.deletingLastPathComponent()]
        for folder in folders {
            for ext in ["png", "jpg", "jpeg"] {
                let candidate = folder.appendingPathComponent(stem + "." + ext)
                if fm.fileExists(atPath: candidate.path) { return candidate }
            }
        }
        return nil
    }
}

// MARK: - Library

/// How the games are ordered in the library.
enum GameSortMode: String, CaseIterable, Identifiable {
    case recent
    case titleAscending
    case titleDescending
    case manual

    var id: String { rawValue }

    var label: String {
        switch self {
        case .recent: return "Recently Played"
        case .titleAscending: return "Title (A to Z)"
        case .titleDescending: return "Title (Z to A)"
        case .manual: return "Manual"
        }
    }

    var systemImage: String {
        switch self {
        case .recent: return "clock"
        case .titleAscending: return "arrow.down"
        case .titleDescending: return "arrow.up"
        case .manual: return "hand.draw"
        }
    }
}

@MainActor
final class GameLibrary: ObservableObject {
    @Published private(set) var games: [GameEntry] = []

    @Published var sortMode: GameSortMode = {
        UserDefaults.standard.string(forKey: "ymir.sortMode").flatMap(GameSortMode.init(rawValue:)) ?? .recent
    }() {
        didSet {
            UserDefaults.standard.set(sortMode.rawValue, forKey: Self.sortModeKey)
            if sortMode == .manual && oldValue != .manual && Self.manualOrder().isEmpty {
                // Manual ordering starts from what the player was looking at
                Self.saveManualOrder(games.map(\.relativePath))
            }
            applySort()
        }
    }

    private var scanned: [GameEntry] = []

    private static let discExtensions: Set<String> = ["cue", "chd", "iso", "ccd", "mds"]
    // Folders of the emulator profile that never contain games
    private static let ignoredFolders: Set<String> = [
        "roms", "backup", "savestates", "state", "screenshots", "dumps", "covers", "exports", "originals",
    ]
    private static let lastPlayedKey = "ymir.lastPlayed"
    private static let customNamesKey = "ymir.customNames"
    private static let sortModeKey = "ymir.sortMode"
    private static let manualOrderKey = "ymir.manualOrder"

    init() {
        reload()
    }

    func reload() {
        let fm = FileManager.default
        try? fm.createDirectory(at: AppPaths.games, withIntermediateDirectories: true)

        let names = Self.customNames()
        var found: [GameEntry] = []

        let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey]
        if let enumerator = fm.enumerator(at: AppPaths.documents, includingPropertiesForKeys: keys,
                                          options: [.skipsHiddenFiles]) {
            for case let url as URL in enumerator {
                let values = try? url.resourceValues(forKeys: Set(keys))
                if values?.isDirectory == true {
                    if Self.ignoredFolders.contains(url.lastPathComponent.lowercased()) {
                        enumerator.skipDescendants()
                    }
                    continue
                }
                guard Self.discExtensions.contains(url.pathExtension.lowercased()) else { continue }

                var entry = GameEntry(url: url, sizeBytes: 0)
                let total = entry.relatedFiles().reduce(Int64(0)) { sum, file in
                    let size = (try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
                    return sum + Int64(size)
                }
                let stamp = entry.coverURL()
                    .flatMap { try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate }?
                    .timeIntervalSince1970 ?? 0
                entry = GameEntry(url: url, sizeBytes: total, customName: names[entry.relativePath], coverStamp: stamp)
                found.append(entry)
            }
        }

        scanned = found
        applySort()
    }

    /// Orders the scanned games according to the sort mode.
    private func applySort() {
        let alphabetical: (GameEntry, GameEntry) -> Bool = {
            $0.title.localizedStandardCompare($1.title) == .orderedAscending
        }
        switch sortMode {
        case .recent:
            let lastPlayed = Self.lastPlayed()
            games = scanned.sorted { a, b in
                let da = lastPlayed[a.relativePath] ?? 0
                let db = lastPlayed[b.relativePath] ?? 0
                if da != db { return da > db }
                return alphabetical(a, b)
            }
        case .titleAscending:
            games = scanned.sorted(by: alphabetical)
        case .titleDescending:
            games = scanned.sorted { alphabetical($1, $0) }
        case .manual:
            let order = Self.manualOrder()
            let position = Dictionary(order.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
            // Games that were never placed (new ones) go at the end, alphabetically
            games = scanned.sorted { a, b in
                switch (position[a.relativePath], position[b.relativePath]) {
                case let (pa?, pb?): return pa < pb
                case (_?, nil): return true
                case (nil, _?): return false
                case (nil, nil): return alphabetical(a, b)
                }
            }
        }
    }

    /// Moves games in the manual order, like List's onMove. Only meaningful in manual mode.
    func moveGames(from source: IndexSet, to destination: Int) {
        var reordered = games
        reordered.move(fromOffsets: source, toOffset: destination)
        games = reordered
        Self.saveManualOrder(reordered.map(\.relativePath))
    }

    /// Puts the game with this id in the place of another one (dragged onto it), in the manual order.
    func moveGame(id: String, onto targetID: String) {
        guard let from = games.firstIndex(where: { $0.id == id }),
              let to = games.firstIndex(where: { $0.id == targetID }), from != to else { return }
        moveGames(from: IndexSet(integer: from), to: to > from ? to + 1 : to)
    }

    private static func manualOrder() -> [String] {
        UserDefaults.standard.stringArray(forKey: manualOrderKey) ?? []
    }

    private static func saveManualOrder(_ order: [String]) {
        UserDefaults.standard.set(order, forKey: manualOrderKey)
    }

    func delete(_ game: GameEntry) {
        for file in game.relatedFiles() {
            try? FileManager.default.removeItem(at: file)
        }
        var played = Self.lastPlayed()
        played.removeValue(forKey: game.relativePath)
        UserDefaults.standard.set(played, forKey: Self.lastPlayedKey)
        removeArtworkFiles(for: game)
        rename(game, to: nil, reloadAfter: false)
        reload()
    }

    /// Hands what the app remembers about a game (its name, when it was played, its place in the manual order) over to
    /// the path the game has now, for a game whose file was replaced by another (a conversion to CHD).
    static func transferMetadata(from old: GameEntry, toRelativePath newPath: String) {
        guard old.relativePath != newPath else { return }
        let defaults = UserDefaults.standard

        var names = customNames()
        if let name = names.removeValue(forKey: old.relativePath) {
            names[newPath] = name
            defaults.set(names, forKey: customNamesKey)
        }
        var played = lastPlayed()
        if let time = played.removeValue(forKey: old.relativePath) {
            played[newPath] = time
            defaults.set(played, forKey: lastPlayedKey)
        }
        var order = manualOrder()
        if let index = order.firstIndex(of: old.relativePath) {
            order[index] = newPath
            saveManualOrder(order)
        }
    }

    // MARK: Names

    /// Changes the name the game has in the app. An empty name restores the file name.
    func rename(_ game: GameEntry, to name: String?, reloadAfter: Bool = true) {
        var names = Self.customNames()
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmed.isEmpty || trimmed == game.stem {
            names.removeValue(forKey: game.relativePath)
        } else {
            names[game.relativePath] = trimmed
        }
        UserDefaults.standard.set(names, forKey: Self.customNamesKey)
        if reloadAfter { reload() }
    }

    // MARK: Renaming the files

    /// Gives the game's files a new name (the extensions stay): the descriptor and its tracks, the sheet's references to
    /// the tracks, the artwork, and what the app remembers about the game (play time, place in the order, save states).
    /// Returns what went wrong, or nil.
    func renameFiles(of game: GameEntry, to requested: String) -> String? {
        let forbidden = CharacterSet(charactersIn: "/\\:*?\"<>|").union(.controlCharacters)
        var name = requested.components(separatedBy: forbidden).joined(separator: " ")
        name = name.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ".")))
        while name.contains("  ") { name = name.replacingOccurrences(of: "  ", with: " ") }
        guard !name.isEmpty else { return "That name can't be used for a file." }

        if name == game.stem {
            rename(game, to: nil)
            return nil
        }
        if let loaded = YmirHost.loadedGamePath, YmirHost.isDiscLoaded,
           URL(fileURLWithPath: loaded).standardizedFileURL == game.url.standardizedFileURL {
            return "The game is running. Close it first."
        }

        let fm = FileManager.default
        let dir = game.url.deletingLastPathComponent()
        let ext = game.url.pathExtension
        let newDescriptor = dir.appendingPathComponent(name).appendingPathExtension(ext)

        // The files to move, with the names they get
        var moves: [(from: URL, to: URL)] = [(game.url, newDescriptor)]
        var sheetNames: [(old: String, new: String)] = []
        let related = game.relatedFiles().filter { $0 != game.url }
        let others = Set(games.filter { $0.id != game.id }.flatMap { $0.relatedFiles().map(\.path) })
        if related.contains(where: { others.contains($0.path) }) {
            return "The game shares files with another game, so its files can't be renamed."
        }

        switch ext.lowercased() {
        case "cue":
            var taken = Set<String>([newDescriptor.lastPathComponent])
            for (index, file) in related.enumerated() {
                let fileStem = file.deletingPathExtension().lastPathComponent
                var newStem = fileStem.hasPrefix(game.stem) ? name + String(fileStem.dropFirst(game.stem.count))
                                                              : (index == 0 ? name : "\(name) (\(index + 1))")
                var candidate = newStem + "." + file.pathExtension
                var counter = 2
                while taken.contains(candidate) {
                    newStem = "\(name) (\(counter))"
                    candidate = newStem + "." + file.pathExtension
                    counter += 1
                }
                taken.insert(candidate)
                moves.append((file, dir.appendingPathComponent(candidate)))
                sheetNames.append((file.lastPathComponent, candidate))
            }
        default:
            // CCD and MDS: the image files are named like the descriptor
            for file in related {
                moves.append((file, dir.appendingPathComponent(name).appendingPathExtension(file.pathExtension)))
            }
        }

        for move in moves where fm.fileExists(atPath: move.to.path) && move.from != move.to {
            return "A file named \(move.to.lastPathComponent) is there already."
        }

        // Move them; put everything back if one fails
        var done: [(from: URL, to: URL)] = []
        do {
            for move in moves {
                try fm.moveItem(at: move.from, to: move.to)
                done.append(move)
            }
            if ext.lowercased() == "cue" {
                let data = try Data(contentsOf: newDescriptor)
                let utf8 = String(data: data, encoding: .utf8)
                var text = utf8 ?? String(data: data, encoding: .isoLatin1) ?? ""
                for pair in sheetNames {
                    text = text.replacingOccurrences(of: "\"\(pair.old)\"", with: "\"\(pair.new)\"")
                }
                try (utf8 != nil ? text.data(using: .utf8) : text.data(using: .isoLatin1))?.write(to: newDescriptor)
            }
        } catch {
            for move in done.reversed() {
                try? fm.moveItem(at: move.to, to: move.from)
            }
            return "The files couldn't be renamed: \(error.localizedDescription)"
        }

        // What the app keeps about the game goes with it
        rename(game, to: nil, reloadAfter: false)
        let renamed = GameEntry(url: newDescriptor, sizeBytes: game.sizeBytes)
        Self.transferMetadata(from: game, toRelativePath: renamed.relativePath)
        SaveStateCatalog.relink(from: game.relativePath, to: renamed.relativePath)
        for folder in [AppPaths.covers, dir] {
            for imageExt in ["png", "jpg", "jpeg"] {
                let old = folder.appendingPathComponent(game.stem + "." + imageExt)
                let new = folder.appendingPathComponent(name + "." + imageExt)
                if fm.fileExists(atPath: old.path) && !fm.fileExists(atPath: new.path) {
                    try? fm.moveItem(at: old, to: new)
                }
            }
        }
        reload()
        return nil
    }

    // MARK: Artwork

    func hasCustomArtwork(_ game: GameEntry) -> Bool {
        ["png", "jpg", "jpeg"].contains {
            FileManager.default.fileExists(atPath: AppPaths.covers.appendingPathComponent(game.stem + "." + $0).path)
        }
    }

    /// Saves an image as the game's artwork. Returns false if the data isn't an image.
    @discardableResult
    func setArtwork(_ data: Data, for game: GameEntry) -> Bool {
        guard let image = UIImage(data: data) else { return false }

        // Covers are shown small; keep the files light
        let maxSide: CGFloat = 800
        let scale = min(1, maxSide / max(image.size.width, image.size.height))
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let resized = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
        guard let jpeg = resized.jpegData(compressionQuality: 0.88) else { return false }

        removeArtworkFiles(for: game)
        do {
            try FileManager.default.createDirectory(at: AppPaths.covers, withIntermediateDirectories: true)
            try jpeg.write(to: AppPaths.covers.appendingPathComponent(game.stem + ".jpg"), options: .atomic)
        } catch {
            return false
        }
        reload()
        return true
    }

    func removeArtwork(for game: GameEntry) {
        removeArtworkFiles(for: game)
        reload()
    }

    private func removeArtworkFiles(for game: GameEntry) {
        for ext in ["png", "jpg", "jpeg"] {
            try? FileManager.default.removeItem(at: AppPaths.covers.appendingPathComponent(game.stem + "." + ext))
        }
    }

    private static func customNames() -> [String: String] {
        (UserDefaults.standard.dictionary(forKey: customNamesKey) as? [String: String]) ?? [:]
    }

    static func markPlayed(_ game: GameEntry) {
        var played = lastPlayed()
        played[game.relativePath] = Date().timeIntervalSince1970
        UserDefaults.standard.set(played, forKey: lastPlayedKey)
    }

    private static func lastPlayed() -> [String: Double] {
        (UserDefaults.standard.dictionary(forKey: lastPlayedKey) as? [String: Double]) ?? [:]
    }
}

// MARK: - Importing files

enum ImportService {
    struct Outcome {
        var copied = 0
        var failed = 0
    }

    /// Copies files picked with the document picker into a folder inside Documents.
    /// Meant to be called off the main thread, since disc images can be large.
    static func copy(_ urls: [URL], to folder: URL) -> Outcome {
        let fm = FileManager.default
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)

        var outcome = Outcome()
        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }

            let destination = folder.appendingPathComponent(url.lastPathComponent)
            do {
                if fm.fileExists(atPath: destination.path) {
                    try fm.removeItem(at: destination)
                }
                try fm.copyItem(at: url, to: destination)
                outcome.copied += 1
            } catch {
                outcome.failed += 1
            }
        }
        return outcome
    }
}

// MARK: - Cover art

private final class CoverCache: @unchecked Sendable {
    static let shared = CoverCache()
    private let cache = NSCache<NSString, UIImage>()

    func image(for game: GameEntry, pixelSize: CGFloat) async -> UIImage? {
        let key = "\(game.id)|\(game.coverStamp)@\(Int(pixelSize))" as NSString
        if let cached = cache.object(forKey: key) {
            return cached
        }
        let url = game.coverURL()
        let image: UIImage? = await Task.detached(priority: .utility) { () -> UIImage? in
            guard let url, let full = UIImage(contentsOfFile: url.path) else { return nil }
            return full.preparingThumbnail(of: CGSize(width: pixelSize, height: pixelSize)) ?? full
        }.value
        if let image {
            cache.setObject(image, forKey: key)
        }
        return image
    }
}

struct CoverArtView: View {
    let game: GameEntry
    var size: CGFloat = 60

    @State private var image: UIImage?
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                placeholder
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: size * 0.22, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5)
        )
        // (the size is part of the id: the grid is laid out with a small width at first, and a picture loaded for that
        // size stayed on screen, blurred, after the tiles had got their real size)
        .task(id: "\(game.id)|\(game.coverStamp)|\(Int(size * displayScale))") {
            image = await CoverCache.shared.image(for: game, pixelSize: size * displayScale)
        }
    }

    /// A stable colour per title, so that games are easy to tell apart without cover art.
    private var hue: Double {
        var hash: UInt32 = 5381
        for byte in game.title.utf8 {
            hash = (hash &* 33) &+ UInt32(byte)
        }
        return Double(hash % 360) / 360.0
    }

    private var placeholder: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(hue: hue, saturation: 0.55, brightness: 0.88),
                    Color(hue: (hue + 0.08).truncatingRemainder(dividingBy: 1), saturation: 0.75, brightness: 0.55),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            Image(systemName: "opticaldisc.fill")
                .font(.system(size: size * 0.46, weight: .semibold))
                .foregroundStyle(.white.opacity(0.92))
        }
    }
}
