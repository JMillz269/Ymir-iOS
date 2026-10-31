import SwiftUI

// MARK: - Model

/// A save state slot of a game, as it is on disk.
struct SavedSlot: Identifiable, Hashable {
    /// The game's save state folder.
    let folder: URL
    let index: Int
    let date: Date
    /// Size of the slot's file and of its backup (the state it replaced).
    let bytes: Int64

    var url: URL { folder.appendingPathComponent("\(index).savestate") }
    var backupURL: URL { folder.appendingPathComponent("\(index)-1.savestate") }
    var id: String { url.path }

    var title: String { "Slot \(index + 1)" }
    var dateText: String { date.formatted(date: .abbreviated, time: .shortened) }
    var sizeText: String { ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }
}

/// The save states of one game: a folder in the save states folder, named after a hash of the disc.
struct SavedGame: Identifiable {
    let folder: URL
    /// The game in the library these save states belong to, if it is known and still there.
    let game: GameEntry?
    /// The game's title from the disc, for when the game isn't known.
    let discTitle: String?
    var slots: [SavedSlot]

    var id: String { folder.path }
    var title: String { game?.title ?? discTitle ?? "Unknown Game" }
    var totalBytes: Int64 { slots.reduce(0) { $0 + $1.bytes } }
    var totalSizeText: String { ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file) }
}

// MARK: - Catalog

/// Finds the save states of all games on disk. They are stored per game in `savestates/<disc hash>/<slot>.savestate`;
/// the emulator notes which disc image a folder belongs to in `game.txt` (when the game is started or a state saved).
enum SaveStateCatalog {
    static var root: URL {
        AppPaths.documents.appendingPathComponent("savestates", isDirectory: true)
    }

    /// Paths of one place can be written with or without the "/private" in front on iOS.
    private static func normalized(_ path: String) -> String {
        path.hasPrefix("/private/") ? String(path.dropFirst("/private".count)) : path
    }

    private static func firstLine(of url: URL) -> String? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return text.split(whereSeparator: \.isNewline).first.map { $0.trimmingCharacters(in: .whitespaces) }
    }

    private static func discTitle(in folder: URL) -> String? {
        guard let text = try? String(contentsOf: folder.appendingPathComponent("meta.txt"), encoding: .utf8) else {
            return nil
        }
        for line in text.split(whereSeparator: \.isNewline) where line.hasPrefix("Title:") {
            let title = line.dropFirst("Title:".count).trimmingCharacters(in: .whitespaces)
            return title.isEmpty ? nil : title
        }
        return nil
    }

    private static func fileSize(_ url: URL) -> Int64 {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes?[.size] as? NSNumber)?.int64Value ?? 0
    }

    /// Lists every game that has save states, those in the library first (by title), then the rest.
    static func scan(games: [GameEntry]) -> [SavedGame] {
        let fm = FileManager.default
        guard let folders = try? fm.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return [] }

        var found: [SavedGame] = []
        for folder in folders {
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: folder.path, isDirectory: &isDirectory), isDirectory.boolValue,
                  let names = try? fm.contentsOfDirectory(atPath: folder.path) else { continue }

            var slots: [SavedSlot] = []
            for name in names where name.hasSuffix(".savestate") {
                // (the backups are named "<slot>-1" and don't parse)
                guard let index = Int(name.dropLast(".savestate".count)) else { continue }
                let file = folder.appendingPathComponent(name)
                let attributes = try? fm.attributesOfItem(atPath: file.path)
                let date = (attributes?[.modificationDate] as? Date) ?? .distantPast
                let backup = folder.appendingPathComponent("\(index)-1.savestate")
                slots.append(SavedSlot(folder: folder, index: index, date: date,
                                       bytes: fileSize(file) + fileSize(backup)))
            }
            guard !slots.isEmpty else { continue }
            slots.sort { $0.index < $1.index }

            var game: GameEntry?
            if let link = firstLine(of: folder.appendingPathComponent("game.txt")) {
                let wanted = normalized(link)
                game = games.first {
                    $0.relativePath == link || normalized($0.url.path) == wanted
                        || normalized($0.relativePath) == wanted
                }
            }
            found.append(SavedGame(folder: folder, game: game, discTitle: discTitle(in: folder), slots: slots))
        }
        return found.sorted {
            if ($0.game != nil) != ($1.game != nil) { return $0.game != nil }
            return $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
        }
    }

    /// The save states of a game of the library, newest first.
    static func slots(for game: GameEntry, in saved: [SavedGame]) -> [SavedSlot] {
        guard let entry = saved.first(where: { $0.game?.id == game.id }) else { return [] }
        return entry.slots.sorted { $0.date > $1.date }
    }

    /// Whether the emulator has this game loaded, and so holds its save states in memory.
    private static func isLoaded(_ game: GameEntry?) -> Bool {
        guard let game, YmirHost.isDiscLoaded, let loaded = YmirHost.loadedGamePath else { return false }
        return normalized(loaded) == normalized(game.url.path)
    }

    /// Deletes a slot and its backup.
    static func delete(_ slot: SavedSlot, of saved: SavedGame) {
        if isLoaded(saved.game) {
            // (the emulator forgets it too)
            YmirHost.deleteState(slot: slot.index)
        } else {
            try? FileManager.default.removeItem(at: slot.url)
            try? FileManager.default.removeItem(at: slot.backupURL)
        }
    }

    /// Deletes all states of a game.
    static func deleteAll(of saved: SavedGame) {
        for slot in saved.slots {
            delete(slot, of: saved)
        }
        if !isLoaded(saved.game) {
            // (what's left is only the notes about the game)
            try? FileManager.default.removeItem(at: saved.folder)
        }
    }

    /// Copies a slot's file to a temporary folder as "<game> - Slot N.savestate", for the share sheet.
    static func exportCopy(of slot: SavedSlot, game title: String) throws -> URL {
        let name = "\(title) - Slot \(slot.index + 1).savestate".replacingOccurrences(of: "/", with: "-")
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("SaveStateExport", isDirectory: true)
        let target = folder.appendingPathComponent(name)
        try? FileManager.default.removeItem(at: folder)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: slot.url, to: target)
        return target
    }
}

// MARK: - Manager

/// Settings screen listing the save states of all games: load, export or delete any of them.
struct SaveStateManagerView: View {
    @StateObject private var library = GameLibrary()
    @State private var saved: [SavedGame] = []
    @State private var loaded = false
    @State private var pendingDelete: PendingDelete?
    @State private var pendingDeleteAll: SavedGame?
    @State private var exportItem: ExportItem?
    @State private var alertText: String?

    struct PendingDelete: Identifiable {
        let slot: SavedSlot
        let game: SavedGame
        var id: String { slot.id }
    }

    struct ExportItem: Identifiable {
        let url: URL
        var id: URL { url }
    }

    private func reload() {
        library.reload()
        saved = SaveStateCatalog.scan(games: library.games)
        loaded = true
    }

    private func load(_ slot: SavedSlot, of entry: SavedGame) {
        guard let game = entry.game else { return }
        guard YmirHost.hasBIOS else {
            alertText = "Ymir needs a Sega Saturn BIOS (IPL ROM) to run games. Import one first."
            return
        }
        YmirShell.launch(game, loadSlot: slot.index)
    }

    private func export(_ slot: SavedSlot, of entry: SavedGame) {
        do {
            exportItem = ExportItem(url: try SaveStateCatalog.exportCopy(of: slot, game: entry.title))
        } catch {
            alertText = "Couldn't export the save state: \(error.localizedDescription)"
        }
    }

    var body: some View {
        List {
            if saved.isEmpty {
                Section {
                    Text(loaded ? "No save states yet. Save one from the in-game menu and it shows up here." : "")
                        .foregroundStyle(.secondary)
                }
            }

            ForEach(saved) { entry in
                Section {
                    ForEach(entry.slots) { slot in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(slot.title)
                                Text("\(slot.dateText) · \(slot.sizeText)")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Load") {
                                load(slot, of: entry)
                            }
                            .ymirSecondaryButton()
                            .disabled(entry.game == nil)
                            Menu {
                                Button {
                                    export(slot, of: entry)
                                } label: {
                                    Label("Export…", systemImage: "square.and.arrow.up")
                                }
                                Button(role: .destructive) {
                                    pendingDelete = PendingDelete(slot: slot, game: entry)
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            } label: {
                                Image(systemName: "ellipsis.circle")
                                    .font(.title3)
                                    .frame(minWidth: 32, minHeight: 32)
                            }
                            .accessibilityLabel("More for \(entry.title), \(slot.title)")
                        }
                        .buttonStyle(.borderless)
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                pendingDelete = PendingDelete(slot: slot, game: entry)
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
                } header: {
                    HStack {
                        Text(entry.title)
                            .textCase(nil)
                        Spacer()
                        Text(entry.totalSizeText)
                        Menu {
                            Button(role: .destructive) {
                                pendingDeleteAll = entry
                            } label: {
                                Label("Delete All…", systemImage: "trash")
                            }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                        }
                    }
                } footer: {
                    if entry.game == nil {
                        Text("This game isn't in your library, or its save states were made before Ymir noted which game they belong to. Start the game once from the library to link them, then they can be loaded from here.")
                    }
                }
            }

            if !saved.isEmpty {
                Section {
                } footer: {
                    Text("Load starts the game and continues from the state. Save states are stored per game in the savestates folder, which is visible in the Files app. Export shares a copy, for example to Files or AirDrop.")
                }
            }
        }
        .navigationTitle("Save States")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { reload() }
        .confirmationDialog(
            "Delete this save state?",
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            titleVisibility: .visible,
            presenting: pendingDelete
        ) { item in
            Button("Delete \(item.slot.title)", role: .destructive) {
                SaveStateCatalog.delete(item.slot, of: item.game)
                pendingDelete = nil
                reload()
            }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: { item in
            Text("\(item.game.title), \(item.slot.title). This can't be undone.")
        }
        .confirmationDialog(
            "Delete all save states of this game?",
            isPresented: Binding(get: { pendingDeleteAll != nil }, set: { if !$0 { pendingDeleteAll = nil } }),
            titleVisibility: .visible,
            presenting: pendingDeleteAll
        ) { entry in
            Button("Delete \(entry.slots.count) Save State\(entry.slots.count == 1 ? "" : "s")", role: .destructive) {
                SaveStateCatalog.deleteAll(of: entry)
                pendingDeleteAll = nil
                reload()
            }
            Button("Cancel", role: .cancel) { pendingDeleteAll = nil }
        } message: { entry in
            Text("\(entry.title). This can't be undone.")
        }
        .sheet(item: $exportItem) { item in
            ShareSheet(items: [item.url])
        }
        .alert(
            "Save States",
            isPresented: Binding(get: { alertText != nil }, set: { if !$0 { alertText = nil } })
        ) {
            Button("OK", role: .cancel) { alertText = nil }
        } message: {
            Text(alertText ?? "")
        }
    }
}
