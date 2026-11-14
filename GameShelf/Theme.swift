import AppKit
import Observation
import SwiftUI

/// Everything about how the library looks. Themes are plain JSON, so they can be shared and hand-edited.
struct Theme: Codable, Hashable, Identifiable, Sendable {
    enum Layout: String, Codable, CaseIterable, Identifiable, Sendable {
        /// A big hero for the selected game over rows of collections.
        case showcase
        /// Large covers in a sliding carousel, one collection at a time.
        case carousel
        /// A sidebar of collections, a cover grid and an info panel.
        case grid
        /// Covers standing on wooden shelves.
        case shelf
        /// A hand of cards fanned in an arc, one collection at a time.
        case fan
        /// Covers strewn across a table at odd angles.
        case scatter

        var id: String { rawValue }

        var label: String {
            switch self {
            case .showcase: "Showcase"
            case .carousel: "Carousel"
            case .grid: "Grid"
            case .shelf: "Bookshelf"
            case .fan: "Fan"
            case .scatter: "Scattered"
            }
        }

        var summary: String {
            switch self {
            case .showcase: "A hero banner for the selected game above scrolling rows."
            case .carousel: "Big covers that slide past, one collection at a time."
            case .grid: "Collections in a sidebar, a dense grid and a details panel."
            case .shelf: "Game cases standing on wooden shelves."
            case .fan: "A hand of covers fanned in an arc, one collection at a time."
            case .scatter: "Covers strewn across a table at odd angles, nothing lined up."
            }
        }
    }

    enum Typeface: String, Codable, CaseIterable, Identifiable, Sendable {
        case standard, rounded, serif, mono

        var id: String { rawValue }
        var label: String { rawValue == "standard" ? "System" : rawValue.capitalized }

        var design: Font.Design {
            switch self {
            case .standard: .default
            case .rounded: .rounded
            case .serif: .serif
            case .mono: .monospaced
            }
        }
    }

    enum Backdrop: String, Codable, CaseIterable, Identifiable, Sendable {
        /// The selected game's artwork, blurred and dimmed.
        case artwork
        case gradient
        case solid
        /// An image file you chose.
        case image

        var id: String { rawValue }
        var label: String { rawValue == "artwork" ? "Game artwork" : rawValue.capitalized }
    }

    enum Highlight: String, Codable, CaseIterable, Identifiable, Sendable {
        case glow, outline, lift

        var id: String { rawValue }
        var label: String { rawValue.capitalized }
    }

    /// Something moving behind the library, which also reacts to the pointer.
    enum Ambience: String, Codable, CaseIterable, Identifiable, Sendable {
        case none, stars, grid, rain, embers, bubbles, moon, fog, ash, wisps

        var id: String { rawValue }

        var label: String {
            switch self {
            case .none: "None"
            case .stars: "Starfield"
            case .grid: "Neon grid"
            case .rain: "Code rain"
            case .embers: "Embers"
            case .bubbles: "Bubbles"
            case .moon: "Moonrise"
            case .fog: "Fog"
            case .ash: "Falling ash"
            case .wisps: "Wisps"
            }
        }
    }

    var id: String
    var name: String
    var author: String = "You"
    var layout: Layout
    var typeface: Typeface = .standard

    var background: HexColor
    var backgroundEnd: HexColor
    var surface: HexColor
    var text: HexColor
    var secondaryText: HexColor
    var accent: HexColor

    var backdrop: Backdrop = .artwork
    var backdropImagePath: String?
    /// 0 shows the backdrop at full strength, 1 hides it under the background colour.
    var backdropDim: Double = 0.55
    var backdropBlur: Double = 30

    /// Multiplies the layout's default cover size.
    var coverScale: Double = 1
    var cornerRadius: Double = 8
    var highlight: Highlight = .glow
    var showTitles: Bool = true
    var showPlaytime: Bool = true
    var animations: Bool = true
    var ambience: Ambience = .none
    /// Covers tilt under the pointer and catch the light.
    var tilt: Bool = true
    /// How far the window's edges fall into shadow: 0 is none, 1 is black.
    var vignette: Double = 0

    var isBuiltIn: Bool { Theme.builtIn.contains { $0.id == id } }

    func font(_ style: Font.TextStyle, weight: Font.Weight = .regular) -> Font {
        .system(style, design: typeface.design, weight: weight)
    }

    func font(size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: typeface.design)
    }

    /// Whether the palette is light, so system controls can match.
    var isLight: Bool { background.luminance > 0.5 }
}

/// A colour stored as "#RRGGBB" or "#RRGGBBAA" so theme files stay readable.
struct HexColor: Codable, Hashable, Sendable {
    var hex: String

    init(_ hex: String) { self.hex = hex }

    init(_ color: Color) {
        let rgb = NSColor(color).usingColorSpace(.sRGB) ?? .black
        let parts = [rgb.redComponent, rgb.greenComponent, rgb.blueComponent].map { Int(($0 * 255).rounded()) }
        var hex = String(format: "#%02X%02X%02X", parts[0], parts[1], parts[2])
        if rgb.alphaComponent < 1 { hex += String(format: "%02X", Int((rgb.alphaComponent * 255).rounded())) }
        self.hex = hex
    }

    init(from decoder: Decoder) throws {
        hex = try decoder.singleValueContainer().decode(String.self)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(hex)
    }

    private var components: (red: Double, green: Double, blue: Double, alpha: Double) {
        let digits = hex.trimmingCharacters(in: CharacterSet(charactersIn: "# "))
        guard let value = UInt64(digits, radix: 16) else { return (0, 0, 0, 1) }
        if digits.count == 8 {
            return (Double(value >> 24 & 0xFF) / 255, Double(value >> 16 & 0xFF) / 255, Double(value >> 8 & 0xFF) / 255, Double(value & 0xFF) / 255)
        }
        return (Double(value >> 16 & 0xFF) / 255, Double(value >> 8 & 0xFF) / 255, Double(value & 0xFF) / 255, 1)
    }

    var color: Color {
        let parts = components
        return Color(.sRGB, red: parts.red, green: parts.green, blue: parts.blue, opacity: parts.alpha)
    }

    var luminance: Double {
        let parts = components
        return 0.2126 * parts.red + 0.7152 * parts.green + 0.0722 * parts.blue
    }
}

extension Theme {
    static let builtIn: [Theme] = [
        Theme(
            id: "midnight", name: "Midnight", author: "GameShelf", layout: .showcase, typeface: .standard,
            background: HexColor("#0B1020"), backgroundEnd: HexColor("#05070F"), surface: HexColor("#FFFFFF14"),
            text: HexColor("#F3F5FF"), secondaryText: HexColor("#9AA3C7"), accent: HexColor("#5AC8FA"),
            backdrop: .artwork, backdropDim: 0.5, backdropBlur: 24, highlight: .glow
        ),
        Theme(
            id: "neon-arcade", name: "Neon Arcade", author: "GameShelf", layout: .carousel, typeface: .rounded,
            background: HexColor("#1A0629"), backgroundEnd: HexColor("#06010D"), surface: HexColor("#FF3CAC1F"),
            text: HexColor("#FFF0FB"), secondaryText: HexColor("#C79BD9"), accent: HexColor("#FF3CAC"),
            backdrop: .artwork, backdropDim: 0.62, backdropBlur: 40, coverScale: 1.1, cornerRadius: 14, highlight: .glow
        ),
        Theme(
            id: "paperback", name: "Paperback", author: "GameShelf", layout: .grid, typeface: .serif,
            background: HexColor("#F4EEE2"), backgroundEnd: HexColor("#E8DFCC"), surface: HexColor("#FFFFFFB3"),
            text: HexColor("#2B2118"), secondaryText: HexColor("#7A6A58"), accent: HexColor("#B4462F"),
            backdrop: .gradient, cornerRadius: 4, highlight: .outline
        ),
        Theme(
            id: "phosphor", name: "Phosphor", author: "GameShelf", layout: .grid, typeface: .mono,
            background: HexColor("#030A05"), backgroundEnd: HexColor("#000000"), surface: HexColor("#33FF661A"),
            text: HexColor("#B8FFC8"), secondaryText: HexColor("#4FA866"), accent: HexColor("#33FF66"),
            backdrop: .solid, cornerRadius: 0, highlight: .outline, animations: false
        ),
        Theme(
            id: "sunset-drive", name: "Sunset Drive", author: "GameShelf", layout: .showcase, typeface: .rounded,
            background: HexColor("#3A1C3F"), backgroundEnd: HexColor("#120914"), surface: HexColor("#FFB34714"),
            text: HexColor("#FFF4E8"), secondaryText: HexColor("#E0A98C"), accent: HexColor("#FFB347"),
            backdrop: .artwork, backdropDim: 0.4, backdropBlur: 12, cornerRadius: 12, highlight: .lift
        ),
        Theme(
            id: "bookshelf", name: "Bookshelf", author: "GameShelf", layout: .shelf, typeface: .serif,
            background: HexColor("#211609"), backgroundEnd: HexColor("#120B05"), surface: HexColor("#DBB87014"),
            text: HexColor("#F6E7CC"), secondaryText: HexColor("#B89A72"), accent: HexColor("#DBB870"),
            backdrop: .gradient, cornerRadius: 3, highlight: .lift
        ),
        Theme(
            id: "deep-space", name: "Deep Space", author: "GameShelf", layout: .showcase, typeface: .standard,
            background: HexColor("#070B1E"), backgroundEnd: HexColor("#010207"), surface: HexColor("#8B9DFF1A"),
            text: HexColor("#EEF1FF"), secondaryText: HexColor("#8F98C4"), accent: HexColor("#8B9DFF"),
            backdrop: .gradient, cornerRadius: 10, highlight: .glow, ambience: .stars
        ),
        Theme(
            id: "outrun", name: "Outrun", author: "GameShelf", layout: .carousel, typeface: .rounded,
            background: HexColor("#1B0B3A"), backgroundEnd: HexColor("#05010F"), surface: HexColor("#FF5E9C1F"),
            text: HexColor("#FFF1FA"), secondaryText: HexColor("#B79AE0"), accent: HexColor("#FF5E9C"),
            backdrop: .gradient, cornerRadius: 10, highlight: .glow, ambience: .grid
        ),
        Theme(
            id: "mainframe", name: "Mainframe", author: "GameShelf", layout: .grid, typeface: .mono,
            background: HexColor("#020803"), backgroundEnd: HexColor("#000000"), surface: HexColor("#3DFF7A14"),
            text: HexColor("#C9FFD8"), secondaryText: HexColor("#58B272"), accent: HexColor("#3DFF7A"),
            backdrop: .solid, cornerRadius: 2, highlight: .outline, ambience: .rain
        ),
        Theme(
            id: "campfire", name: "Campfire", author: "GameShelf", layout: .shelf, typeface: .serif,
            background: HexColor("#1F1108"), backgroundEnd: HexColor("#0A0502"), surface: HexColor("#FF9A3C14"),
            text: HexColor("#FFEBD2"), secondaryText: HexColor("#C49A74"), accent: HexColor("#FF9A3C"),
            backdrop: .gradient, cornerRadius: 4, highlight: .lift, ambience: .embers
        ),
        Theme(
            id: "abyss", name: "Abyss", author: "GameShelf", layout: .showcase, typeface: .rounded,
            background: HexColor("#04222E"), backgroundEnd: HexColor("#010B12"), surface: HexColor("#3FE0C51A"),
            text: HexColor("#E6FFFA"), secondaryText: HexColor("#7FB5B8"), accent: HexColor("#3FE0C5"),
            backdrop: .artwork, backdropDim: 0.72, backdropBlur: 40, cornerRadius: 12, highlight: .lift, ambience: .bubbles
        ),
        Theme(
            id: "blood-moon", name: "Blood Moon", author: "GameShelf", layout: .fan, typeface: .serif,
            background: HexColor("#160709"), backgroundEnd: HexColor("#030102"), surface: HexColor("#C2182F1F"),
            text: HexColor("#E9DFCF"), secondaryText: HexColor("#9A8478"), accent: HexColor("#C2182F"),
            backdrop: .gradient, cornerRadius: 3, highlight: .glow, ambience: .moon, vignette: 0.6
        ),
        Theme(
            id: "lanternlight", name: "Lanternlight", author: "GameShelf", layout: .scatter, typeface: .serif,
            background: HexColor("#0E1416"), backgroundEnd: HexColor("#040708"), surface: HexColor("#E3C27A14"),
            text: HexColor("#E6E0D0"), secondaryText: HexColor("#8E968F"), accent: HexColor("#E3C27A"),
            backdrop: .artwork, backdropDim: 0.78, backdropBlur: 36, cornerRadius: 2, highlight: .lift,
            ambience: .wisps, vignette: 0.55
        ),
        Theme(
            id: "ashen", name: "Ashen", author: "GameShelf", layout: .scatter, typeface: .serif,
            background: HexColor("#17171A"), backgroundEnd: HexColor("#070708"), surface: HexColor("#FFFFFF10"),
            text: HexColor("#DAD6CF"), secondaryText: HexColor("#8A8782"), accent: HexColor("#D0703A"),
            backdrop: .gradient, cornerRadius: 2, highlight: .lift, ambience: .ash, vignette: 0.5
        ),
        Theme(
            id: "old-cathedral", name: "Old Cathedral", author: "GameShelf", layout: .fan, typeface: .serif,
            background: HexColor("#0D1218"), backgroundEnd: HexColor("#030507"), surface: HexColor("#9FB4C814"),
            text: HexColor("#DCE3EA"), secondaryText: HexColor("#7F8C99"), accent: HexColor("#B89B5E"),
            backdrop: .artwork, backdropDim: 0.75, backdropBlur: 30, cornerRadius: 2, highlight: .outline,
            ambience: .fog, vignette: 0.65
        ),
    ]

    static let fallback = builtIn[0]
}

@MainActor
@Observable
final class ThemeStore {
    static let selectedKey = "themeID"

    private(set) var custom: [Theme] = []
    var selectedID: String {
        didSet { UserDefaults.standard.set(selectedID, forKey: Self.selectedKey) }
    }

    let folder: URL

    init() {
        folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("GameShelf/Themes")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        selectedID = UserDefaults.standard.string(forKey: Self.selectedKey) ?? Theme.fallback.id
        reload()
    }

    var all: [Theme] { Theme.builtIn + custom }

    var current: Theme { all.first { $0.id == selectedID } ?? Theme.fallback }

    /// Picks up theme files dropped into the Themes folder by hand.
    func reload() {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        custom = files.filter { $0.pathExtension == "json" }.compactMap { url in
            guard let data = try? Data(contentsOf: url), var theme = try? JSONDecoder().decode(Theme.self, from: data) else { return nil }
            // A file's name is its identity, so copied files never collide with a built-in.
            theme.id = url.deletingPathExtension().lastPathComponent
            return theme
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Built-in themes can't change, so editing one saves a copy and switches to it.
    func save(_ theme: Theme) {
        var theme = theme
        if let original = Theme.builtIn.first(where: { $0.id == theme.id }) {
            if theme.name == original.name { theme.name = "\(original.name) Custom" }
            theme.id = uniqueID(for: theme.name)
            theme.author = "You"
        }
        write(theme)
        // Updated in memory rather than reloaded, since sliders save on every step.
        if let index = custom.firstIndex(where: { $0.id == theme.id }) {
            custom[index] = theme
        } else {
            custom.append(theme)
        }
        selectedID = theme.id
    }

    func duplicate(_ theme: Theme) -> Theme {
        var copy = theme
        copy.name = "\(theme.name) Copy"
        copy.id = uniqueID(for: copy.name)
        copy.author = "You"
        write(copy)
        reload()
        selectedID = copy.id
        return copy
    }

    func delete(_ theme: Theme) {
        guard !theme.isBuiltIn else { return }
        try? FileManager.default.removeItem(at: url(for: theme.id))
        reload()
        if selectedID == theme.id { selectedID = Theme.fallback.id }
    }

    func importTheme(from source: URL) throws {
        let data = try Data(contentsOf: source)
        var theme = try JSONDecoder().decode(Theme.self, from: data)
        theme.id = uniqueID(for: theme.name)
        write(theme)
        reload()
        selectedID = theme.id
    }

    func export(_ theme: Theme, to destination: URL) throws {
        try encoded(theme).write(to: destination, options: .atomic)
    }

    private func write(_ theme: Theme) {
        try? encoded(theme).write(to: url(for: theme.id), options: .atomic)
    }

    private func encoded(_ theme: Theme) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(theme)
    }

    private func url(for id: String) -> URL { folder.appendingPathComponent("\(id).json") }

    private func uniqueID(for name: String) -> String {
        let base = name.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" }.reduce("") { $0 + String($1) }
        var candidate = base.isEmpty ? "theme" : base
        var counter = 2
        while all.contains(where: { $0.id == candidate }) {
            candidate = "\(base)-\(counter)"
            counter += 1
        }
        return candidate
    }
}

private struct ThemeKey: EnvironmentKey {
    static let defaultValue = Theme.fallback
}

extension EnvironmentValues {
    var theme: Theme {
        get { self[ThemeKey.self] }
        set { self[ThemeKey.self] = newValue }
    }
}

extension Theme {
    /// Missing keys fall back to Midnight's values, so a theme file only needs the parts it changes.
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let base = Theme.fallback
        func value<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
            (try? values.decodeIfPresent(T.self, forKey: key)) ?? fallback
        }
        id = value(.id, UUID().uuidString)
        name = value(.name, "Untitled Theme")
        author = value(.author, "Unknown")
        layout = value(.layout, base.layout)
        typeface = value(.typeface, base.typeface)
        background = value(.background, base.background)
        backgroundEnd = value(.backgroundEnd, background)
        surface = value(.surface, base.surface)
        text = value(.text, base.text)
        secondaryText = value(.secondaryText, base.secondaryText)
        accent = value(.accent, base.accent)
        backdrop = value(.backdrop, base.backdrop)
        backdropImagePath = try? values.decodeIfPresent(String.self, forKey: .backdropImagePath)
        backdropDim = value(.backdropDim, base.backdropDim)
        backdropBlur = value(.backdropBlur, base.backdropBlur)
        coverScale = value(.coverScale, base.coverScale)
        cornerRadius = value(.cornerRadius, base.cornerRadius)
        highlight = value(.highlight, base.highlight)
        showTitles = value(.showTitles, base.showTitles)
        showPlaytime = value(.showPlaytime, base.showPlaytime)
        animations = value(.animations, base.animations)
        ambience = value(.ambience, base.ambience)
        tilt = value(.tilt, base.tilt)
        vignette = value(.vignette, base.vignette)
    }
}
