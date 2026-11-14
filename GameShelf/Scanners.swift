import AppKit
import Foundation

struct ManualEntry: Codable, Hashable, Sendable {
    var title: String
    var path: String
}

struct ScanOptions: Sendable {
    var n64Folder: URL
    var manualEntries: [ManualEntry]
}

enum LibraryScanner {
    private static let home = FileManager.default.homeDirectoryForCurrentUser
    private static let appSupport = home.appendingPathComponent("Library/Application Support")

    static func scan(_ options: ScanOptions) -> [Game] {
        let ports = scanPorts(manual: options.manualEntries)
        let portPaths = Set(ports.compactMap { $0.location?.path })
        return scanDuckStation() + scanPCSX2() + scanN64(folder: options.n64Folder)
            + ports + scanSteam() + scanMacGames(excluding: portPaths)
    }

    // MARK: Emulators

    private static func scanDuckStation() -> [Game] {
        let folder = appSupport.appendingPathComponent("DuckStation")
        guard let config = INIFile(url: folder.appendingPathComponent("settings.ini")) else { return [] }
        return discGames(
            config: config,
            playtime: PlaytimeFile.read(folder.appendingPathComponent("playtime.dat")),
            extensions: ["cue", "chd", "iso", "img", "ecm", "mds", "pbp", "m3u", "bin"],
            emulator: .duckStation,
            platform: .ps1,
            artSystem: "Sony_-_PlayStation",
            covers: folder.appendingPathComponent("covers")
        )
    }

    private static func scanPCSX2() -> [Game] {
        let folder = appSupport.appendingPathComponent("PCSX2")
        guard let config = INIFile(url: folder.appendingPathComponent("inis/PCSX2.ini")) else { return [] }
        return discGames(
            config: config,
            playtime: PlaytimeFile.read(folder.appendingPathComponent("inis/playtime.dat")),
            extensions: ["iso", "chd", "cso", "zso", "gz", "cue", "mdf", "bin", "m3u"],
            emulator: .pcsx2,
            platform: .ps2,
            artSystem: "Sony_-_PlayStation_2",
            covers: folder.appendingPathComponent("covers")
        )
    }

    /// Scans the same folders the emulator's own game list uses, folding multi-disc sets into one case.
    private static func discGames(
        config: INIFile,
        playtime: [String: PlaytimeEntry],
        extensions: Set<String>,
        emulator: Emulator,
        platform: Platform,
        artSystem: String,
        covers: URL
    ) -> [Game] {
        var files: [URL] = []
        for path in config.all("GameList", "RecursivePaths") where !path.isEmpty {
            files += findFiles(in: URL(fileURLWithPath: path), extensions: extensions, recursive: true)
        }
        for path in config.all("GameList", "Paths") where !path.isEmpty {
            files += findFiles(in: URL(fileURLWithPath: path), extensions: extensions, recursive: false)
        }

        // A .cue and its tracks are one disc, and so are an .m3u and its entries.
        let cueTracks = files.filter { $0.pathExtension.lowercased() == "cue" }.flatMap(DiscSerial.cueTracks)
        let claimed = Set(cueTracks.map(\.standardizedFileURL.path))
        let discFiles = Set(files.map(\.standardizedFileURL)).filter { url in
            guard !claimed.contains(url.path) else { return false }
            return url.pathExtension.lowercased() != "bin" || isLikelyDiscImage(url)
        }

        var groups: [String: [URL]] = [:]
        for url in discFiles {
            let name = url.deletingPathExtension().lastPathComponent
            groups[GameTitle.discGroupKey(name), default: []].append(url)
        }

        return groups.values.map { urls in
            let ordered = urls.sorted { lhs, rhs in
                let left = GameTitle.discNumber(lhs.deletingPathExtension().lastPathComponent) ?? 0
                let right = GameTitle.discNumber(rhs.deletingPathExtension().lastPathComponent) ?? 0
                return left == right ? lhs.path < rhs.path : left < right
            }
            let discs = ordered.map { url -> Disc in
                let name = url.deletingPathExtension().lastPathComponent
                let label = GameTitle.discNumber(name).map { "Disc \($0)" } ?? "Disc"
                return Disc(label: label, url: url, serial: DiscSerial.read(url))
            }
            let firstName = ordered[0].deletingPathExtension().lastPathComponent
            let entries = discs.compactMap { $0.serial.flatMap { playtime[$0] } }
            return Game(
                id: "\(emulator.rawValue):\(ordered[0].path)",
                title: GameTitle.clean(firstName),
                platform: platform,
                launch: .emulator(emulator),
                discs: discs,
                art: .libretro(system: artSystem, name: firstName),
                sourceLabel: emulator.name,
                location: ordered[0],
                localCoverFolder: covers,
                playtime: entries.reduce(0) { $0 + $1.seconds },
                lastPlayed: entries.compactMap(\.lastPlayed).max()
            )
        }
    }

    /// Gopher64 keeps no game list, so its games come from a ROM folder.
    private static func scanN64(folder: URL) -> [Game] {
        findFiles(in: folder, extensions: ["z64", "n64", "v64", "zip", "7z"], recursive: true).map { url in
            let name = url.deletingPathExtension().lastPathComponent
            return Game(
                id: "gopher64:\(url.path)",
                title: GameTitle.clean(name),
                platform: .n64,
                launch: .emulator(.gopher64),
                discs: [Disc(label: "Cartridge", url: url, serial: nil)],
                art: .libretro(system: "Nintendo_-_Nintendo_64", name: name),
                sourceLabel: Emulator.gopher64.name,
                location: url
            )
        }
    }

    private static func findFiles(in folder: URL, extensions: Set<String>, recursive: Bool) -> [URL] {
        let manager = FileManager.default
        var options: FileManager.DirectoryEnumerationOptions = [.skipsHiddenFiles, .skipsPackageDescendants]
        if !recursive { options.insert(.skipsSubdirectoryDescendants) }
        guard let walker = manager.enumerator(at: folder, includingPropertiesForKeys: [.isDirectoryKey], options: options) else {
            return []
        }
        var found: [URL] = []
        for case let url as URL in walker {
            // BIOS dumps live beside games but aren't games.
            if url.lastPathComponent.lowercased().contains("bios") {
                if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true { walker.skipDescendants() }
                continue
            }
            if extensions.contains(url.pathExtension.lowercased()) { found.append(url) }
        }
        return found
    }

    /// Filters stray firmware and audio-track .bins that no .cue claims.
    private static func isLikelyDiscImage(_ url: URL) -> Bool {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        return size >= 32 * 1024 * 1024
    }

    // MARK: Steam

    /// Tools and runtimes Steam installs alongside games.
    private static let steamNonGames: Set<String> = ["431730", "228980", "1070560", "1391110", "1628350", "480"]

    private static func scanSteam() -> [Game] {
        let steam = appSupport.appendingPathComponent("Steam")
        var libraries = [steam]
        if let folders = VDF.read(steam.appendingPathComponent("steamapps/libraryfolders.vdf"))?["libraryfolders"]?.children {
            for folder in folders.values {
                if let path = folder["path"]?.string {
                    libraries.append(URL(fileURLWithPath: path))
                }
            }
        }

        let playtimes = readSteamPlaytimes(steam: steam)
        var games: [String: Game] = [:]
        for library in libraries {
            let apps = library.appendingPathComponent("steamapps")
            let manifests = (try? FileManager.default.contentsOfDirectory(at: apps, includingPropertiesForKeys: nil)) ?? []
            for manifest in manifests where manifest.lastPathComponent.hasPrefix("appmanifest_") {
                guard let state = VDF.read(manifest)?["AppState"],
                      let appID = state["appid"]?.string,
                      let name = state["name"]?.string,
                      !steamNonGames.contains(appID),
                      !name.hasPrefix("Steamworks"), !name.hasPrefix("Steam Linux Runtime") else { continue }
                var location: URL?
                if let directory = state["installdir"]?.string {
                    location = apps.appendingPathComponent("common/\(directory)")
                }
                games[appID] = Game(
                    id: "steam:\(appID)",
                    title: name,
                    platform: .steam,
                    launch: .steam(appID: appID),
                    art: .steam(appID: appID),
                    sourceLabel: "Steam",
                    location: location,
                    playtime: playtimes[appID]?.seconds ?? 0,
                    lastPlayed: playtimes[appID]?.lastPlayed
                )
            }
        }

        // Steam's own cache lists the rest of your library. Only games with a Mac version can be installed here.
        for app in SteamAppInfo.read(steam.appendingPathComponent("appcache/appinfo.vdf")) {
            guard games[app.id] == nil, !steamNonGames.contains(app.id), app.type.lowercased() == "game",
                  app.systems.lowercased().split(separator: ",").contains("macos") else { continue }
            games[app.id] = Game(
                id: "steam:\(app.id)",
                title: app.name,
                platform: .steam,
                launch: .steam(appID: app.id),
                art: .steam(appID: app.id),
                sourceLabel: "Steam · Not installed",
                playtime: playtimes[app.id]?.seconds ?? 0,
                lastPlayed: playtimes[app.id]?.lastPlayed,
                isInstalled: false
            )
        }
        return Array(games.values)
    }

    /// Steam stores playtime per signed-in account. A game's figure is taken from the
    /// account with the most time on it, so old logins on this Mac don't hide it.
    private static func readSteamPlaytimes(steam: URL) -> [String: PlaytimeEntry] {
        let userdata = steam.appendingPathComponent("userdata")
        let accounts = (try? FileManager.default.contentsOfDirectory(at: userdata, includingPropertiesForKeys: nil)) ?? []
        var result: [String: PlaytimeEntry] = [:]
        for account in accounts {
            let file = account.appendingPathComponent("config/localconfig.vdf")
            guard let root = VDF.read(file),
                  let apps = root["UserLocalConfigStore"]?["Software"]?["Valve"]?["Steam"]?["apps"]?.children else { continue }
            for (appID, values) in apps {
                let minutes = values["playtime"]?.string.flatMap(TimeInterval.init) ?? 0
                let last = values["lastplayed"]?.string.flatMap(TimeInterval.init) ?? 0
                guard minutes > 0 || last > 0 else { continue }
                if minutes * 60 >= (result[appID]?.seconds ?? 0) {
                    result[appID] = PlaytimeEntry(
                        seconds: minutes * 60,
                        lastPlayed: last > 0 ? Date(timeIntervalSince1970: last) : nil
                    )
                }
            }
        }
        return result
    }

    // MARK: Mac games

    private static let notGames: Set<String> = [
        "com.github.stenzek.duckstation", "net.pcsx2.pcsx2", "io.github.gopher64.gopher64",
        "com.valvesoftware.steam", "com.blizzard.bna", "com.williamsavner.GameShelf",
    ]

    /// Games whose bundles don't declare the games category, relative to the app folders.
    private static let knownMacGames = [
        "Minecraft.app", "Prism Launcher.app", "Roblox.app", "Hearthstone/Hearthstone.app",
    ]

    private static func scanMacGames(excluding: Set<String>) -> [Game] {
        let manager = FileManager.default
        let folders = [URL(fileURLWithPath: "/Applications"), home.appendingPathComponent("Applications")]
        var apps: [URL] = []

        for folder in folders {
            let contents = (try? manager.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
            apps += contents.filter { url in
                guard url.pathExtension == "app", let info = Bundle(url: url)?.infoDictionary else { return false }
                let category = info["LSApplicationCategoryType"] as? String ?? ""
                return category.contains("games") && !notGames.contains(info["CFBundleIdentifier"] as? String ?? "")
            }
            apps += knownMacGames.map { folder.appendingPathComponent($0) }.filter { manager.fileExists(atPath: $0.path) }

            // World of Warcraft installs one app per game flavour, e.g. _retail_/World of Warcraft.app.
            let warcraft = folder.appendingPathComponent("World of Warcraft")
            for flavour in (try? manager.contentsOfDirectory(at: warcraft, includingPropertiesForKeys: nil)) ?? [] {
                let bundles = (try? manager.contentsOfDirectory(at: flavour, includingPropertiesForKeys: nil)) ?? []
                apps += bundles.filter { $0.pathExtension == "app" && $0.lastPathComponent.hasPrefix("World of Warcraft") }
            }
        }

        var seen = excluding
        return apps.compactMap { url in
            guard seen.insert(url.standardizedFileURL.path).inserted else { return nil }
            return appGame(url: url, title: url.deletingPathExtension().lastPathComponent, platform: .mac, source: "Mac app")
        }
    }

    private static func appGame(url: URL, title: String, platform: Platform, source: String, art: ArtSource = .none) -> Game {
        Game(
            id: "app:\(url.standardizedFileURL.path)",
            title: title,
            platform: platform,
            launch: url.pathExtension == "app" ? .app(url) : .executable(url),
            art: art,
            sourceLabel: source,
            location: url
        )
    }

    // MARK: Decomps and recomps

    private struct KnownPort {
        var title: String
        var names: Set<String>
        var namePrefix: String? = nil
        var boxart: String
    }

    /// Names are compared lowercased with punctuation removed. Box art comes from the original game.
    private static let knownPorts: [KnownPort] = [
        KnownPort(title: "Zelda 64: Recompiled", names: ["zelda64recompiled", "zelda64recomp", "zelda64"], boxart: "Legend of Zelda, The - Majora's Mask (USA)"),
        KnownPort(title: "2 Ship 2 Harkinian", names: ["2ship2harkinian", "2ship", "2s2h"], boxart: "Legend of Zelda, The - Majora's Mask (USA)"),
        KnownPort(title: "Ship of Harkinian", names: ["shipofharkinian", "soh"], boxart: "Legend of Zelda, The - Ocarina of Time (USA)"),
        KnownPort(title: "Super Mario 64 (Ghostship)", names: ["ghostship"], boxart: "Super Mario 64 (USA)"),
        KnownPort(title: "Super Mario 64", names: [], namePrefix: "sm64", boxart: "Super Mario 64 (USA)"),
        KnownPort(title: "Starship", names: ["starship"], boxart: "Star Fox 64 (USA)"),
        KnownPort(title: "SpaghettiKart", names: ["spaghettikart"], boxart: "Mario Kart 64 (USA)"),
        KnownPort(title: "Banjo: Recompiled", names: ["banjorecompiled", "banjorecomp", "bkrecomp"], boxart: "Banjo-Kazooie (USA)"),
        KnownPort(title: "Goemon 64: Recompiled", names: ["goemon64recompiled", "goemon64recomp"], boxart: "Mystical Ninja Starring Goemon (USA)"),
        KnownPort(title: "Paper Mario: Recompiled", names: ["papermariorecompiled", "pmrecomp"], boxart: "Paper Mario (USA)"),
        KnownPort(title: "Donkey Kong 64: Recompiled", names: ["dk64recompiled", "dk64recomp"], boxart: "Donkey Kong 64 (USA)"),
        KnownPort(title: "Perfect Dark", names: ["perfectdark", "pdarm64", "pdx8664", "pd"], boxart: "Perfect Dark (USA)"),
    ]

    private static func normalized(_ name: String) -> String {
        name.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    private static func matchPort(_ name: String) -> KnownPort? {
        let key = normalized(name)
        return knownPorts.first { port in
            port.names.contains(key) || port.namePrefix.map(key.hasPrefix) == true
        }
    }

    private static func scanPorts(manual: [ManualEntry]) -> [Game] {
        let manager = FileManager.default
        var games: [String: Game] = [:]

        let roots = ["/Applications", "\(home.path)/Applications", "\(home.path)/Games"].map(URL.init(fileURLWithPath:))
        for root in roots {
            guard let walker = manager.enumerator(
                at: root,
                includingPropertiesForKeys: [.isExecutableKey, .isRegularFileKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else { continue }
            for case let url as URL in walker {
                if walker.level >= 3 { walker.skipDescendants() }
                let isApp = url.pathExtension == "app"
                let values = try? url.resourceValues(forKeys: [.isExecutableKey, .isRegularFileKey])
                let isBareExecutable = url.pathExtension.isEmpty && values?.isRegularFile == true && values?.isExecutable == true
                // Loose executables are only trusted inside ~/Games, where a port's name means something.
                guard isApp || (isBareExecutable && root.lastPathComponent == "Games") else { continue }
                guard let port = matchPort(url.deletingPathExtension().lastPathComponent) else { continue }
                let game = appGame(
                    url: url,
                    title: port.title,
                    platform: .ports,
                    source: "Native port",
                    art: .libretro(system: "Nintendo_-_Nintendo_64", name: port.boxart)
                )
                games[game.id] = game
            }
        }

        for entry in manual {
            let url = URL(fileURLWithPath: entry.path)
            guard manager.fileExists(atPath: url.path) else { continue }
            let art = matchPort(url.deletingPathExtension().lastPathComponent).map {
                ArtSource.libretro(system: "Nintendo_-_Nintendo_64", name: $0.boxart)
            } ?? .none
            let game = appGame(url: url, title: entry.title, platform: .ports, source: "Added by you", art: art)
            games[game.id] = game
        }
        return Array(games.values)
    }
}
