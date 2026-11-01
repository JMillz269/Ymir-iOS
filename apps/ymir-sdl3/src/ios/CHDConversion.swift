import SwiftUI
import UIKit

// MARK: - Running one conversion (off the main actor)

/// Lets the main actor stop a conversion that runs on another thread.
final class ConversionCancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }
}

struct ConversionOutcome: Sendable {
    enum Status: Sendable {
        case done
        case cancelled
        case failed
    }

    let status: Status
    let message: String
    let outputBytes: Int64
    let rawBytes: Int64
}

/// Starts a conversion and reports back from the thread it runs on. Not tied to the main actor on purpose: the
/// callbacks are called from the converter's thread.
enum CHDJobRunner {
    /// `progress` gets how far along it is (0 to 1) and whether it is checking the new file (the second half).
    static func run(source: URL, destination: URL, level: Int, cancel: ConversionCancelFlag,
                    progress: @escaping @Sendable (Double, Bool) -> Void,
                    finished: @escaping @Sendable (ConversionOutcome) -> Void) {
        var lastReported = -1.0
        YmirHost.convertDiscImage(
            at: source.path, toCHDAt: destination.path, level: level,
            progress: { done, total in
                if cancel.isCancelled {
                    return false
                }
                let fraction = total > 0 ? Double(done) / Double(total) : 0
                if fraction - lastReported >= 0.004 || fraction >= 1 {
                    lastReported = fraction
                    progress(fraction, done * 2 > total)
                }
                return true
            },
            completion: { status, message, outputBytes, rawBytes in
                let kind: ConversionOutcome.Status = status == 0 ? .done : status == 1 ? .cancelled : .failed
                finished(ConversionOutcome(status: kind, message: message,
                                           outputBytes: Int64(clamping: outputBytes), rawBytes: Int64(clamping: rawBytes)))
            })
    }
}

// MARK: - The converter

/// What the player is told when the games in the queue are done.
struct ConversionReport: Identifiable, Equatable {
    let id = UUID()
    let title: String
    let message: String
}

/// Converts the games of the library to CHD files, one after the other, and takes care of what the app keeps about them:
/// the new file takes the place of the old one in the library, with its name, play time and save states.
@MainActor
final class CHDConverter: ObservableObject {
    static let shared = CHDConverter()

    enum Level: Int, CaseIterable, Identifiable {
        case fast = 5
        case balanced = 7
        case smallest = 9

        var id: Int { rawValue }

        var label: String {
            switch self {
            case .fast: return "Fast"
            case .balanced: return "Balanced"
            case .smallest: return "Smallest"
            }
        }
    }

    private struct Result {
        let title: String
        let savedBytes: Int64
        let failure: String?
    }

    @Published private(set) var queue: [GameEntry] = []
    @Published private(set) var current: GameEntry?
    @Published private(set) var progress = 0.0
    @Published private(set) var isVerifying = false
    /// Counts the games converted, for screens to reload their lists
    @Published private(set) var completedCount = 0
    /// Set when the queue is done; whoever shows it clears it
    @Published var report: ConversionReport?

    @Published var level: Level {
        didSet { UserDefaults.standard.set(level.rawValue, forKey: Self.levelKey) }
    }

    /// Whether the original files are kept (moved to the originals folder) instead of deleted
    @Published var keepOriginals: Bool {
        didSet { UserDefaults.standard.set(keepOriginals, forKey: Self.keepKey) }
    }

    private static let levelKey = "ymir.chd.level"
    private static let keepKey = "ymir.chd.keepOriginals"

    private var results: [Result] = []
    private var cancelFlag: ConversionCancelFlag?

    private init() {
        let stored = UserDefaults.standard.object(forKey: Self.levelKey) as? Int
        level = stored.flatMap(Level.init(rawValue:)) ?? .smallest
        keepOriginals = UserDefaults.standard.bool(forKey: Self.keepKey)
    }

    var isAvailable: Bool { YmirHost.chdConversionAvailable }
    var isBusy: Bool { current != nil }

    static func canConvert(_ game: GameEntry) -> Bool {
        game.url.pathExtension.lowercased() != "chd"
    }

    func isQueued(_ game: GameEntry) -> Bool {
        current?.id == game.id || queue.contains { $0.id == game.id }
    }

    /// Adds games to the queue (the ones that are CHD files already, or queued already, are left out).
    func enqueue(_ games: [GameEntry]) {
        let wanted = games.filter { Self.canConvert($0) && !isQueued($0) }
        guard !wanted.isEmpty else { return }
        if !isBusy {
            results = []
        }
        queue.append(contentsOf: wanted)
        startNext()
    }

    /// Stops what is running and empties the queue.
    func cancelAll() {
        queue.removeAll()
        cancelFlag?.cancel()
    }

    // MARK: Running the queue

    private func startNext() {
        guard current == nil else { return }
        guard !queue.isEmpty else {
            UIApplication.shared.isIdleTimerDisabled = false
            makeReport()
            return
        }

        let game = queue.removeFirst()
        current = game
        progress = 0
        isVerifying = false
        // (the screen stays on: the conversion goes on in the background only for a short while)
        UIApplication.shared.isIdleTimerDisabled = true

        let destination = game.url.deletingPathExtension().appendingPathExtension("chd")
        if let problem = preflight(game, destination: destination) {
            results.append(Result(title: game.title, savedBytes: 0, failure: problem))
            current = nil
            startNext()
            return
        }

        let partial = destination.appendingPathExtension("part")
        try? FileManager.default.removeItem(at: partial)
        let flag = ConversionCancelFlag()
        cancelFlag = flag
        CHDJobRunner.run(
            source: game.url, destination: partial, level: level.rawValue, cancel: flag,
            progress: { [weak self] fraction, verifying in
                Task { @MainActor in self?.update(game, fraction: fraction, verifying: verifying) }
            },
            finished: { [weak self] outcome in
                Task { @MainActor in self?.finish(game, destination: destination, partial: partial, outcome: outcome) }
            })
    }

    /// Checks what can be checked before starting; returns what is wrong, if anything.
    private func preflight(_ game: GameEntry, destination: URL) -> String? {
        if YmirHost.isDiscLoaded, let loaded = YmirHost.loadedGamePath, loaded == game.url.path {
            return "The game is running. Close it first."
        }
        if FileManager.default.fileExists(atPath: destination.path) {
            return "A file named \(destination.lastPathComponent) is there already."
        }
        // The new file is smaller than the disc data, but both exist until the conversion is over
        let needed = game.sizeBytes + 64 * 1024 * 1024
        let values = try? game.url.deletingLastPathComponent()
            .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        if let free = values?.volumeAvailableCapacityForImportantUsage, free < needed {
            let text = ByteCountFormatter.string(fromByteCount: needed, countStyle: .file)
            return "There isn't enough free storage (about \(text) is needed)."
        }
        return nil
    }

    private func update(_ game: GameEntry, fraction: Double, verifying: Bool) {
        guard current?.id == game.id else { return }
        progress = fraction
        isVerifying = verifying
    }

    private func finish(_ game: GameEntry, destination: URL, partial: URL, outcome: ConversionOutcome) {
        defer {
            current = nil
            cancelFlag = nil
            startNext()
        }
        let fm = FileManager.default

        switch outcome.status {
        case .cancelled:
            try? fm.removeItem(at: partial)
        case .failed:
            try? fm.removeItem(at: partial)
            results.append(Result(title: game.title, savedBytes: 0, failure: outcome.message))
        case .done:
            do {
                try fm.moveItem(at: partial, to: destination)
            } catch {
                try? fm.removeItem(at: partial)
                results.append(Result(title: game.title, savedBytes: 0,
                                      failure: "The new file couldn't be put in place: \(error.localizedDescription)"))
                return
            }
            adopt(game, as: destination)
            results.append(Result(title: game.title, savedBytes: game.sizeBytes - outcome.outputBytes, failure: nil))
            completedCount += 1
        }
    }

    /// The CHD file takes the place of the game's files: what the app remembers is handed over, and the old files are
    /// deleted or put away.
    private func adopt(_ old: GameEntry, as newFile: URL) {
        let new = GameEntry(url: newFile, sizeBytes: 0)
        GameLibrary.transferMetadata(from: old, toRelativePath: new.relativePath)
        SaveStateCatalog.relink(from: old.relativePath, to: new.relativePath)

        // Files that other games use as well (two cue sheets of one image) stay
        let others = GameLibrary().games.filter { $0.id != old.id }
        let shared = Set(others.flatMap { $0.relatedFiles().map(\.path) })

        let fm = FileManager.default
        let folder = AppPaths.originals.appendingPathComponent(old.stem, isDirectory: true)
        for file in old.relatedFiles() where !shared.contains(file.path) {
            if keepOriginals {
                try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
                var target = folder.appendingPathComponent(file.lastPathComponent)
                var counter = 2
                while fm.fileExists(atPath: target.path) {
                    target = folder.appendingPathComponent("\(counter)-" + file.lastPathComponent)
                    counter += 1
                }
                try? fm.moveItem(at: file, to: target)
            } else {
                try? fm.removeItem(at: file)
            }
        }
    }

    private func makeReport() {
        guard !results.isEmpty else { return }
        let done = results.filter { $0.failure == nil }
        let failed = results.filter { $0.failure != nil }
        let saved = done.reduce(Int64(0)) { $0 + $1.savedBytes }
        let size = ByteCountFormatter.string(fromByteCount: max(saved, 0), countStyle: .file)

        var lines: [String] = []
        if !done.isEmpty {
            lines.append(done.count == 1 ? "\(done[0].title) is a CHD file now. It saves \(size)."
                                         : "\(done.count) games are CHD files now. They save \(size).")
            if keepOriginals {
                lines.append("The original files are in the originals folder.")
            }
        }
        for item in failed {
            lines.append("\(item.title) wasn't converted: \(item.failure ?? "").")
        }
        let title = failed.isEmpty ? "Converted" : done.isEmpty ? "Couldn't Convert" : "Converted, With Problems"
        results = []
        report = ConversionReport(title: title, message: lines.joined(separator: "\n"))
    }
}

// MARK: - The bar in the library

/// Shows what is being converted, over the library.
struct ConversionBar: View {
    @ObservedObject var converter: CHDConverter

    var body: some View {
        if let game = converter.current {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("\(converter.isVerifying ? "Checking" : "Converting") \(game.title)")
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    ProgressView(value: converter.progress)
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Button {
                    converter.cancelAll()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Cancel conversion")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .ymirGlass(in: RoundedRectangle(cornerRadius: 22, style: .continuous), interactive: false)
        }
    }

    private var detail: String {
        var text = String(format: "%.0f%%", converter.progress * 100)
        if !converter.queue.isEmpty {
            text += " · \(converter.queue.count) more waiting"
        }
        return text
    }
}

// MARK: - The settings page

/// Settings > Convert to CHD
struct CHDConversionSettingsView: View {
    @ObservedObject private var converter = CHDConverter.shared
    @StateObject private var library = GameLibrary()
    @State private var originalsBytes: Int64 = 0
    @State private var confirmDeleteOriginals = false
    @State private var report: ConversionReport?

    private var candidates: [GameEntry] {
        library.games.filter { CHDConverter.canConvert($0) }
    }

    private func sizeText(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private func reload() {
        library.reload()
        Task {
            let size = await Task.detached(priority: .utility) { () -> Int64 in
                Self.folderSize(AppPaths.originals)
            }.value
            originalsBytes = size
        }
    }

    private nonisolated static func folderSize(_ folder: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(
            at: folder, includingPropertiesForKeys: [.fileSizeKey], options: []) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            total += Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
        }
        return total
    }

    var body: some View {
        GlassForm {
            if let game = converter.current {
                GlassSection(content: {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("\(converter.isVerifying ? "Checking" : "Converting") \(game.title)")
                            .font(.headline)
                        ProgressView(value: converter.progress)
                        Text(String(format: "%.0f%%", converter.progress * 100)
                             + (converter.queue.isEmpty ? "" : " · \(converter.queue.count) more waiting"))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    Button(role: .destructive) {
                        converter.cancelAll()
                    } label: {
                        Text("Cancel")
                            .foregroundStyle(.red)
                    }
                    .buttonStyle(.plain)
                }, header: {
                    Text("In Progress")
                }, footer: {
                    WrappedText("Keep Ymir open while it works; the screen stays on. The new file is read back and checked against the disc before the original is touched.")
                })
            }

            GlassSection(content: {
                if candidates.isEmpty {
                    Text("Every game is a CHD file already.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(candidates) { game in
                        HStack(spacing: 12) {
                            CoverArtView(game: game, size: 38)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(game.title)
                                    .lineLimit(2)
                                    .fixedSize(horizontal: false, vertical: true)
                                Text(game.subtitle)
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            if converter.isQueued(game) {
                                Text(converter.current?.id == game.id ? "Working…" : "Waiting")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .fixedSize()
                            } else {
                                Button {
                                    converter.enqueue([game])
                                } label: {
                                    Text("Convert")
                                        .lineLimit(1)
                                        .fixedSize()
                                }
                                .ymirSecondaryButton()
                                .controlSize(.small)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                    Button {
                        converter.enqueue(candidates)
                    } label: {
                        Label("Convert All (\(candidates.count))", systemImage: "archivebox")
                    }
                    .disabled(candidates.allSatisfy { converter.isQueued($0) })
                }
            }, header: {
                Text("Games")
            }, footer: {
                WrappedText("CHD files hold the same disc in a compressed form: a game usually takes about half the storage, and plays the same, with the same save states. You can also convert a game from its long-press menu in the library.")
            })

            GlassSection(content: {
                GlassPicker("Compression", selection: $converter.level) {
                    ForEach(CHDConverter.Level.allCases) { level in
                        Text(level.label).tag(level)
                    }
                }
                Toggle("Keep the Originals", isOn: $converter.keepOriginals)
            }, header: {
                Text("Options")
            }, footer: {
                WrappedText("Smallest takes the longest and makes the smallest files. When the originals are kept, they are moved to the originals folder (visible in the Files app) instead of being deleted.")
            })

            if originalsBytes > 0 {
                GlassSection(content: {
                    HStack {
                        Text("Originals Kept")
                        Spacer()
                        Text(sizeText(originalsBytes))
                            .foregroundStyle(.secondary)
                    }
                    Button {
                        FilesApp.open(AppPaths.originals)
                    } label: {
                        Label("Show Originals in Files", systemImage: "folder")
                    }
                    Button(role: .destructive) {
                        confirmDeleteOriginals = true
                    } label: {
                        Text("Delete All Originals…")
                            .foregroundStyle(.red)
                    }
                    .buttonStyle(.plain)
                }, header: {
                    Text("Storage")
                })
            }
        }
        .navigationTitle("Convert to CHD")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { reload() }
        .onChange(of: converter.completedCount) { _ in reload() }
        .onChange(of: converter.report) { value in
            if let value {
                report = value
                converter.report = nil
            }
        }
        .alert(item: $report) { report in
            Alert(title: Text(report.title), message: Text(report.message), dismissButton: .default(Text("OK")))
        }
        .confirmationDialog(
            "Delete the originals?", isPresented: $confirmDeleteOriginals, titleVisibility: .visible
        ) {
            Button("Delete \(sizeText(originalsBytes))", role: .destructive) {
                try? FileManager.default.removeItem(at: AppPaths.originals)
                reload()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The disc images of the games you converted are removed from this device. The CHD files stay.")
        }
    }
}
