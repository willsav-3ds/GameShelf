import SwiftUI

@main
struct GameShelfApp: App {
    @State private var library = LibraryStore()
    @State private var themes = ThemeStore()

    var body: some Scene {
        WindowGroup("GameShelf", id: "library") {
            LibraryView()
                .environment(library)
                .environment(themes)
                .frame(minWidth: 860, minHeight: 520)
                .task { await library.refresh() }
        }
        .defaultSize(width: 1180, height: 820)
        .commands {
            CommandGroup(after: .newItem) {
                Button("Add Game…") { AddGamePanel.present(library: library) }
                    .keyboardShortcut("n")
                Button("Rescan Library") { Task { await library.refresh() } }
                    .keyboardShortcut("r")
            }
        }

        Settings {
            SettingsView()
                .environment(library)
                .environment(themes)
        }
    }
}

enum AddGamePanel {
    @MainActor
    static func present(library: LibraryStore) {
        let panel = NSOpenPanel()
        panel.message = "Choose a decomp, recomp or other game: an app or an executable."
        panel.prompt = "Add to Shelf"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.treatsFilePackagesAsDirectories = false
        guard panel.runModal() == .OK else { return }
        add(panel.urls, to: library)
    }

    @MainActor
    static func add(_ urls: [URL], to library: LibraryStore) {
        let rejected = urls.filter { !library.addManual(url: $0) }
        if let first = rejected.first {
            library.notice = LibraryStore.LaunchNotice(
                title: "\(first.lastPathComponent) can't be added",
                message: "GameShelf can add apps and executable files. ROMs appear automatically from your emulators' game folders."
            )
        }
        Task { await library.refresh() }
    }
}
