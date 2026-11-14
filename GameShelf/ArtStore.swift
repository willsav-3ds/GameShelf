import AppKit
import CryptoKit
import Foundation

enum ArtKind: String, CaseIterable, Sendable {
    /// Box art.
    case cover
    /// A wide screenshot or hero image shown behind the interface.
    case background
    /// A transparent title logo.
    case logo

    var label: String {
        switch self {
        case .cover: "Cover"
        case .background: "Background"
        case .logo: "Logo"
        }
    }
}

/// Finds artwork in order: your own pick, the emulator's folder (covers only), the download cache, then the web.
actor ArtStore {
    static let shared = ArtStore()
    static let downloadsEnabledKey = "downloadCovers"

    private let memory = NSCache<NSString, NSImage>()
    private var missing: Set<String> = []

    private let customFolder: URL
    private let cacheFolder: URL

    init() {
        let manager = FileManager.default
        customFolder = manager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("GameShelf/CustomCovers")
        cacheFolder = manager.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("GameShelf/Covers")
        try? manager.createDirectory(at: customFolder, withIntermediateDirectories: true)
        try? manager.createDirectory(at: cacheFolder, withIntermediateDirectories: true)
    }

    func image(_ kind: ArtKind, for game: Game) async -> NSImage? {
        let key = Self.key(game.id, kind)
        if let image = memory.object(forKey: key as NSString) { return image }

        let local = kind == .cover ? localCover(for: game) : nil
        if let image = NSImage(contentsOf: customURL(key)) ?? local ?? NSImage(contentsOf: cacheURL(key)) {
            memory.setObject(image, forKey: key as NSString)
            return image
        }

        let downloadsEnabled = UserDefaults.standard.object(forKey: Self.downloadsEnabledKey) as? Bool ?? true
        guard downloadsEnabled, !missing.contains(key) else { return nil }

        for url in Self.remoteURLs(for: game.art, kind: kind) {
            guard let (data, response) = try? await URLSession.shared.data(from: url),
                  (response as? HTTPURLResponse)?.statusCode == 200,
                  let image = NSImage(data: data) else { continue }
            try? data.write(to: cacheURL(key), options: .atomic)
            memory.setObject(image, forKey: key as NSString)
            return image
        }
        missing.insert(key)
        return nil
    }

    func setCustom(_ kind: ArtKind, from source: URL, for game: Game) throws {
        guard let image = NSImage(contentsOf: source),
              let tiff = image.tiffRepresentation,
              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let key = Self.key(game.id, kind)
        try png.write(to: customURL(key), options: .atomic)
        memory.removeObject(forKey: key as NSString)
        missing.remove(key)
    }

    func removeCustom(_ kind: ArtKind, for game: Game) {
        let key = Self.key(game.id, kind)
        try? FileManager.default.removeItem(at: customURL(key))
        memory.removeObject(forKey: key as NSString)
        missing.remove(key)
    }

    func hasCustom(_ kind: ArtKind, for game: Game) -> Bool {
        FileManager.default.fileExists(atPath: customURL(Self.key(game.id, kind)).path)
    }

    private func localCover(for game: Game) -> NSImage? {
        guard let folder = game.localCoverFolder else { return nil }
        var names = [game.title, game.location?.deletingPathExtension().lastPathComponent]
        names += game.discs.map(\.serial)
        for name in names.compactMap({ $0 }) {
            for fileExtension in ["jpg", "jpeg", "png", "webp"] {
                if let image = NSImage(contentsOf: folder.appendingPathComponent("\(name).\(fileExtension)")) {
                    return image
                }
            }
        }
        return nil
    }

    /// Covers keep the bare game ID so art cached before backgrounds and logos existed is still found.
    private static func key(_ id: String, _ kind: ArtKind) -> String {
        kind == .cover ? id : "\(id)#\(kind.rawValue)"
    }

    private func customURL(_ key: String) -> URL {
        customFolder.appendingPathComponent("\(Self.fileName(for: key)).png")
    }

    private func cacheURL(_ key: String) -> URL {
        cacheFolder.appendingPathComponent(Self.fileName(for: key))
    }

    private static func fileName(for key: String) -> String {
        SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func remoteURLs(for art: ArtSource, kind: ArtKind) -> [URL] {
        switch art {
        case .none:
            return []
        case .steam(let appID):
            let files = switch kind {
            case .cover: ["library_600x900_2x.jpg", "library_600x900.jpg", "header.jpg"]
            case .background: ["library_hero.jpg", "page_bg_generated_v6b.jpg"]
            case .logo: ["logo.png"]
            }
            return files.compactMap { URL(string: "https://cdn.cloudflare.steamstatic.com/steam/apps/\(appID)/\($0)") }
        case .libretro(let system, let name):
            let folders = switch kind {
            case .cover: ["Named_Boxarts"]
            case .background: ["Named_Snaps", "Named_Titles"]
            case .logo: ["Named_Logos"]
            }
            // libretro-thumbnails swaps these characters for underscores in its file names.
            let safeName = String(name.map { "&*/:`<>?\\|\"".contains($0) ? "_" : $0 })
            // Redump's multi-region tags often don't match, e.g. "(USA, Canada)" is filed under "(USA)".
            var names = [safeName]
            if let tag = safeName.range(of: " (") {
                names.append("\(safeName[..<tag.lowerBound]) (USA)")
            }
            return folders.flatMap { folder in
                names.compactMap { candidate -> URL? in
                    guard let encoded = "\(candidate).png".addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else { return nil }
                    return URL(string: "https://raw.githubusercontent.com/libretro-thumbnails/\(system)/master/\(folder)/\(encoded)")
                }
            }
        }
    }
}
