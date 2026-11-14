import Foundation

enum Platform: String, CaseIterable, Sendable {
    case ps1, ps2, n64, ports, steam, mac

    var title: String {
        switch self {
        case .ps1: "PlayStation"
        case .ps2: "PlayStation 2"
        case .n64: "Nintendo 64"
        case .ports: "Decomps & Recomps"
        case .steam: "Steam"
        case .mac: "Mac"
        }
    }

    var shortTitle: String {
        switch self {
        case .ps1: "PS1"
        case .ps2: "PS2"
        case .n64: "N64"
        case .ports: "Ports"
        case .steam: "Steam"
        case .mac: "Mac"
        }
    }

    var symbol: String {
        switch self {
        case .ps1, .ps2: "opticaldisc"
        case .n64: "gamecontroller"
        case .ports: "hammer"
        case .steam: "cloud"
        case .mac: "desktopcomputer"
        }
    }

    /// Width / height of the box art each platform shipped in.
    var caseAspect: CGFloat {
        switch self {
        case .ps1: 1.0
        case .ps2: 0.7
        case .n64, .ports: 1.38
        case .steam, .mac: 0.667
        }
    }
}

enum Emulator: String, Sendable {
    case duckStation, pcsx2, gopher64

    var name: String {
        switch self {
        case .duckStation: "DuckStation"
        case .pcsx2: "PCSX2"
        case .gopher64: "Gopher64"
        }
    }

    var bundleID: String {
        switch self {
        case .duckStation: "com.github.stenzek.duckstation"
        case .pcsx2: "net.pcsx2.pcsx2"
        case .gopher64: "io.github.gopher64.gopher64"
        }
    }
}

enum LaunchMethod: Hashable, Sendable {
    case emulator(Emulator)
    case steam(appID: String)
    case app(URL)
    case executable(URL)
}

enum ArtSource: Hashable, Sendable {
    case libretro(system: String, name: String)
    case steam(appID: String)
    case none
}

struct Disc: Hashable, Sendable {
    var label: String
    var url: URL
    var serial: String?
}

struct Game: Identifiable, Hashable, Sendable {
    var id: String
    var title: String
    var platform: Platform
    var launch: LaunchMethod
    var discs: [Disc] = []
    var art: ArtSource = .none
    var sourceLabel: String
    var location: URL?
    /// Folder of artwork the owning emulator already keeps, checked before downloading.
    var localCoverFolder: URL?
    var playtime: TimeInterval = 0
    var lastPlayed: Date?

    /// Playtime the emulator or Steam records itself. Everything else is timed by GameShelf.
    var tracksOwnPlaytime: Bool {
        switch launch {
        case .emulator(let emulator): emulator != .gopher64
        case .steam: true
        case .app, .executable: false
        }
    }

    var sortKey: String {
        let lowered = title.lowercased()
        return lowered.hasPrefix("the ") ? String(lowered.dropFirst(4)) : lowered
    }
}

enum GameTitle {
    /// Turns a Redump / No-Intro file name into a display title:
    /// "Legend of Zelda, The - Majora's Mask (USA)" becomes "The Legend of Zelda: Majora's Mask".
    static func clean(_ fileName: String) -> String {
        var title = fileName
        if let tagStart = title.firstIndex(where: { $0 == "(" || $0 == "[" }) {
            title = String(title[..<tagStart])
        }
        title = title.trimmingCharacters(in: .whitespaces)
        title = title.replacingOccurrences(of: " - ", with: ": ")

        for article in ["The", "A", "An"] {
            let suffix = ", \(article)"
            if let range = title.range(of: suffix) {
                title.removeSubrange(range)
                title = "\(article) \(title)"
                break
            }
        }
        return title
    }

    /// "Resident Evil 2 (USA) (Disc 2)" returns 2.
    static func discNumber(_ fileName: String) -> Int? {
        guard let match = fileName.firstMatch(of: /\((?:Disc|CD|Disk) ([0-9]+)[^)]*\)/.ignoresCase()) else { return nil }
        return Int(match.1)
    }

    /// Duplicate titles only merge when they share every tag apart from the disc number.
    static func discGroupKey(_ fileName: String) -> String {
        fileName.replacing(/\s*\((?:Disc|CD|Disk) [0-9]+[^)]*\)/.ignoresCase(), with: "").lowercased()
    }
}

/// A collection is any list of games you can browse: a platform, favorites, recents or one you made.
enum CollectionID: Hashable, Sendable {
    case all, favorites, recent
    case platform(Platform)
    case custom(UUID)

    /// A stable string for saving order and visibility.
    var key: String {
        switch self {
        case .all: "all"
        case .favorites: "favorites"
        case .recent: "recent"
        case .platform(let platform): "platform:\(platform.rawValue)"
        case .custom(let id): "custom:\(id.uuidString)"
        }
    }
}

struct GameCollection: Identifiable {
    var id: CollectionID
    var title: String
    var symbol: String
    var games: [Game]
}

struct UserCollection: Codable, Hashable, Identifiable, Sendable {
    var id = UUID()
    var name: String
    var symbol: String = "folder"
    var gameIDs: [String] = []
}
