import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    var body: some View {
        TabView {
            Tab("Appearance", systemImage: "paintpalette") { AppearanceSettings() }
            Tab("Collections", systemImage: "folder") { CollectionSettings() }
            Tab("Library", systemImage: "books.vertical") { LibrarySettings() }
        }
        .frame(width: 680, height: 640)
    }
}

// MARK: Appearance

private struct AppearanceSettings: View {
    @Environment(ThemeStore.self) private var themes
    @Environment(LibraryStore.self) private var library
    @State private var error: String?

    /// Edits write straight to the theme, so the library window updates as you drag.
    private func binding<Value>(_ keyPath: WritableKeyPath<Theme, Value>) -> Binding<Value> {
        Binding(
            get: { themes.current[keyPath: keyPath] },
            set: { value in
                var theme = themes.current
                theme[keyPath: keyPath] = value
                themes.save(theme)
            }
        )
    }

    private func color(_ keyPath: WritableKeyPath<Theme, HexColor>) -> Binding<Color> {
        Binding(
            get: { themes.current[keyPath: keyPath].color },
            set: { value in
                var theme = themes.current
                theme[keyPath: keyPath] = HexColor(value)
                themes.save(theme)
            }
        )
    }

    var body: some View {
        let theme = themes.current
        Form {
            Section {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 14)], spacing: 14) {
                    ForEach(themes.all) { candidate in
                        ThemeSwatch(theme: candidate, isSelected: candidate.id == theme.id)
                            .onTapGesture { themes.selectedID = candidate.id }
                            .contextMenu {
                                Button("Duplicate") { _ = themes.duplicate(candidate) }
                                Button("Export…") { export(candidate) }
                                if !candidate.isBuiltIn {
                                    Button("Delete", role: .destructive) { themes.delete(candidate) }
                                }
                            }
                    }
                }
                .padding(.vertical, 4)
                HStack {
                    Button("Import…", action: importTheme)
                    Button("Export…") { export(theme) }
                    Button("Show Themes Folder") { NSWorkspace.shared.open(themes.folder) }
                    Button("Reload") { themes.reload() }
                        .help("Pick up theme files you added or edited by hand")
                }
                .controlSize(.small)
            } header: {
                Text("Theme")
            } footer: {
                if theme.isBuiltIn {
                    Text("Built-in themes stay as they are. Changing anything below saves your version as a new theme.")
                }
            }

            Section("Identity") {
                TextField("Name", text: binding(\.name))
                LabeledContent("Author", value: theme.author)
            }

            Section("Layout") {
                Picker("Layout", selection: binding(\.layout)) {
                    ForEach(Theme.Layout.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                Text(theme.layout.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Slider(value: binding(\.coverScale), in: 0.6...1.6) { Text("Cover size") }
                Slider(value: binding(\.cornerRadius), in: 0...24) { Text("Corner rounding") }
                Picker("Selection style", selection: binding(\.highlight)) {
                    ForEach(Theme.Highlight.allCases) { Text($0.label).tag($0) }
                }
                Toggle("Show titles under covers", isOn: binding(\.showTitles))
                Toggle("Show playtime", isOn: binding(\.showPlaytime))
                Toggle("Animations", isOn: binding(\.animations))
                Toggle("Covers tilt under the pointer", isOn: binding(\.tilt))
                    .disabled(!theme.animations)
            }

            Section("Colors & type") {
                Picker("Typeface", selection: binding(\.typeface)) {
                    ForEach(Theme.Typeface.allCases) { Text($0.label).tag($0) }
                }
                ColorPicker("Background", selection: color(\.background), supportsOpacity: false)
                ColorPicker("Background fade", selection: color(\.backgroundEnd), supportsOpacity: false)
                ColorPicker("Panels", selection: color(\.surface))
                ColorPicker("Text", selection: color(\.text), supportsOpacity: false)
                ColorPicker("Secondary text", selection: color(\.secondaryText), supportsOpacity: false)
                ColorPicker("Accent", selection: color(\.accent), supportsOpacity: false)
            }

            Section("Backdrop") {
                Picker("Behind the library", selection: binding(\.backdrop)) {
                    ForEach(Theme.Backdrop.allCases) { Text($0.label).tag($0) }
                }
                Picker("Ambience", selection: binding(\.ambience)) {
                    ForEach(Theme.Ambience.allCases) { Text($0.label).tag($0) }
                }
                .disabled(!theme.animations)
                Slider(value: binding(\.vignette), in: 0...0.9) { Text("Edge shadow") }
                if theme.backdrop == .image {
                    LabeledContent("Image") {
                        HStack {
                            Text(theme.backdropImagePath.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "None")
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Button("Choose…", action: chooseBackdrop)
                        }
                    }
                }
                if theme.backdrop == .artwork || theme.backdrop == .image {
                    Slider(value: binding(\.backdropDim), in: 0...0.95) { Text("Dim") }
                    Slider(value: binding(\.backdropBlur), in: 0...60) { Text("Blur") }
                }
            }
        }
        .formStyle(.grouped)
        .alert("Couldn't use that theme", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK") {}
        } message: {
            Text(error ?? "")
        }
    }

    private func importTheme() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.message = "Choose a theme file"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try themes.importTheme(from: url) } catch { self.error = error.localizedDescription }
    }

    private func export(_ theme: Theme) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "\(theme.name).json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try themes.export(theme, to: url) } catch { self.error = error.localizedDescription }
    }

    private func chooseBackdrop() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.message = "Choose an image to show behind your library"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        var theme = themes.current
        theme.backdropImagePath = url.path
        themes.save(theme)
    }
}

/// A small preview of a theme: its colours, type and layout.
private struct ThemeSwatch: View {
    let theme: Theme
    let isSelected: Bool

    private var layoutSymbol: String {
        switch theme.layout {
        case .showcase: "rectangle.tophalf.inset.filled"
        case .carousel: "rectangle.stack"
        case .grid: "square.grid.3x3"
        case .shelf: "books.vertical"
        case .fan: "rectangle.portrait.on.rectangle.portrait.angled"
        case .scatter: "square.on.square.dashed"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .bottomLeading) {
                LinearGradient(colors: [theme.background.color, theme.backgroundEnd.color], startPoint: .top, endPoint: .bottom)
                HStack(alignment: .bottom, spacing: 5) {
                    ForEach(0..<4) { index in
                        RoundedRectangle(cornerRadius: min(theme.cornerRadius / 3, 4))
                            .fill(index == 1 ? theme.accent.color : theme.text.color.opacity(0.22))
                            .frame(width: 18, height: index == 1 ? 30 : 26)
                    }
                }
                .padding(10)
                HStack(spacing: 5) {
                    if theme.ambience != .none { Image(systemName: "sparkles") }
                    Image(systemName: layoutSymbol)
                }
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(theme.secondaryText.color)
                    .padding(8)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            }
            .frame(height: 70)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(isSelected ? Color.accentColor : .secondary.opacity(0.3), lineWidth: isSelected ? 3 : 1)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(theme.name)
                    .font(.system(.callout, design: theme.typeface.design, weight: .semibold))
                    .lineLimit(1)
                Text("\(theme.layout.label) · \(theme.author)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

// MARK: Collections

private struct CollectionSettings: View {
    @Environment(LibraryStore.self) private var library
    @State private var newName = ""

    private static let symbols = [
        "folder", "star", "heart", "flame", "trophy", "person.2", "gamecontroller", "sparkles",
        "moon", "bolt", "leaf", "crown", "flag.checkered", "puzzlepiece", "car", "shield",
    ]

    var body: some View {
        Form {
            Section {
                List {
                    ForEach(library.allCollectionIDs, id: \.self) { id in
                        row(id)
                    }
                    .onMove { source, destination in
                        var ids = library.allCollectionIDs
                        ids.move(fromOffsets: source, toOffset: destination)
                        library.setCollectionOrder(ids)
                    }
                }
                .frame(minHeight: 300)
            } header: {
                Text("Order and visibility")
            } footer: {
                Text("Drag to reorder. Empty collections are always hidden from the library.")
            }

            Section("New collection") {
                HStack {
                    TextField("Name", text: $newName)
                        .onSubmit(create)
                    Button("Create", action: create)
                        .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                Text("Add games to a collection from their right-click menu or details.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private func row(_ id: CollectionID) -> some View {
        HStack(spacing: 10) {
            Toggle("", isOn: Binding(
                get: { !library.isCollectionHidden(id) },
                set: { library.setCollectionHidden(!$0, id) }
            ))
            .labelsHidden()
            .toggleStyle(.checkbox)

            if case .custom(let uuid) = id, let collection = library.state.collections.first(where: { $0.id == uuid }) {
                Menu {
                    ForEach(Self.symbols, id: \.self) { symbol in
                        Button { library.updateCollection(with(collection) { $0.symbol = symbol }) } label: {
                            Label(symbol, systemImage: symbol)
                        }
                    }
                } label: {
                    Image(systemName: collection.symbol)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                TextField("Name", text: Binding(
                    get: { collection.name },
                    set: { name in library.updateCollection(with(collection) { $0.name = name }) }
                ))
                .textFieldStyle(.plain)
                Text("\(collection.gameIDs.count) games")
                    .foregroundStyle(.secondary)
                    .font(.caption)
                Button(role: .destructive) { library.deleteCollection(uuid) } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .help("Delete collection (the games stay in your library)")
            } else {
                Image(systemName: library.symbol(of: id))
                    .frame(width: 20)
                Text(library.title(of: id))
                Spacer()
            }
        }
    }

    private func with(_ collection: UserCollection, _ change: (inout UserCollection) -> Void) -> UserCollection {
        var copy = collection
        change(&copy)
        return copy
    }

    private func create() {
        let name = newName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        library.createCollection(named: name)
        newName = ""
    }
}

// MARK: Library

private struct LibrarySettings: View {
    @Environment(LibraryStore.self) private var library
    @AppStorage("launchFullscreen") private var launchFullscreen = false
    @AppStorage(ArtStore.downloadsEnabledKey) private var downloadCovers = true

    var body: some View {
        Form {
            Section("Playing") {
                Toggle("Start emulated games in fullscreen", isOn: $launchFullscreen)
            }
            Section("Artwork") {
                Toggle("Download missing covers, backgrounds and logos", isOn: $downloadCovers)
                Text("Sends game names to GitHub (libretro-thumbnails) and Steam's image servers to find art.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Nintendo 64") {
                LabeledContent("ROM folder") {
                    HStack {
                        Text(library.n64Folder.path)
                            .truncationMode(.middle)
                            .lineLimit(1)
                            .foregroundStyle(.secondary)
                        Button("Change…", action: chooseN64Folder)
                    }
                }
            }
            if !library.state.manualEntries.isEmpty {
                Section("Games you added") {
                    ForEach(library.state.manualEntries, id: \.self) { entry in
                        LabeledContent(entry.title) {
                            Button("Remove") {
                                library.removeManual(entry)
                                Task { await library.refresh() }
                            }
                        }
                    }
                }
            }
            if !library.hiddenGames.isEmpty {
                Section("Hidden games") {
                    ForEach(library.hiddenGames) { game in
                        LabeledContent(game.title) {
                            Button("Show") { library.setHidden(false, game: game) }
                        }
                    }
                }
            }
            Section("About") {
                LabeledContent("Version", value: Self.version)
                LabeledContent("Running from") {
                    Text(Bundle.main.bundlePath)
                        .truncationMode(.middle)
                        .lineLimit(1)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .help(Bundle.main.bundlePath)
                }
            }
        }
        .formStyle(.grouped)
    }

    /// "0.2 (2)", marked when it's a build run from Xcode rather than an installed release.
    private static var version: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = "\(info["CFBundleShortVersionString"] as? String ?? "?") (\(info["CFBundleVersion"] as? String ?? "?"))"
        #if DEBUG
        return version + " · Debug build"
        #else
        return version
        #endif
    }

    private func chooseN64Folder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.directoryURL = library.n64Folder
        panel.message = "Choose the folder that holds your N64 ROMs"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        library.setN64Folder(url)
        Task { await library.refresh() }
    }
}
