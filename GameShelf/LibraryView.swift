import SwiftUI

/// The main window. Holds the selection and input handling; the theme's layout draws everything else.
struct LibraryView: View {
    @Environment(LibraryStore.self) private var library
    @Environment(ThemeStore.self) private var themes
    @AppStorage("sortOrder") private var sortOrder: SortOrder = .title
    @State private var query = ""
    @State private var focusedCollection: CollectionID?
    @State private var focusedGameID: String?
    /// Where you were in each collection, so switching back returns there.
    @State private var lastFocus: [CollectionID: String] = [:]
    @State private var gridColumns = 5
    /// Whether the last selection came from a click, which shouldn't scroll anything.
    @State private var focusedByPointer = false
    @State private var detailID: String?
    @State private var isDropTargeted = false
    @State private var newCollectionFor: Game?
    @State private var newCollectionName = ""
    @State private var gamepad = GamepadInput()
    @State private var pointer = PointerField()
    @FocusState private var hasKeyboardFocus: Bool

    private var theme: Theme { themes.current }

    private var collections: [GameCollection] {
        let all = library.collections(matching: query, sortedBy: sortOrder)
        // The grid's sidebar is the collection list, so it keeps "All Games". Rows would just repeat it.
        guard theme.layout != .grid else { return all }
        let withoutAll = all.filter { $0.id != .all }
        return withoutAll.isEmpty ? all : withoutAll
    }

    /// The selected collection and game, falling back to the first available.
    private var focus: (collection: GameCollection, game: Game)? {
        let collections = collections
        guard let collection = collections.first(where: { $0.id == focusedCollection }) ?? collections.first,
              let game = collection.games.first(where: { $0.id == focusedGameID }) ?? collection.games.first else { return nil }
        return (collection, game)
    }

    var body: some View {
        @Bindable var library = library
        let focus = focus
        let context = LayoutContext(
            collections: collections,
            focusedCollection: focus?.collection.id,
            focusedGame: focus?.game,
            focusedByPointer: focusedByPointer,
            gridColumns: $gridColumns,
            selectCollection: { switchTo($0) }
        )

        Group {
            switch theme.layout {
            case .showcase: ShowcaseLayout(context: context)
            case .carousel: CarouselLayout(context: context)
            case .grid: GridLayout(context: context)
            case .shelf: ShelfLayout(context: context)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onGeometryChange(for: CGSize.self, of: \.size) { pointer.size = $0 }
        .onContinuousHover { phase in
            if case .active(let location) = phase { pointer.location = location } else { pointer.location = nil }
        }
        .overlay { emptyState }
        // A background, not a ZStack sibling: artwork drawn to fill would otherwise grow the window's
        // layout to its own size, shifting everything each time the selected game's art changes.
        .background { ThemeBackdrop(game: focus?.game, pointer: pointer) }
        .environment(\.theme, theme)
        .environment(\.gameActions, actions)
        .foregroundStyle(theme.text.color)
        .tint(theme.accent.color)
        .preferredColorScheme(theme.isLight ? .light : .dark)
        .toolbarBackground(.hidden, for: .windowToolbar)
        .focusable()
        .focusEffectDisabled()
        .focused($hasKeyboardFocus)
        .onAppear {
            hasKeyboardFocus = true
            gamepad.handler = handle
        }
        .onKeyPress(keys: [.leftArrow, .rightArrow, .upArrow, .downArrow, .return, .space, .pageUp, .pageDown, "[", "]", "f"]) { press in
            switch press.key {
            case .leftArrow: handle(.move(dx: -1, dy: 0))
            case .rightArrow: handle(.move(dx: 1, dy: 0))
            case .upArrow: handle(.move(dx: 0, dy: -1))
            case .downArrow: handle(.move(dx: 0, dy: 1))
            case .return: handle(.confirm)
            case .space: handle(.play)
            case .pageUp, "[": handle(.switchCollection(-1))
            case .pageDown, "]": handle(.switchCollection(1))
            case "f": handle(.favorite)
            default: return .ignored
            }
            return .handled
        }
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(theme.accent.color, lineWidth: 3)
                    .padding(6)
                    .allowsHitTesting(false)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            AddGamePanel.add(urls, to: library)
            return true
        } isTargeted: { isDropTargeted = $0 }
        .searchable(text: $query, placement: .toolbar, prompt: "Search games")
        .toolbar { toolbar }
        .sheet(item: Binding(
            get: { detailID.flatMap(library.game(id:)) },
            set: { detailID = $0?.id }
        )) { game in
            GameDetailView(game: game)
                .environment(library)
                .environment(\.theme, theme)
                .environment(\.gameActions, actions)
                .preferredColorScheme(theme.isLight ? .light : .dark)
        }
        .alert(item: $library.notice) { notice in
            Alert(title: Text(notice.title), message: Text(notice.message))
        }
        .alert("New Collection", isPresented: Binding(
            get: { newCollectionFor != nil },
            set: { if !$0 { newCollectionFor = nil } }
        )) {
            TextField("Name", text: $newCollectionName)
            Button("Create") {
                let name = newCollectionName.trimmingCharacters(in: .whitespaces)
                if !name.isEmpty { library.createCollection(named: name, with: newCollectionFor) }
                newCollectionName = ""
            }
            Button("Cancel", role: .cancel) { newCollectionName = "" }
        } message: {
            if let game = newCollectionFor { Text("\(game.title) will be added to it.") }
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem {
            Menu {
                Picker("Theme", selection: Binding(get: { themes.selectedID }, set: { themes.selectedID = $0 })) {
                    ForEach(themes.all) { Text($0.name).tag($0.id) }
                }
                .pickerStyle(.inline)
                Divider()
                SettingsLink { Text("Customize…") }
            } label: {
                Label("Theme", systemImage: "paintpalette")
            }
            .help("Switch themes")
        }
        ToolbarItem {
            Picker("Sort", selection: $sortOrder) {
                ForEach(SortOrder.allCases) { Text($0.rawValue).tag($0) }
            }
            .help("Sort games in each collection")
        }
        ToolbarItem {
            Button("Add Game", systemImage: "plus") { AddGamePanel.present(library: library) }
                .help("Add a decomp, recomp or other game")
        }
        ToolbarItem {
            Button("Rescan", systemImage: "arrow.clockwise") { Task { await library.refresh() } }
                .disabled(library.isScanning)
                .help("Rescan your emulators and apps")
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if collections.isEmpty && !library.isScanning {
            Group {
                if query.isEmpty {
                    ContentUnavailableView(
                        "Your library is empty",
                        systemImage: "gamecontroller",
                        description: Text("Add game folders in DuckStation or PCSX2, or drag a game here.")
                    )
                } else {
                    ContentUnavailableView.search(text: query)
                }
            }
            .foregroundStyle(theme.text.color)
        }
    }

    // MARK: Actions

    private var actions: GameActions {
        GameActions(
            focus: { collection, game in setFocus(collection, game.id, byPointer: true) },
            open: { detailID = $0.id },
            play: { game in Task { await library.play(game) } },
            newCollection: { newCollectionFor = $0 }
        )
    }

    private func setFocus(_ collection: CollectionID, _ gameID: String, byPointer: Bool = false) {
        focusedByPointer = byPointer
        focusedCollection = collection
        focusedGameID = gameID
        lastFocus[collection] = gameID
    }

    private func switchTo(_ collection: CollectionID) {
        let games = collections.first { $0.id == collection }?.games ?? []
        let remembered = lastFocus[collection].flatMap { id in games.first { $0.id == id } }
        guard let game = remembered ?? games.first else { return }
        setFocus(collection, game.id)
    }

    private func handle(_ input: GamepadInput.Action) {
        // The details sheet handles its own keys; a controller's B button closes it.
        if detailID != nil {
            switch input {
            case .back: detailID = nil
            case .play:
                if let game = detailID.flatMap(library.game(id:)) { Task { await library.play(game) } }
                detailID = nil
            default: break
            }
            return
        }
        guard let focus else { return }
        switch input {
        case .move(let dx, let dy): move(dx: dx, dy: dy, from: focus)
        case .switchCollection(let delta):
            let ids = collections.map(\.id)
            guard let index = ids.firstIndex(of: focus.collection.id) else { return }
            switchTo(ids[(index + delta + ids.count) % ids.count])
        case .confirm: detailID = focus.game.id
        case .play: Task { await library.play(focus.game) }
        case .favorite: library.toggleFavorite(focus.game)
        case .back: break
        }
    }

    private func move(dx: Int, dy: Int, from focus: (collection: GameCollection, game: Game)) {
        let games = focus.collection.games
        let index = games.firstIndex { $0.id == focus.game.id } ?? 0
        if theme.layout == .grid {
            // Up and down move by a row; leaving the grid's top or bottom does nothing.
            let target = index + dx + dy * gridColumns
            guard games.indices.contains(target) else { return }
            setFocus(focus.collection.id, games[target].id)
        } else if dy != 0 {
            let ids = collections.map(\.id)
            guard let row = ids.firstIndex(of: focus.collection.id), ids.indices.contains(row + dy) else { return }
            switchTo(ids[row + dy])
        } else {
            let target = min(max(index + dx, 0), games.count - 1)
            setFocus(focus.collection.id, games[target].id)
        }
    }
}

/// What every layout gets to draw with.
struct LayoutContext {
    var collections: [GameCollection]
    var focusedCollection: CollectionID?
    var focusedGame: Game?
    var focusedByPointer: Bool
    var gridColumns: Binding<Int>
    var selectCollection: (CollectionID) -> Void

    func isFocused(_ game: Game, in collection: CollectionID) -> Bool {
        collection == focusedCollection && game.id == focusedGame?.id
    }

    /// A scroll position ID that stays unique when one game appears in several collections.
    static func scrollID(_ collection: CollectionID, _ game: Game) -> String {
        "\(collection.key)|\(game.id)"
    }
}
