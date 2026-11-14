import SwiftUI
import UniformTypeIdentifiers

struct GameDetailView: View {
    @Environment(LibraryStore.self) private var library
    @Environment(\.theme) private var theme
    @Environment(\.gameActions) private var actions
    @Environment(\.dismiss) private var dismiss
    let game: Game
    @State private var discIndex = 0
    @State private var customArt: Set<ArtKind> = []
    @State private var isRenaming = false
    @State private var draftTitle = ""

    private var coverSize: CGSize {
        let aspect = game.platform.caseAspect
        return aspect >= 1 ? CGSize(width: 300, height: 300 / aspect) : CGSize(width: 340 * aspect, height: 340)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 26) {
            CoverImage(game: game, size: coverSize)
                .clipShape(RoundedRectangle(cornerRadius: theme.cornerRadius))
                .modifier(PointerTilt(size: coverSize, maxAngle: 14, draggable: true))
                .shadow(color: .black.opacity(0.5), radius: 14, y: 6)
                .help("Drag to turn the case")

            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    if isRenaming {
                        TextField("Title", text: $draftTitle)
                            .textFieldStyle(.roundedBorder)
                            .font(theme.font(.title2))
                            .onSubmit(commitRename)
                            .onExitCommand { isRenaming = false }
                    } else {
                        Text(game.title)
                            .font(theme.font(.title, weight: .bold))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Label("\(game.platform.title) · \(game.sourceLabel)", systemImage: game.platform.symbol)
                        .foregroundStyle(theme.secondaryText.color)
                }

                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
                    GridRow {
                        Text("Played").foregroundStyle(theme.secondaryText.color)
                        Text(GameStats.playtime(game) ?? "Not played yet")
                    }
                    GridRow {
                        Text("Last played").foregroundStyle(theme.secondaryText.color)
                        Text(GameStats.lastPlayed(game) ?? "Never")
                    }
                }
                .font(theme.font(.body))

                if game.discs.count > 1 {
                    Picker("Start from", selection: $discIndex) {
                        ForEach(Array(game.discs.enumerated()), id: \.offset) { index, disc in
                            Text(disc.label).tag(index)
                        }
                    }
                    .pickerStyle(.segmented)
                    .fixedSize()
                }

                HStack(spacing: 10) {
                    Button {
                        let disc = game.discs.indices.contains(discIndex) ? game.discs[discIndex] : nil
                        Task { await library.play(game, disc: disc) }
                        dismiss()
                    } label: {
                        Label(game.isInstalled ? "Play" : "Install", systemImage: game.isInstalled ? "play.fill" : "arrow.down.circle.fill")
                            .frame(minWidth: 110)
                    }
                    .controlSize(.large)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)

                    Button {
                        library.toggleFavorite(game)
                    } label: {
                        Image(systemName: library.isFavorite(game) ? "star.fill" : "star")
                    }
                    .controlSize(.large)
                    .help(library.isFavorite(game) ? "Remove from Favorites" : "Add to Favorites")
                    .keyboardShortcut("f", modifiers: [])

                    Menu {
                        ForEach(library.state.collections) { collection in
                            Toggle(collection.name, isOn: Binding(
                                get: { collection.gameIDs.contains(game.id) },
                                set: { _ in library.toggle(game, in: collection.id) }
                            ))
                        }
                        if !library.state.collections.isEmpty { Divider() }
                        Button("New Collection…") {
                            dismiss()
                            actions.newCollection(game)
                        }
                    } label: {
                        Label("Collections", systemImage: "folder.badge.plus")
                    }
                    .controlSize(.large)
                    .fixedSize()
                }

                Spacer(minLength: 0)

                HStack {
                    Menu("Customize") {
                        Button("Rename…") {
                            draftTitle = game.title
                            isRenaming = true
                        }
                        if library.hasCustomTitle(game) {
                            Button("Use Original Title") { library.rename(game, to: "") }
                        }
                        Divider()
                        ForEach(ArtKind.allCases, id: \.self) { kind in
                            Button("Choose \(kind.label) Image…") { chooseArt(kind) }
                        }
                        let custom = ArtKind.allCases.filter(customArt.contains)
                        if !custom.isEmpty {
                            Divider()
                            ForEach(custom, id: \.self) { kind in
                                Button("Use Automatic \(kind.label)") {
                                    Task {
                                        await library.resetArt(kind, for: game)
                                        customArt.remove(kind)
                                    }
                                }
                            }
                        }
                    }
                    .fixedSize()
                    if let location = game.location {
                        Button("Show in Finder") {
                            NSWorkspace.shared.activateFileViewerSelecting([location])
                        }
                    }
                    Button("Hide from Library") {
                        library.setHidden(true, game: game)
                        dismiss()
                    }
                    Spacer()
                    Button("Done") { dismiss() }
                        .keyboardShortcut(.cancelAction)
                }
                .controlSize(.small)
            }
        }
        .padding(24)
        .frame(width: 740)
        .frame(minHeight: coverSize.height + 48)
        .background {
            ZStack {
                theme.background.color
                GameArtwork(game: game, kind: .background) { Color.clear } content: { image in
                    AnyView(Image(nsImage: image).resizable().aspectRatio(contentMode: .fill))
                }
                .blur(radius: 30)
                .opacity(0.35)
            }
            .clipped()
        }
        .foregroundStyle(theme.text.color)
        .tint(theme.accent.color)
        .task {
            var found: Set<ArtKind> = []
            for kind in ArtKind.allCases where await ArtStore.shared.hasCustom(kind, for: game) {
                found.insert(kind)
            }
            customArt = found
        }
    }

    private func commitRename() {
        library.rename(game, to: draftTitle)
        isRenaming = false
    }

    private func chooseArt(_ kind: ArtKind) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.message = "Choose a \(kind.label.lowercased()) image for \(game.title)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            await library.setArt(kind, from: url, for: game)
            customArt.insert(kind)
        }
    }
}
