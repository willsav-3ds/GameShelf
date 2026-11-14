import AppKit
import Foundation
import Observation

enum SortOrder: String, CaseIterable, Identifiable {
    case title = "Title"
    case recent = "Recently Played"
    case playtime = "Most Played"

    var id: String { rawValue }
}

@MainActor
@Observable
final class LibraryStore {
    struct Session: Codable {
        var seconds: TimeInterval = 0
        var lastPlayed: Date?
    }

    /// Everything GameShelf owns. Emulator and Steam files are only ever read.
    struct SavedState: Codable {
        var hidden: Set<String> = []
        var manualEntries: [ManualEntry] = []
        var sessions: [String: Session] = [:]
        var n64FolderPath: String?
        var favorites: Set<String> = []
        var customTitles: [String: String] = [:]
        var collections: [UserCollection] = []
        /// Collection keys in the order you arranged them. Unlisted ones follow in their default order.
        var collectionOrder: [String] = []
        var hiddenCollections: Set<String> = []

        init() {}

        /// Every field is optional on disk, so files written by older versions still load.
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            hidden = try container.decodeIfPresent(Set<String>.self, forKey: .hidden) ?? []
            manualEntries = try container.decodeIfPresent([ManualEntry].self, forKey: .manualEntries) ?? []
            sessions = try container.decodeIfPresent([String: Session].self, forKey: .sessions) ?? [:]
            n64FolderPath = try container.decodeIfPresent(String.self, forKey: .n64FolderPath)
            favorites = try container.decodeIfPresent(Set<String>.self, forKey: .favorites) ?? []
            customTitles = try container.decodeIfPresent([String: String].self, forKey: .customTitles) ?? [:]
            collections = try container.decodeIfPresent([UserCollection].self, forKey: .collections) ?? []
            collectionOrder = try container.decodeIfPresent([String].self, forKey: .collectionOrder) ?? []
            hiddenCollections = try container.decodeIfPresent(Set<String>.self, forKey: .hiddenCollections) ?? []
        }
    }

    private(set) var games: [Game] = []
    private(set) var isScanning = false
    private(set) var state = SavedState()
    /// Bumped when art changes so case views reload their covers.
    private(set) var coverRevision = 0
    var notice: LaunchNotice?

    struct LaunchNotice: Identifiable {
        let id = UUID()
        var title: String
        var message: String
    }

    private struct RunningSession {
        var gameID: String
        var startedAt: Date
    }

    private let stateURL: URL
    @ObservationIgnored private var runningSessions: [pid_t: RunningSession] = [:]

    private var fullscreen: Bool { UserDefaults.standard.bool(forKey: "launchFullscreen") }

    init() {
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("GameShelf")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        stateURL = folder.appendingPathComponent("library.json")
        if let data = try? Data(contentsOf: stateURL),
           let saved = try? JSONDecoder().decode(SavedState.self, from: data) {
            state = saved
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let pid = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier else { return }
            MainActor.assumeIsolated { self?.applicationTerminated(pid: pid) }
        }
    }

    var n64Folder: URL {
        if let path = state.n64FolderPath { return URL(fileURLWithPath: path) }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents/ROMs/N64")
    }

    var visibleGames: [Game] { games.filter { !state.hidden.contains($0.id) } }
    var hiddenGames: [Game] { games.filter { state.hidden.contains($0.id) } }

    func isFavorite(_ game: Game) -> Bool { state.favorites.contains(game.id) }

    /// Every collection in your chosen order, including hidden and empty ones. Used by Settings.
    var allCollectionIDs: [CollectionID] {
        var defaults: [CollectionID] = [.recent, .favorites]
        defaults += Platform.allCases.map(CollectionID.platform)
        defaults.append(.available)
        defaults += state.collections.map { .custom($0.id) }
        defaults.append(.all)
        let position = Dictionary(uniqueKeysWithValues: state.collectionOrder.enumerated().map { ($1, $0) })
        return defaults.enumerated().sorted { lhs, rhs in
            let left = position[lhs.element.key] ?? Int.max, right = position[rhs.element.key] ?? Int.max
            return left == right ? lhs.offset < rhs.offset : left < right
        }.map(\.element)
    }

    /// The collections to show, skipping hidden and empty ones.
    func collections(matching query: String, sortedBy order: SortOrder) -> [GameCollection] {
        allCollectionIDs.compactMap { id in
            guard !state.hiddenCollections.contains(id.key) else { return nil }
            let games = self.games(in: id, matching: query, sortedBy: order)
            return games.isEmpty ? nil : GameCollection(id: id, title: title(of: id), symbol: symbol(of: id), games: games)
        }
    }

    func games(in collection: CollectionID, matching query: String, sortedBy order: SortOrder) -> [Game] {
        let matches = visibleGames.filter { query.isEmpty || $0.title.localizedCaseInsensitiveContains(query) }
        switch collection {
        case .all:
            return sort(matches.filter(\.isInstalled), by: order)
        case .favorites:
            return sort(matches.filter { state.favorites.contains($0.id) }, by: order)
        case .recent:
            // Always newest first, whatever the sort setting: it's a "continue playing" row.
            return Array(sort(matches.filter { $0.lastPlayed != nil && $0.isInstalled }, by: .recent).prefix(20))
        case .available:
            return sort(matches.filter { !$0.isInstalled }, by: order)
        case .platform(let platform):
            return sort(matches.filter { $0.platform == platform && $0.isInstalled }, by: order)
        case .custom(let id):
            let members = Set(state.collections.first { $0.id == id }?.gameIDs ?? [])
            return sort(matches.filter { members.contains($0.id) }, by: order)
        }
    }

    func title(of collection: CollectionID) -> String {
        switch collection {
        case .all: "All Games"
        case .favorites: "Favorites"
        case .recent: "Continue Playing"
        case .available: "Ready to Install"
        case .platform(let platform): platform.title
        case .custom(let id): state.collections.first { $0.id == id }?.name ?? "Collection"
        }
    }

    func symbol(of collection: CollectionID) -> String {
        switch collection {
        case .all: "square.grid.2x2"
        case .favorites: "star"
        case .recent: "clock.arrow.circlepath"
        case .available: "arrow.down.circle"
        case .platform(let platform): platform.symbol
        case .custom(let id): state.collections.first { $0.id == id }?.symbol ?? "folder"
        }
    }

    private func sort(_ games: [Game], by order: SortOrder) -> [Game] {
        games.sorted { lhs, rhs in
            switch order {
            case .title:
                break
            case .recent:
                let left = lhs.lastPlayed ?? .distantPast, right = rhs.lastPlayed ?? .distantPast
                if left != right { return left > right }
            case .playtime:
                if lhs.playtime != rhs.playtime { return lhs.playtime > rhs.playtime }
            }
            return lhs.sortKey < rhs.sortKey
        }
    }

    func game(id: String) -> Game? { games.first { $0.id == id } }

    // MARK: Scanning

    func refresh() async {
        guard !isScanning else { return }
        isScanning = true
        defer { isScanning = false }
        let options = ScanOptions(n64Folder: n64Folder, manualEntries: state.manualEntries)
        let scanned = await Task.detached(priority: .userInitiated) { LibraryScanner.scan(options) }.value
        games = scanned.map(applySavedState)

        #if DEBUG
        if CommandLine.arguments.contains("--dump-library") {
            for game in games.sorted(by: { ($0.platform.rawValue, $0.sortKey) < ($1.platform.rawValue, $1.sortKey) }) {
                let serials = game.discs.map { $0.serial ?? "?" }.joined(separator: ",")
                print("\(game.platform.rawValue)\t\(game.title)\t\(game.discs.count)\t\(serials)\t\(Int(game.playtime))\t\(game.lastPlayed.map { "\($0)" } ?? "-")")
            }
            exit(0)
        }
        if let flag = CommandLine.arguments.firstIndex(of: "--play"), flag + 1 < CommandLine.arguments.count,
           let game = games.first(where: { $0.title.contains(CommandLine.arguments[flag + 1]) }) {
            await play(game)
            print("played: \(game.title) notice: \(notice?.title ?? "none")")
            fflush(stdout)
            exit(0)
        }
        if let flag = CommandLine.arguments.firstIndex(of: "--snapshot"), flag + 1 < CommandLine.arguments.count {
            let path = CommandLine.arguments[flag + 1]
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(12))
                guard let window = NSApp.windows.first(where: \.isVisible), let view = window.contentView else { exit(1) }
                @MainActor func capture(to path: String) {
                    guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
                    view.cacheDisplay(in: view.bounds, to: bitmap)
                    try? bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
                }
                capture(to: path)
                window.setContentSize(NSSize(width: 1180, height: 2300))
                try? await Task.sleep(for: .seconds(2))
                capture(to: path + ".tall.png")
                for (index, other) in NSApp.windows.filter({ $0.isVisible && $0 != window }).enumerated() {
                    guard let content = other.contentView,
                          let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) else { continue }
                    content.cacheDisplay(in: content.bounds, to: bitmap)
                    try? bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "\(path).window\(index).png"))
                }
                exit(0)
            }
        }
        #endif
    }

    private func applySavedState(_ game: Game) -> Game {
        var game = game
        if let title = state.customTitles[game.id] { game.title = title }
        guard let session = state.sessions[game.id] else { return game }
        if !game.tracksOwnPlaytime { game.playtime += session.seconds }
        if let last = session.lastPlayed, last > (game.lastPlayed ?? .distantPast) { game.lastPlayed = last }
        return game
    }

    // MARK: Editing the library

    func setHidden(_ hidden: Bool, game: Game) {
        if hidden { state.hidden.insert(game.id) } else { state.hidden.remove(game.id) }
        save()
    }

    /// Adds a port or any other app or executable by hand. Returns false when the file can't be run.
    @discardableResult
    func addManual(url: URL) -> Bool {
        let isApp = url.pathExtension == "app"
        guard isApp || FileManager.default.isExecutableFile(atPath: url.path) else { return false }
        let path = url.standardizedFileURL.path
        if !state.manualEntries.contains(where: { $0.path == path }) {
            state.manualEntries.append(ManualEntry(title: url.deletingPathExtension().lastPathComponent, path: path))
            save()
        }
        return true
    }

    func removeManual(_ entry: ManualEntry) {
        state.manualEntries.removeAll { $0 == entry }
        save()
    }

    func setN64Folder(_ url: URL) {
        state.n64FolderPath = url.path
        save()
    }

    func toggleFavorite(_ game: Game) {
        if state.favorites.contains(game.id) { state.favorites.remove(game.id) } else { state.favorites.insert(game.id) }
        save()
    }

    /// An empty or unchanged title goes back to the scanned name.
    func rename(_ game: Game, to title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        state.customTitles[game.id] = trimmed.isEmpty ? nil : trimmed
        save()
        Task { await refresh() }
    }

    func hasCustomTitle(_ game: Game) -> Bool { state.customTitles[game.id] != nil }

    @discardableResult
    func createCollection(named name: String, symbol: String = "folder", with game: Game? = nil) -> UserCollection {
        let collection = UserCollection(name: name, symbol: symbol, gameIDs: game.map { [$0.id] } ?? [])
        state.collections.append(collection)
        save()
        return collection
    }

    func updateCollection(_ collection: UserCollection) {
        guard let index = state.collections.firstIndex(where: { $0.id == collection.id }) else { return }
        state.collections[index] = collection
        save()
    }

    func deleteCollection(_ id: UUID) {
        state.collections.removeAll { $0.id == id }
        state.collectionOrder.removeAll { $0 == CollectionID.custom(id).key }
        save()
    }

    func toggle(_ game: Game, in collectionID: UUID) {
        guard let index = state.collections.firstIndex(where: { $0.id == collectionID }) else { return }
        if let position = state.collections[index].gameIDs.firstIndex(of: game.id) {
            state.collections[index].gameIDs.remove(at: position)
        } else {
            state.collections[index].gameIDs.append(game.id)
        }
        save()
    }

    func setCollectionOrder(_ ids: [CollectionID]) {
        state.collectionOrder = ids.map(\.key)
        save()
    }

    func setCollectionHidden(_ hidden: Bool, _ id: CollectionID) {
        if hidden { state.hiddenCollections.insert(id.key) } else { state.hiddenCollections.remove(id.key) }
        save()
    }

    func isCollectionHidden(_ id: CollectionID) -> Bool { state.hiddenCollections.contains(id.key) }

    func setArt(_ kind: ArtKind, from url: URL, for game: Game) async {
        do {
            try await ArtStore.shared.setCustom(kind, from: url, for: game)
            coverRevision += 1
        } catch {
            notice = LaunchNotice(title: "Couldn't use that image", message: error.localizedDescription)
        }
    }

    func resetArt(_ kind: ArtKind, for game: Game) async {
        await ArtStore.shared.removeCustom(kind, for: game)
        coverRevision += 1
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(state) else { return }
        try? data.write(to: stateURL, options: .atomic)
    }

    // MARK: Launching

    func play(_ game: Game, disc: Disc? = nil) async {
        do {
            switch game.launch {
            case .steam(let appID):
                // Steam asks where to put a game that isn't installed, then downloads it.
                guard let url = URL(string: "steam://\(game.isInstalled ? "run" : "install")/\(appID)") else { return }
                NSWorkspace.shared.open(url)
            case .app(let url):
                track(try await launch(appAt: url, arguments: []), game: game)
            case .executable(let url):
                try launch(executable: url, game: game)
            case .emulator(let emulator):
                guard let rom = disc?.url ?? game.discs.first?.url else { return }
                try await launch(rom: rom, with: emulator, game: game)
            }
        } catch {
            notice = LaunchNotice(title: "Couldn't start \(game.title)", message: error.localizedDescription)
        }
    }

    private func launch(rom: URL, with emulator: Emulator, game: Game) async throws {
        guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: emulator.bundleID) else {
            throw LaunchError.emulatorMissing(emulator)
        }
        switch emulator {
        case .duckStation, .pcsx2:
            var arguments = ["-batch"]
            if fullscreen { arguments.append("-fullscreen") }
            track(try await launch(appAt: appURL, arguments: arguments + ["--", rom.path]), game: game)
        case .gopher64:
            if let readable = cloneIntoGopherContainer(rom) {
                var arguments = fullscreen ? ["--fullscreen"] : []
                arguments.append(readable.path)
                track(try await launch(appAt: appURL, arguments: arguments), game: game)
            } else {
                // Without container access, a Finder drag is the sandbox-approved way to hand over a ROM.
                _ = try await launch(appAt: appURL, arguments: [])
                NSWorkspace.shared.activateFileViewerSelecting([rom])
                notice = LaunchNotice(
                    title: "Drag the ROM into Gopher64",
                    message: "macOS didn't let GameShelf hand the ROM to Gopher64, so it can't start automatically. "
                        + "It's selected in Finder: drag it onto the Gopher64 window to start playing.\n\n"
                        + "To make this one click, choose Allow when macOS asks if GameShelf can access data from other apps, "
                        + "or add GameShelf to Full Disk Access in System Settings › Privacy & Security."
                )
            }
        }
    }

    /// Gopher64 is sandboxed and can only read a command-line path from inside its own container.
    /// It ignores files sent by Launch Services ("Open With"), and its gopher64-cli helper only runs as
    /// its own child, so an APFS clone in the container is the one route that works. The clone uses
    /// no extra disk space. Returns nil if macOS refuses access to the container.
    private func cloneIntoGopherContainer(_ rom: URL) -> URL? {
        let manager = FileManager.default
        let folder = manager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Containers/\(Emulator.gopher64.bundleID)/Data/GameShelf ROMs")
        let destination = folder.appendingPathComponent(rom.lastPathComponent)
        if manager.fileExists(atPath: destination.path) { return destination }
        do {
            try manager.createDirectory(at: folder, withIntermediateDirectories: true)
            try manager.copyItem(at: rom, to: destination)
            return destination
        } catch {
            return nil
        }
    }

    private func launch(appAt url: URL, arguments: [String]) async throws -> NSRunningApplication {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.arguments = arguments
        configuration.activates = true
        // Arguments are dropped when macOS reuses a running copy of the app.
        configuration.createsNewApplicationInstance = !arguments.isEmpty
        return try await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
    }

    private func launch(executable url: URL, game: Game) throws {
        let process = Process()
        process.executableURL = url
        process.currentDirectoryURL = url.deletingLastPathComponent()
        let started = Date()
        let gameID = game.id
        process.terminationHandler = { [weak self] _ in
            Task { @MainActor in self?.endSession(gameID: gameID, startedAt: started) }
        }
        try process.run()
    }

    private func track(_ app: NSRunningApplication, game: Game) {
        runningSessions[app.processIdentifier] = RunningSession(gameID: game.id, startedAt: Date())
    }

    private func applicationTerminated(pid: pid_t) {
        guard let session = runningSessions.removeValue(forKey: pid) else { return }
        endSession(gameID: session.gameID, startedAt: session.startedAt)
    }

    private func endSession(gameID: String, startedAt: Date) {
        var session = state.sessions[gameID] ?? Session()
        session.seconds += Date().timeIntervalSince(startedAt)
        session.lastPlayed = Date()
        state.sessions[gameID] = session
        save()
        Task { await refresh() }
    }

    private enum LaunchError: LocalizedError {
        case emulatorMissing(Emulator)

        var errorDescription: String? {
            switch self {
            case .emulatorMissing(let emulator): "\(emulator.name) isn't installed."
            }
        }
    }
}
