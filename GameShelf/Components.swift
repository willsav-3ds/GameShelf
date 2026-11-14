import SwiftUI

/// Loads one kind of artwork for a game and reloads when you change it.
struct GameArtwork<Placeholder: View>: View {
    @Environment(LibraryStore.self) private var library
    let game: Game?
    let kind: ArtKind
    @ViewBuilder var placeholder: () -> Placeholder
    var content: (NSImage) -> AnyView = { AnyView(Image(nsImage: $0).resizable().interpolation(.high)) }
    @State private var image: NSImage?
    @State private var loadedKey: String?

    var body: some View {
        let key = game.map { "\($0.id)#\(kind.rawValue)#\(library.coverRevision)" }
        ZStack {
            if let image, loadedKey == key {
                content(image)
            } else {
                placeholder()
            }
        }
        .task(id: key) {
            guard let game else { image = nil; return }
            let loaded = await ArtStore.shared.image(kind, for: game)
            image = loaded
            loadedKey = key
        }
    }
}

/// Box art sized to a frame: fills it when the shapes are close, otherwise fits over a blurred copy.
struct CoverImage: View {
    let game: Game
    let size: CGSize

    var body: some View {
        GameArtwork(game: game, kind: .cover) {
            GeneratedCover(game: game)
        } content: { image in
            AnyView(CoverArt(image: image, size: size))
        }
        .frame(width: size.width, height: size.height)
    }
}

private struct CoverArt: View {
    let image: NSImage
    let size: CGSize

    var body: some View {
        let imageAspect = image.size.width / max(image.size.height, 1)
        let frameAspect = size.width / max(size.height, 1)
        if abs(imageAspect - frameAspect) / frameAspect < 0.2 {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fill)
                .frame(width: size.width, height: size.height)
        } else {
            ZStack {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: size.width, height: size.height)
                    .blur(radius: 16)
                    .overlay(.black.opacity(0.3))
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
            }
        }
    }
}

struct GeneratedCover: View {
    @Environment(\.theme) private var theme
    let game: Game

    /// A stable colour per title, so a game's cover doesn't change between launches.
    private var hue: Double {
        let total = game.title.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xFFFF }
        return Double(total % 360) / 360
    }

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(hue: hue, saturation: 0.55, brightness: 0.45),
                    Color(hue: hue, saturation: 0.7, brightness: 0.16),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            VStack(spacing: 10) {
                if let location = game.location, game.launch.isApp {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: location.path))
                        .resizable()
                        .frame(width: 64, height: 64)
                        .shadow(radius: 5)
                }
                Text(game.title)
                    .font(theme.font(.headline, weight: .semibold))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.white)
                    .minimumScaleFactor(0.6)
                    .padding(.horizontal, 10)
            }
        }
    }
}

extension LaunchMethod {
    var isApp: Bool {
        if case .app = self { return true }
        return false
    }
}

/// What a card can ask the library window to do.
struct GameActions {
    var focus: (CollectionID, Game) -> Void
    var open: (Game) -> Void
    var play: (Game) -> Void
    var newCollection: (Game) -> Void
}

private struct GameActionsKey: EnvironmentKey {
    static let defaultValue = GameActions(focus: { _, _ in }, open: { _ in }, play: { _ in }, newCollection: { _ in })
}

extension EnvironmentValues {
    var gameActions: GameActions {
        get { self[GameActionsKey.self] }
        set { self[GameActionsKey.self] = newValue }
    }
}

/// A cover in any layout. Click to select it; click a selected cover to open it.
struct CoverCard: View {
    @Environment(\.theme) private var theme
    @Environment(\.gameActions) private var actions
    @Environment(LibraryStore.self) private var library
    let game: Game
    let collection: CollectionID
    let size: CGSize
    let isFocused: Bool
    var showsTitle: Bool? = nil
    @State private var isHovered = false

    var body: some View {
        VStack(spacing: 7) {
            CoverImage(game: game, size: size)
                .clipShape(RoundedRectangle(cornerRadius: theme.cornerRadius))
                .overlay(alignment: .topTrailing) {
                    if library.isFavorite(game) {
                        Image(systemName: "star.fill")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(theme.accent.color)
                            .padding(5)
                            .background(.black.opacity(0.55), in: Circle())
                            .padding(6)
                    }
                }
                .overlay(alignment: .topLeading) {
                    if !game.isInstalled {
                        Image(systemName: "arrow.down")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(5)
                            .background(.black.opacity(0.55), in: Circle())
                            .padding(6)
                            .accessibilityLabel("Not installed")
                    }
                }
                .overlay {
                    RoundedRectangle(cornerRadius: theme.cornerRadius)
                        .strokeBorder(highlightBorder, lineWidth: isFocused ? 3 : 0.5)
                }
                .modifier(PointerTilt(size: size))
                .shadow(color: glowColor, radius: isFocused ? 18 : 6, y: isFocused ? 0 : 3)
                .scaleEffect(scale, anchor: theme.layout == .shelf ? .bottom : .center)
            if showsTitle ?? theme.showTitles {
                Text(game.title)
                    .font(theme.font(.caption, weight: isFocused ? .semibold : .regular))
                    .foregroundStyle(isFocused ? theme.text.color : theme.secondaryText.color)
                    .lineLimit(1)
                    .frame(width: size.width)
            }
        }
        .animation(theme.animations ? .spring(duration: 0.25) : nil, value: isFocused)
        .animation(theme.animations ? .spring(duration: 0.2) : nil, value: isHovered)
        .contentShape(Rectangle())
        .onTapGesture {
            if isFocused { actions.open(game) } else { actions.focus(collection, game) }
        }
        .onHover { isHovered = $0 }
        .help(game.title)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(game.title)
        .accessibilityAddTraits(isFocused ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { actions.open(game) }
        .contextMenu { GameMenu(game: game) }
    }

    private var scale: CGFloat {
        guard theme.animations else { return 1 }
        if isFocused { return theme.highlight == .lift ? 1.08 : 1.03 }
        return isHovered ? 1.02 : 1
    }

    private var highlightBorder: Color {
        guard isFocused else { return .black.opacity(0.35) }
        return theme.highlight == .lift ? .white.opacity(0.25) : theme.accent.color
    }

    private var glowColor: Color {
        guard isFocused else { return .black.opacity(0.45) }
        return theme.highlight == .glow ? theme.accent.color.opacity(0.75) : .black.opacity(0.6)
    }
}

/// The right-click menu for a game, shared by every layout.
struct GameMenu: View {
    @Environment(LibraryStore.self) private var library
    @Environment(\.gameActions) private var actions
    let game: Game

    var body: some View {
        Button(game.isInstalled ? "Play" : "Install with Steam") { actions.play(game) }
        Button("Show Details") { actions.open(game) }
        Divider()
        Button(library.isFavorite(game) ? "Remove from Favorites" : "Add to Favorites") {
            library.toggleFavorite(game)
        }
        Menu("Collections") {
            ForEach(library.state.collections) { collection in
                Toggle(collection.name, isOn: Binding(
                    get: { collection.gameIDs.contains(game.id) },
                    set: { _ in library.toggle(game, in: collection.id) }
                ))
            }
            if !library.state.collections.isEmpty { Divider() }
            Button("New Collection…") { actions.newCollection(game) }
        }
        Divider()
        Button("Hide from Library") { library.setHidden(true, game: game) }
    }
}

/// Behind every layout: the selected game's art, a gradient, a colour or your own image.
struct ThemeBackdrop: View {
    @Environment(\.theme) private var theme
    let game: Game?
    var pointer: PointerField? = nil

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [theme.background.color, theme.backgroundEnd.color],
                startPoint: .top,
                endPoint: .bottom
            )
            switch theme.backdrop {
            case .artwork:
                GameArtwork(game: game, kind: .background) {
                    // Without a screenshot, a heavily blurred cover still sets the mood.
                    GameArtwork(game: game, kind: .cover) { Color.clear } content: { image in
                        AnyView(Image(nsImage: image).resizable().aspectRatio(contentMode: .fill).blur(radius: 60))
                    }
                } content: { image in
                    AnyView(Image(nsImage: image).resizable().interpolation(.high).aspectRatio(contentMode: .fill))
                }
                .blur(radius: theme.backdropBlur)
                .overlay(theme.background.color.opacity(theme.backdropDim))
                .id(game?.id)
                .transition(.opacity)
            case .image:
                if let path = theme.backdropImagePath, let image = NSImage(contentsOfFile: path) {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .blur(radius: theme.backdropBlur)
                        .overlay(theme.background.color.opacity(theme.backdropDim))
                }
            case .gradient:
                RadialGradient(
                    colors: [theme.accent.color.opacity(0.18), .clear],
                    center: .topLeading,
                    startRadius: 0,
                    endRadius: 900
                )
            case .solid:
                theme.background.color
            }
            AmbientLayer(pointer: pointer)
            if theme.vignette > 0 {
                EllipticalGradient(
                    colors: [.clear, .black.opacity(theme.vignette)],
                    center: .center, startRadiusFraction: 0.3, endRadiusFraction: 0.8
                )
            }
            // Keeps text readable where rows sit near the bottom.
            LinearGradient(
                colors: [.clear, theme.backgroundEnd.color.opacity(0.85)],
                startPoint: .center,
                endPoint: .bottom
            )
        }
        .animation(theme.animations ? .easeInOut(duration: 0.45) : nil, value: game?.id)
        .clipped()
        .ignoresSafeArea()
    }
}

/// "12 hr played · Yesterday", or nothing for games you haven't started.
struct GameStats {
    static func playtime(_ game: Game) -> String? {
        guard game.playtime >= 60 else { return nil }
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = game.playtime >= 3600 ? [.hour, .minute] : [.minute]
        formatter.unitsStyle = .short
        formatter.maximumUnitCount = 1
        return formatter.string(from: game.playtime).map { "\($0) played" }
    }

    static func lastPlayed(_ game: Game) -> String? {
        game.lastPlayed?.formatted(.relative(presentation: .named))
    }

    static func line(_ game: Game, showPlaytime: Bool) -> String {
        var parts = [game.platform.title]
        if !game.isInstalled { parts.append("Not installed") }
        if showPlaytime {
            parts += [playtime(game), lastPlayed(game)].compactMap { $0 }
        }
        return parts.joined(separator: "  ·  ")
    }
}

/// The game's logo if one exists, otherwise its title in large type.
struct GameTitleArt: View {
    @Environment(\.theme) private var theme
    let game: Game
    var maxHeight: CGFloat = 110
    var fontSize: CGFloat = 40

    var body: some View {
        GameArtwork(game: game, kind: .logo) {
            Text(game.title)
                .font(theme.font(size: fontSize, weight: .bold))
                .foregroundStyle(theme.text.color)
                .lineLimit(2)
                .minimumScaleFactor(0.5)
                .shadow(color: .black.opacity(0.4), radius: 8)
        } content: { image in
            AnyView(
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .shadow(color: .black.opacity(0.5), radius: 10)
            )
        }
        .frame(maxWidth: 520, maxHeight: maxHeight, alignment: .leading)
        .id(game.id)
    }
}

/// Play, details and favourite, used by layouts that show the selected game.
struct GameButtons: View {
    @Environment(\.theme) private var theme
    @Environment(\.gameActions) private var actions
    @Environment(LibraryStore.self) private var library
    let game: Game

    var body: some View {
        HStack(spacing: 10) {
            Button { actions.play(game) } label: {
                Label(game.isInstalled ? "Play" : "Install", systemImage: game.isInstalled ? "play.fill" : "arrow.down.circle.fill")
                    .font(theme.font(.body, weight: .semibold))
                    .padding(.horizontal, 18)
                    .padding(.vertical, 9)
                    .foregroundStyle(theme.accent.luminance > 0.6 ? .black : .white)
                    .background(theme.accent.color, in: Capsule())
            }
            .buttonStyle(.plain)
            .help(game.isInstalled ? "Play (Space)" : "Install with Steam (Space)")

            Button { actions.open(game) } label: {
                Label("Details", systemImage: "info.circle")
                    .font(theme.font(.body, weight: .medium))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .foregroundStyle(theme.text.color)
                    .background(theme.surface.color, in: Capsule())
                    .overlay(Capsule().strokeBorder(theme.text.color.opacity(0.15)))
            }
            .buttonStyle(.plain)
            .help("Show details (Return)")

            Button { library.toggleFavorite(game) } label: {
                Image(systemName: library.isFavorite(game) ? "star.fill" : "star")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: 36, height: 36)
                    .foregroundStyle(library.isFavorite(game) ? theme.accent.color : theme.text.color)
                    .background(theme.surface.color, in: Circle())
                    .overlay(Circle().strokeBorder(theme.text.color.opacity(0.15)))
            }
            .buttonStyle(.plain)
            .help(library.isFavorite(game) ? "Remove from Favorites" : "Add to Favorites")
        }
    }
}

/// A row of collection names to switch between.
struct CollectionTabs: View {
    @Environment(\.theme) private var theme
    let collections: [GameCollection]
    let selected: CollectionID?
    let select: (CollectionID) -> Void

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(collections) { collection in
                        let isSelected = collection.id == selected
                        Button { select(collection.id) } label: {
                            Label(collection.title, systemImage: collection.symbol)
                                .font(theme.font(.callout, weight: isSelected ? .semibold : .regular))
                                .padding(.horizontal, 14)
                                .padding(.vertical, 7)
                                .foregroundStyle(isSelected ? (theme.accent.luminance > 0.6 ? .black : .white) : theme.secondaryText.color)
                                .background(isSelected ? theme.accent.color : theme.surface.color, in: Capsule())
                        }
                        .buttonStyle(.plain)
                        .id(collection.id)
                    }
                }
            }
            .contentMargins(.horizontal, 32, for: .scrollContent)
            .onChange(of: selected) { _, id in
                withAnimation { proxy.scrollTo(id) }
            }
        }
    }
}
