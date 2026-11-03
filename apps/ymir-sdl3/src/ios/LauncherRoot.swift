import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// Root of the native app: a tab bar (Liquid Glass on iOS 26 and later) with the game library and the settings.
struct LauncherRoot: View {
    let onLaunch: (GameEntry) -> Void
    let onLaunchState: (GameEntry, Int) -> Void
    let onResume: () -> Void

    @StateObject private var library = GameLibrary()
    @State private var selection = 0

    var body: some View {
        TabView(selection: $selection) {
            GamesView(library: library, onLaunch: onLaunch, onLaunchState: onLaunchState, onResume: onResume)
                .tabItem { Label("Games", systemImage: "gamecontroller.fill") }
                .tag(0)

            NavigationStack {
                SettingsView()
                    .navigationTitle("Settings")
            }
            .tabItem { Label("Settings", systemImage: "gearshape.fill") }
            .tag(1)
        }
    }
}

// MARK: - Games tab

private enum ImportKind {
    case games
    case bios
}

private struct AlertInfo: Identifiable {
    let id = UUID()
    let title: String
    let message: String
    var actionTitle: String?
    var action: (() -> Void)?
}

struct GamesView: View {
    @ObservedObject var library: GameLibrary
    let onLaunch: (GameEntry) -> Void
    let onLaunchState: (GameEntry, Int) -> Void
    let onResume: () -> Void

    @ObservedObject private var converter = CHDConverter.shared
    @State private var conversionReport: ConversionReport?
    @State private var search = ""
    @State private var showImporter = false
    @State private var importKind = ImportKind.games
    @State private var isImporting = false
    @State private var alert: AlertInfo?
    @State private var pendingDelete: GameEntry?
    @State private var artworkTarget: GameEntry?
    @State private var showPhotoPicker = false
    @State private var showArtworkFiles = false
    @State private var photoItem: PhotosPickerItem?
    @State private var searchTarget: GameEntry?
    @State private var renameTarget: GameEntry?
    @State private var renameText = ""
    @State private var editMode = EditMode.inactive
    @State private var hasBIOS = YmirHost.hasBIOS
    @State private var activePath: String? = YmirHost.loadedGamePath
    @State private var savedStates: [SavedGame] = []
    @AppStorage("library.useGrid") private var useGrid = true

    private var filteredGames: [GameEntry] {
        let query = search.trimmingCharacters(in: .whitespaces)
        if query.isEmpty { return library.games }
        return library.games.filter { $0.title.localizedCaseInsensitiveContains(query) }
    }

    /// Games can only be dragged into a new order in manual mode, and while the whole list is visible.
    private var canReorder: Bool {
        library.sortMode == .manual && search.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private var activeGame: GameEntry? {
        guard let activePath else { return nil }
        return library.games.first { $0.url.path == activePath }
    }

    var body: some View {
        NavigationStack {
            Group {
            if useGrid && !library.games.isEmpty {
                gridContent
            } else {
            List {
                if !hasBIOS {
                    Section {
                        BIOSBanner { startImport(.bios) }
                            .padding(16)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .ymirGlassCard()
                            .ymirGlassRow()
                    }
                }

                if library.games.isEmpty {
                    Section {
                        EmptyLibraryView(
                            importGames: { startImport(.games) },
                            openFiles: { FilesApp.openDocuments() }
                        )
                        .padding(16)
                        .ymirGlassCard()
                        .ymirGlassRow()
                    }
                } else {
                    Section {
                        ForEach(filteredGames) { game in
                            Button {
                                if !editMode.isEditing {
                                    play(game)
                                }
                            } label: {
                                GameRow(game: game, isActive: game.url.path == activePath)
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 6)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .ymirGlassCard(cornerRadius: 20)
                            }
                            .buttonStyle(.plain)
                            .ymirGlassRow()
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button(role: .destructive) {
                                    pendingDelete = game
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                            .contextMenu { gameMenu(game) }
                        }
                        .onMove(perform: canReorder ? { source, destination in
                            library.moveGames(from: source, to: destination)
                        } : nil)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(YmirBackdrop())
            }
            }
            .environment(\.editMode, $editMode)
            .onChange(of: canReorder) { value in
                if !value {
                    editMode = .inactive
                }
            }
            .photosPicker(isPresented: $showPhotoPicker, selection: $photoItem, matching: .images)
            .onChange(of: photoItem) { item in
                guard let item, let game = artworkTarget else { return }
                Task {
                    if let data = try? await item.loadTransferable(type: Data.self) {
                        if !library.setArtwork(data, for: game) {
                            alert = AlertInfo(title: "Couldn't Use That Image", message: "The file isn't a supported image.")
                        }
                    }
                    photoItem = nil
                }
            }
            .fileImporter(isPresented: $showArtworkFiles, allowedContentTypes: [.image], allowsMultipleSelection: false) { result in
                guard case .success(let urls) = result, let url = urls.first, let game = artworkTarget else { return }
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                if let data = try? Data(contentsOf: url), library.setArtwork(data, for: game) {
                    return
                }
                alert = AlertInfo(title: "Couldn't Use That Image", message: "The file isn't a supported image.")
            }
            .alert(
                "Rename Game",
                isPresented: Binding(get: { renameTarget != nil }, set: { if !$0 { renameTarget = nil } })
            ) {
                TextField("Name", text: $renameText)
                Button("Save") {
                    if let game = renameTarget {
                        if let problem = library.renameFiles(of: game, to: renameText) {
                            alert = AlertInfo(title: "Couldn't Rename", message: problem)
                        }
                    }
                    renameTarget = nil
                }
                Button("Cancel", role: .cancel) { renameTarget = nil }
            } message: {
                Text("The game's files are renamed as well (the extensions stay), so the name is the same in the Files app and in the game menu.")
            }
            .sheet(item: $searchTarget) { game in
                ArtworkSearchView(game: game) { data in
                    library.setArtwork(data, for: game)
                }
            }
            .listStyle(.plain)
            .navigationTitle("Games")
            .refreshable { refresh() }
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Menu {
                        Picker("Sort By", selection: $library.sortMode) {
                            ForEach(GameSortMode.allCases) { mode in
                                Label(mode.label, systemImage: mode.systemImage).tag(mode)
                            }
                        }
                    } label: {
                        Image(systemName: "arrow.up.arrow.down")
                    }
                }
                ToolbarItem(placement: .navigationBarLeading) {
                    Button {
                        withAnimation { useGrid.toggle() }
                    } label: {
                        Image(systemName: useGrid ? "list.bullet" : "square.grid.2x2")
                    }
                }
                if canReorder {
                    ToolbarItem(placement: .navigationBarLeading) {
                        Button(editMode.isEditing ? "Done" : "Reorder") {
                            withAnimation {
                                editMode = editMode.isEditing ? .inactive : .active
                            }
                        }
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Menu {
                        Button {
                            startImport(.games)
                        } label: {
                            Label("Import Games…", systemImage: "square.and.arrow.down")
                        }
                        Button {
                            startImport(.bios)
                        } label: {
                            Label("Import BIOS…", systemImage: "cpu")
                        }
                        Button {
                            FilesApp.openDocuments()
                        } label: {
                            Label("Open Ymir Folder in Files", systemImage: "folder")
                        }
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 8) {
                    ConversionBar(converter: converter)
                    if let game = activeGame {
                        ResumeBar(game: game, onResume: onResume)
                    }
                    if !library.games.isEmpty {
                        YmirSearchField(text: $search, prompt: "Search games")
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
            }
            .onChange(of: converter.completedCount) { _ in library.reload() }
            .onChange(of: converter.report) { value in
                if let value {
                    conversionReport = value
                    converter.report = nil
                }
            }
            .alert(item: $conversionReport) { report in
                Alert(title: Text(report.title), message: Text(report.message), dismissButton: .default(Text("OK")))
            }
            .overlay {
                if isImporting {
                    ProgressView("Importing…")
                        .padding(24)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                }
            }
        }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            guard case .success(let urls) = result, !urls.isEmpty else { return }
            runImport(urls)
        }
        .alert(item: $alert) { info in
            if let title = info.actionTitle, let action = info.action {
                return Alert(
                    title: Text(info.title),
                    message: Text(info.message),
                    primaryButton: .default(Text(title), action: action),
                    secondaryButton: .cancel()
                )
            }
            return Alert(title: Text(info.title), message: Text(info.message), dismissButton: .default(Text("OK")))
        }
        .confirmationDialog(
            "Delete this game?",
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            titleVisibility: .visible,
            presenting: pendingDelete
        ) { game in
            Button("Delete \(game.title)", role: .destructive) {
                library.delete(game)
                pendingDelete = nil
            }
            Button("Cancel", role: .cancel) {
                pendingDelete = nil
            }
        } message: { _ in
            Text("The disc image is removed from this device.")
        }
        .onAppear { refresh() }
    }

    @ViewBuilder
    private func gameMenu(_ game: GameEntry) -> some View {
        Button {
            play(game)
        } label: {
            Label("Play", systemImage: "play.fill")
        }
        let states = SaveStateCatalog.slots(for: game, in: savedStates)
        if !states.isEmpty {
            Menu {
                ForEach(states) { slot in
                    Button {
                        play(game, loadSlot: slot.index)
                    } label: {
                        Label("\(slot.title) · \(slot.dateText)", systemImage: "clock.arrow.circlepath")
                    }
                }
            } label: {
                Label("Load State", systemImage: "clock.arrow.circlepath")
            }
        }
        if converter.isAvailable && CHDConverter.canConvert(game) {
            Button {
                converter.enqueue([game])
            } label: {
                Label(converter.isQueued(game) ? "Converting to CHD…" : "Convert to CHD", systemImage: "archivebox")
            }
            .disabled(converter.isQueued(game) || game.url.path == activeGame?.url.path)
        }
        Menu {
            Button {
                artworkTarget = game
                showPhotoPicker = true
            } label: {
                Label("Photos", systemImage: "photo.on.rectangle")
            }
            Button {
                artworkTarget = game
                showArtworkFiles = true
            } label: {
                Label("Files", systemImage: "folder")
            }
            Button {
                searchTarget = game
            } label: {
                Label("Search", systemImage: "magnifyingglass")
            }
            if library.hasCustomArtwork(game) {
                Button(role: .destructive) {
                    library.removeArtwork(for: game)
                } label: {
                    Label("Remove Artwork", systemImage: "trash")
                }
            }
        } label: {
            Label("Set Artwork", systemImage: "photo")
        }
        Button {
            renameText = game.title
            renameTarget = game
        } label: {
            Label("Rename", systemImage: "pencil")
        }
        Button(role: .destructive) {
            pendingDelete = game
        } label: {
            Label("Delete", systemImage: "trash")
        }
    }

    private var gridContent: some View {
        GeometryReader { geo in
            let columns = max(2, Int(geo.size.width / 180))
            let spacing: CGFloat = 16
            let side = (geo.size.width - spacing * CGFloat(columns + 1)) / CGFloat(columns)
            ScrollView {
                VStack(spacing: 16) {
                    if !hasBIOS {
                        BIOSBanner { startImport(.bios) }
                            .padding(16)
                            .ymirGlassCard()
                    }
                    LazyVGrid(
                        columns: Array(repeating: GridItem(.fixed(side), spacing: spacing), count: columns),
                        spacing: 20
                    ) {
                        ForEach(filteredGames) { game in
                            if editMode.isEditing {
                                // Reordering: the tiles wiggle and are dragged onto the place they should take
                                GameTile(game: game, isActive: game.url.path == activePath, side: side)
                                    .modifier(WiggleEffect(seed: game.id))
                                    .draggable(game.id)
                                    .dropDestination(for: String.self) { items, _ in
                                        guard let moved = items.first else { return false }
                                        withAnimation { library.moveGame(id: moved, onto: game.id) }
                                        return true
                                    }
                            } else {
                                Button {
                                    play(game)
                                } label: {
                                    GameTile(game: game, isActive: game.url.path == activePath, side: side)
                                }
                                .buttonStyle(.plain)
                                .contextMenu { gameMenu(game) }
                            }
                        }
                    }
                }
                .padding(.horizontal, spacing)
                .padding(.top, 8)
                .padding(.bottom, 24)
            }
            .background(YmirBackdrop())
        }
    }

    private func refresh() {
        library.reload()
        hasBIOS = YmirHost.hasBIOS
        activePath = YmirHost.isDiscLoaded ? YmirHost.loadedGamePath : nil
        savedStates = SaveStateCatalog.scan(games: library.games)
    }

    private func play(_ game: GameEntry, loadSlot slot: Int? = nil) {
        guard hasBIOS else {
            alert = AlertInfo(
                title: "BIOS Required",
                message: "Ymir needs a Sega Saturn BIOS (IPL ROM) to run games. Import one first.",
                actionTitle: "Import BIOS…",
                action: { startImport(.bios) }
            )
            return
        }
        if let slot {
            onLaunchState(game, slot)
        } else {
            onLaunch(game)
        }
    }

    private func startImport(_ kind: ImportKind) {
        importKind = kind
        showImporter = true
    }

    private func runImport(_ urls: [URL]) {
        let kind = importKind
        isImporting = true
        Task {
            let folder = kind == .games ? AppPaths.games : AppPaths.bios
            let outcome = await Task.detached(priority: .userInitiated) { () -> ImportService.Outcome in
                ImportService.copy(urls, to: folder)
            }.value

            var biosError: String?
            if kind == .bios {
                biosError = YmirHost.reloadBIOS()
            }
            refresh()
            isImporting = false

            if outcome.failed > 0 {
                alert = AlertInfo(
                    title: "Import Incomplete",
                    message: "\(outcome.failed) file(s) could not be copied."
                )
            } else if kind == .bios && !hasBIOS {
                alert = AlertInfo(
                    title: "BIOS Not Recognized",
                    message: biosError ?? "That file doesn't look like a valid Sega Saturn BIOS. Try a different image."
                )
            }
        }
    }
}

// MARK: - Rows and banners

private struct GameRow: View {
    let game: GameEntry
    let isActive: Bool

    var body: some View {
        HStack(spacing: 16) {
            CoverArtView(game: game, size: 60)
            VStack(alignment: .leading, spacing: 4) {
                Text(game.title)
                    .font(.body)
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.leading)
                    .lineLimit(2)
                Text(game.subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if isActive {
                Image(systemName: "play.circle.fill")
                    .font(.title3)
                    .foregroundStyle(.tint)
            }
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
    }
}

private struct GameTile: View {
    let game: GameEntry
    let isActive: Bool
    let side: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            CoverArtView(game: game, size: side)
                .shadow(color: .black.opacity(0.28), radius: 10, y: 6)
                .overlay(alignment: .bottomTrailing) {
                    if isActive {
                        Image(systemName: "play.fill")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.white)
                            .frame(width: 30, height: 30)
                            .ymirGlass(in: Circle(), interactive: false)
                            .padding(8)
                    }
                }
            // The name and the disc image type sit on a Liquid Glass card, like the groups in Settings. The title always
            // takes two lines, so that the cards of a row are as tall as each other
            VStack(alignment: .leading, spacing: 2) {
                FixedWidthTitle(text: game.title, width: max(0, side - 24))
                    .frame(width: max(0, side - 24), alignment: .leading)
                Text(game.format)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(width: max(0, side - 24), alignment: .leading)
            .padding(12)
            .ymirGlassCard(cornerRadius: 18)
        }
        .contentShape(Rectangle())
    }
}

private struct ResumeBar: View {
    let game: GameEntry
    let onResume: () -> Void

    var body: some View {
        Button(action: onResume) {
            HStack(spacing: 12) {
                CoverArtView(game: game, size: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text(game.title)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    Text("Tap to resume")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Image(systemName: "play.fill")
                    .font(.title3)
            }
            .foregroundStyle(.primary)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .ymirGlass(in: Capsule())
    }
}

private struct BIOSBanner: View {
    let onImport: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("BIOS required", systemImage: "exclamationmark.triangle.fill")
                .font(.headline)
                .foregroundStyle(.orange)
            Text("Ymir needs a Sega Saturn BIOS (IPL ROM) image to run games. Import one to get started.")
                .font(.subheadline)
                .foregroundStyle(.primary.opacity(0.85))
                .fixedSize(horizontal: false, vertical: true)
            Button {
                onImport()
            } label: {
                Text("Import BIOS…")
                    .lineLimit(1)
                    .fixedSize()
            }
            .ymirProminentButton()
        }
        .padding(.vertical, 6)
    }
}

private struct EmptyLibraryView: View {
    let importGames: () -> Void
    let openFiles: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "opticaldisc")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(.secondary)
            Text("No Games Yet")
                .font(.headline)
            Text("Import disc images (CUE/BIN, CHD, ISO, CCD, MDS) or drop them into the Ymir folder in the Files app.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            HStack(spacing: 12) {
                Button("Import Games…", action: importGames)
                    .ymirProminentButton()
                Button("Open Files", action: openFiles)
                    .ymirSecondaryButton()
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 18)
    }
}

enum FilesApp {
    /// Opens the Files app at this app's Documents folder.
    static func openDocuments() {
        open(AppPaths.documents)
    }

    /// Opens the Files app at a folder of this app.
    static func open(_ folder: URL) {
        if let url = URL(string: "shareddocuments://" + folder.path) {
            UIApplication.shared.open(url)
        }
    }
}

/// A small wiggle for the tiles of the library while they are being put in a new order.
private struct WiggleEffect: ViewModifier {
    let seed: String
    @State private var tilted = false

    func body(content: Content) -> some View {
        // (the angle differs a little from tile to tile, so they don't move in step)
        let angle = 0.9 + Double(abs(seed.hashValue) % 5) * 0.12
        content
            .rotationEffect(.degrees(tilted ? angle : -angle))
            .animation(.easeInOut(duration: 0.14).repeatForever(autoreverses: true), value: tilted)
            .onAppear { tilted = true }
    }
}
