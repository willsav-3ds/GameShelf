import AppKit
import SwiftUI

// MARK: Showcase

/// A hero for the selected game over a row per collection, in the style of a streaming app.
struct ShowcaseLayout: View {
    @Environment(\.theme) private var theme
    let context: LayoutContext

    private var rowHeight: CGFloat { 180 * theme.coverScale }

    var body: some View {
        GeometryReader { proxy in
            VStack(alignment: .leading, spacing: 0) {
                if let game = context.focusedGame {
                    VStack(alignment: .leading, spacing: 14) {
                        Spacer(minLength: 0)
                        GameTitleArt(game: game, maxHeight: min(120, proxy.size.height * 0.16), fontSize: 46)
                        Text(GameStats.line(game, showPlaytime: theme.showPlaytime))
                            .font(theme.font(.callout, weight: .medium))
                            .foregroundStyle(theme.secondaryText.color)
                        GameButtons(game: game)
                    }
                    .padding(.horizontal, 48)
                    .padding(.bottom, 24)
                    .frame(height: max(230, proxy.size.height * 0.42), alignment: .bottomLeading)
                    .animation(theme.animations ? .easeOut(duration: 0.25) : nil, value: game.id)
                }

                ScrollViewReader { scroller in
                    ScrollView(.vertical, showsIndicators: false) {
                        // Not lazy, so rows scrolled out of view keep their horizontal position.
                        VStack(alignment: .leading, spacing: 26) {
                            ForEach(context.collections) { collection in
                                ShowcaseRow(collection: collection, context: context, rowHeight: rowHeight)
                                    .id(collection.id.key)
                            }
                        }
                        .padding(.vertical, 12)
                        .padding(.bottom, 30)
                    }
                    .onChange(of: context.focusedCollection) { _, id in
                        // No anchor: only scroll as far as needed to bring the row into view.
                        guard let id, !context.focusedByPointer else { return }
                        withAnimation(theme.animations ? .easeInOut(duration: 0.3) : nil) {
                            scroller.scrollTo(id.key)
                        }
                    }
                }
            }
        }
        .onAppear { shiftScroll.start() }
        .onDisappear { shiftScroll.stop() }
    }

    @State private var shiftScroll = ShiftScrollMonitor()
}

/// One collection's row in the showcase. It scrolls to a computed offset rather than to an item ID,
/// because scrolling to an ID also scrolls the page around the row and shifts everything.
private struct ShowcaseRow: View {
    @Environment(\.theme) private var theme
    let collection: GameCollection
    let context: LayoutContext
    let rowHeight: CGFloat
    @State private var position = ScrollPosition()
    @State private var viewportWidth: CGFloat = 0

    private let spacing: CGFloat = 18
    private let inset: CGFloat = 48

    private func width(of game: Game) -> CGFloat { rowHeight * game.platform.caseAspect }

    /// The offset that centres a game in the row, kept within the row's scrollable range.
    private func offset(centering target: Game) -> CGFloat? {
        guard let index = collection.games.firstIndex(where: { $0.id == target.id }) else { return nil }
        let widths = collection.games.map(width(of:))
        let leading = inset + widths[..<index].reduce(0, +) + spacing * CGFloat(index)
        let content = inset * 2 + widths.reduce(0, +) + spacing * CGFloat(max(widths.count - 1, 0))
        let centred = leading + widths[index] / 2 - viewportWidth / 2
        return min(max(centred, 0), max(content - viewportWidth, 0))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: collection.symbol)
                Text(collection.title)
                Text("\(collection.games.count)")
                    .foregroundStyle(theme.secondaryText.color)
                    .font(theme.font(.callout))
            }
            .font(theme.font(.title3, weight: .semibold))
            .padding(.horizontal, 48)

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: spacing) {
                    ForEach(collection.games) { game in
                        CoverCard(
                            game: game,
                            collection: collection.id,
                            size: CGSize(width: width(of: game), height: rowHeight),
                            isFocused: context.isFocused(game, in: collection.id)
                        )
                    }
                }
                .padding(.horizontal, inset)
                .padding(.vertical, 14)
            }
            .scrollPosition($position)
            .onScrollGeometryChange(for: CGFloat.self, of: \.containerSize.width) { _, width in viewportWidth = width }
            .onChange(of: context.focusedGame?.id) { _, _ in
                // Clicked covers are already in view; only keyboard and controller moves follow the selection.
                guard collection.id == context.focusedCollection, !context.focusedByPointer,
                      let game = context.focusedGame, let x = offset(centering: game) else { return }
                withAnimation(theme.animations ? .easeInOut(duration: 0.25) : nil) {
                    position.scrollTo(x: x)
                }
            }
        }
    }
}

/// Turns vertical scrolling into horizontal while Shift is held, so a mouse wheel or a trackpad
/// swipe can scroll the row under the pointer.
@MainActor
private final class ShiftScrollMonitor {
    private var monitor: Any?

    func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
            guard event.modifierFlags.contains(.shift), event.scrollingDeltaX == 0, event.scrollingDeltaY != 0,
                  let cgEvent = event.cgEvent?.copy() else { return event }
            let pairs: [(CGEventField, CGEventField)] = [
                (.scrollWheelEventDeltaAxis1, .scrollWheelEventDeltaAxis2),
                (.scrollWheelEventPointDeltaAxis1, .scrollWheelEventPointDeltaAxis2),
                (.scrollWheelEventFixedPtDeltaAxis1, .scrollWheelEventFixedPtDeltaAxis2),
            ]
            for (vertical, horizontal) in pairs {
                if vertical == .scrollWheelEventFixedPtDeltaAxis1 {
                    cgEvent.setDoubleValueField(horizontal, value: cgEvent.getDoubleValueField(vertical))
                    cgEvent.setDoubleValueField(vertical, value: 0)
                } else {
                    cgEvent.setIntegerValueField(horizontal, value: cgEvent.getIntegerValueField(vertical))
                    cgEvent.setIntegerValueField(vertical, value: 0)
                }
            }
            return NSEvent(cgEvent: cgEvent) ?? event
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}

// MARK: Carousel

/// Big covers sliding past the centre, one collection at a time. Fanned, they overlap and swing
/// around a point below the window like a hand of cards.
struct CarouselLayout: View {
    @Environment(\.theme) private var theme
    @Environment(\.gameActions) private var actions
    let context: LayoutContext
    var fanned = false
    @State private var scrolledID: String?

    var body: some View {
        GeometryReader { proxy in
            let height = min(proxy.size.height * 0.46, 380) * theme.coverScale
            let collection = context.collections.first { $0.id == context.focusedCollection }
            VStack(spacing: 0) {
                CollectionTabs(
                    collections: context.collections,
                    selected: context.focusedCollection,
                    select: context.selectCollection
                )
                .padding(.top, 14)

                Spacer(minLength: 10)

                if let collection {
                    ScrollView(.horizontal, showsIndicators: false) {
                        LazyHStack(alignment: .center, spacing: fanned ? -height * 0.08 : 26) {
                            ForEach(collection.games) { game in
                                CoverCard(
                                    game: game,
                                    collection: collection.id,
                                    size: CGSize(width: height * game.platform.caseAspect, height: height),
                                    isFocused: context.isFocused(game, in: collection.id),
                                    showsTitle: false
                                )
                                .visualEffect { [fanned] content, geometry in
                                    let frame = geometry.frame(in: .scrollView)
                                    let bounds = geometry.bounds(of: .scrollView) ?? frame
                                    let offset = (frame.midX - bounds.midX) / max(bounds.width / 2, 1)
                                    let distance = min(abs(offset), 1)
                                    // The card in the middle stands straight even if it's a little off centre.
                                    let swing = max(min(abs(offset), 1.2) - 0.06, 0) * (offset < 0 ? -17 : 17)
                                    return content
                                        .scaleEffect(1 - distance * (fanned ? 0.16 : 0.28))
                                        .rotationEffect(.degrees(fanned ? swing : 0), anchor: .bottom)
                                        .offset(y: fanned ? distance * distance * height * 0.2 : 0)
                                        .opacity(1 - distance * (fanned ? 0.3 : 0.55))
                                }
                                // Cards overlap in a fan, so the selected one comes to the front.
                                .zIndex(context.isFocused(game, in: collection.id) ? 1 : 0)
                                .id(LayoutContext.scrollID(collection.id, game))
                            }
                        }
                        .scrollTargetLayout()
                        .padding(.vertical, 30)
                    }
                    .scrollTargetBehavior(.viewAligned)
                    .scrollClipDisabled(fanned)
                    .safeAreaPadding(.horizontal, max(proxy.size.width / 2 - height * 0.4, 0))
                    .scrollPosition(id: $scrolledID, anchor: .center)
                    .frame(height: height + (fanned ? 70 + height * 0.2 : 70))
                    .id(collection.id)
                    .onAppear { scrolledID = context.focusedGame.map { LayoutContext.scrollID(collection.id, $0) } }
                    .onChange(of: context.focusedGame?.id) { _, _ in
                        let target = context.focusedGame.map { LayoutContext.scrollID(collection.id, $0) }
                        guard target != scrolledID else { return }
                        withAnimation(theme.animations ? .spring(duration: 0.35) : nil) { scrolledID = target }
                    }
                    .onChange(of: scrolledID) { _, id in
                        // Scrolling with a trackpad selects whatever lands in the middle.
                        guard let id, let game = collection.games.first(where: { LayoutContext.scrollID(collection.id, $0) == id }),
                              game.id != context.focusedGame?.id else { return }
                        actions.focus(collection.id, game)
                    }
                }

                if let game = context.focusedGame {
                    VStack(spacing: 10) {
                        Text(game.title)
                            .font(theme.font(.largeTitle, weight: .bold))
                            .lineLimit(1)
                            .minimumScaleFactor(0.6)
                        Text(GameStats.line(game, showPlaytime: theme.showPlaytime))
                            .font(theme.font(.callout, weight: .medium))
                            .foregroundStyle(theme.secondaryText.color)
                        GameButtons(game: game)
                            .padding(.top, 4)
                    }
                    .padding(.horizontal, 40)
                    .multilineTextAlignment(.center)
                }

                Spacer(minLength: 20)
            }
        }
    }
}

// MARK: Grid

/// A sidebar of collections, a cover grid and a panel about the selected game.
struct GridLayout: View {
    @Environment(\.theme) private var theme
    let context: LayoutContext

    private var cellWidth: CGFloat { 150 * theme.coverScale }
    private let spacing: CGFloat = 22

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: 210)
            Divider().opacity(0.3)
            grid
            if let game = context.focusedGame {
                Divider().opacity(0.3)
                GridInfoPanel(game: game)
                    .frame(width: 300)
            }
        }
    }

    private var sidebar: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(context.collections) { collection in
                    let isSelected = collection.id == context.focusedCollection
                    Button { context.selectCollection(collection.id) } label: {
                        HStack(spacing: 10) {
                            Image(systemName: collection.symbol)
                                .frame(width: 18)
                            Text(collection.title)
                                .lineLimit(1)
                            Spacer()
                            Text("\(collection.games.count)")
                                .font(theme.font(.caption))
                                .foregroundStyle(isSelected ? theme.text.color : theme.secondaryText.color)
                        }
                        .font(theme.font(.body, weight: isSelected ? .semibold : .regular))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(isSelected ? theme.accent.color.opacity(0.22) : .clear, in: RoundedRectangle(cornerRadius: max(theme.cornerRadius, 4)))
                        .overlay(alignment: .leading) {
                            if isSelected {
                                Capsule().fill(theme.accent.color).frame(width: 3, height: 18).offset(x: 2)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(12)
        }
    }

    private var grid: some View {
        GeometryReader { proxy in
            let columns = max(1, Int((proxy.size.width - 48 + spacing) / (cellWidth + spacing)))
            let collection = context.collections.first { $0.id == context.focusedCollection }
            ScrollViewReader { scroller in
                ScrollView {
                    if let collection {
                        LazyVGrid(columns: Array(repeating: GridItem(.fixed(cellWidth), spacing: spacing, alignment: .bottom), count: columns), spacing: 26) {
                            ForEach(collection.games) { game in
                                CoverCard(
                                    game: game,
                                    collection: collection.id,
                                    size: CGSize(width: cellWidth, height: cellWidth / game.platform.caseAspect),
                                    isFocused: context.isFocused(game, in: collection.id)
                                )
                                .id(LayoutContext.scrollID(collection.id, game))
                            }
                        }
                        .padding(24)
                    }
                }
                .onAppear { context.gridColumns.wrappedValue = columns }
                .onChange(of: columns) { _, value in context.gridColumns.wrappedValue = value }
                .onChange(of: context.focusedGame?.id) { _, _ in
                    guard let collection, let game = context.focusedGame else { return }
                    withAnimation(theme.animations ? .easeInOut(duration: 0.2) : nil) {
                        scroller.scrollTo(LayoutContext.scrollID(collection.id, game))
                    }
                }
            }
        }
    }
}

private struct GridInfoPanel: View {
    @Environment(\.theme) private var theme
    let game: Game

    private var coverSize: CGSize {
        let aspect = game.platform.caseAspect
        return aspect >= 1 ? CGSize(width: 252, height: 252 / aspect) : CGSize(width: 300 * aspect, height: 300)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                CoverImage(game: game, size: coverSize)
                    .clipShape(RoundedRectangle(cornerRadius: theme.cornerRadius))
                    .modifier(PointerTilt(size: coverSize, maxAngle: 12, draggable: true))
                    .shadow(color: .black.opacity(0.4), radius: 12, y: 6)
                    .frame(maxWidth: .infinity)
                VStack(alignment: .leading, spacing: 6) {
                    Text(game.title)
                        .font(theme.font(.title2, weight: .bold))
                        .fixedSize(horizontal: false, vertical: true)
                    Label(game.platform.title, systemImage: game.platform.symbol)
                        .foregroundStyle(theme.secondaryText.color)
                }
                if theme.showPlaytime {
                    Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                        GridRow {
                            Text("Played").foregroundStyle(theme.secondaryText.color)
                            Text(GameStats.playtime(game) ?? "Not yet")
                        }
                        GridRow {
                            Text("Last played").foregroundStyle(theme.secondaryText.color)
                            Text(GameStats.lastPlayed(game) ?? "Never")
                        }
                    }
                    .font(theme.font(.callout))
                }
                GameButtons(game: game)
            }
            .padding(22)
        }
        .background(theme.surface.color.opacity(0.5))
    }
}

// MARK: Bookshelf

/// Game cases standing on wooden shelves: one shelf per collection.
struct ShelfLayout: View {
    @Environment(\.theme) private var theme
    let context: LayoutContext

    var body: some View {
        GeometryReader { proxy in
            ScrollViewReader { scroller in
                ScrollView {
                    VStack(spacing: 34) {
                        ForEach(context.collections) { collection in
                            ShelfSection(collection: collection, context: context, availableWidth: proxy.size.width)
                                .id(collection.id.key)
                        }
                    }
                    .padding(.vertical, 30)
                }
                .onChange(of: context.focusedCollection) { _, id in
                    guard let id else { return }
                    withAnimation(theme.animations ? .easeInOut(duration: 0.3) : nil) {
                        scroller.scrollTo(id.key, anchor: .center)
                    }
                }
            }
        }
    }
}

private struct ShelfSection: View {
    @Environment(\.theme) private var theme
    let collection: GameCollection
    let context: LayoutContext
    let availableWidth: CGFloat

    private let spacing: CGFloat = 26
    private let sideInset: CGFloat = 42

    /// Mixed collections use the most common case shape so each shelf lines up.
    private var caseAspect: CGFloat {
        let counts = Dictionary(grouping: collection.games, by: \.platform.caseAspect).mapValues(\.count)
        return counts.max { $0.value < $1.value }?.key ?? 0.7
    }

    private var caseSize: CGSize {
        let height: CGFloat = (caseAspect > 1.2 ? 170 : (caseAspect > 0.9 ? 196 : 244)) * theme.coverScale
        return CGSize(width: height * caseAspect, height: height)
    }

    private var rows: [[Game]] {
        let usable = max(availableWidth - sideInset * 2, caseSize.width)
        let perRow = max(1, Int((usable + spacing) / (caseSize.width + spacing)))
        return stride(from: 0, to: collection.games.count, by: perRow).map {
            Array(collection.games[$0..<min($0 + perRow, collection.games.count)])
        }
    }

    var body: some View {
        VStack(spacing: 22) {
            ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                VStack(spacing: 0) {
                    HStack(alignment: .bottom, spacing: spacing) {
                        ForEach(row) { game in
                            CoverCard(
                                game: game,
                                collection: collection.id,
                                size: caseSize,
                                isFocused: context.isFocused(game, in: collection.id),
                                showsTitle: false
                            )
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, sideInset)
                    .zIndex(1)

                    ShelfPlank(label: index == 0 ? collection.title : nil, count: index == 0 ? collection.games.count : nil)
                }
            }
        }
    }
}

private struct ShelfPlank: View {
    @Environment(\.theme) private var theme
    let label: String?
    let count: Int?

    var body: some View {
        VStack(spacing: 0) {
            // Top face, seen from slightly above: the surface the cases stand on.
            LinearGradient(
                colors: [Color(red: 0.36, green: 0.22, blue: 0.12), Color(red: 0.5, green: 0.31, blue: 0.17)],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: 8)

            ZStack {
                WoodGrain()
                if let label {
                    HStack(spacing: 8) {
                        Text(label.uppercased())
                            .kerning(2)
                            .font(theme.font(size: 11, weight: .semibold))
                        if let count {
                            Text("\(count)")
                                .font(theme.font(size: 10, weight: .medium))
                                .opacity(0.65)
                        }
                    }
                    .foregroundStyle(theme.accent.luminance > 0.5 ? Color(red: 0.2, green: 0.12, blue: 0.04) : .white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 3)
                    .background(
                        LinearGradient(
                            colors: [theme.accent.color, theme.accent.color.opacity(0.75)],
                            startPoint: .top,
                            endPoint: .bottom
                        ),
                        in: RoundedRectangle(cornerRadius: 2)
                    )
                    .shadow(color: .black.opacity(0.4), radius: 1, y: 1)
                }
            }
            .frame(height: 26)

            // Shadow the plank throws on the back panel.
            LinearGradient(colors: [.black.opacity(0.5), .clear], startPoint: .top, endPoint: .bottom)
                .frame(height: 16)
        }
    }
}

private struct WoodGrain: View {
    var body: some View {
        Canvas { context, size in
            context.fill(
                Path(CGRect(origin: .zero, size: size)),
                with: .linearGradient(
                    Gradient(colors: [Color(red: 0.34, green: 0.2, blue: 0.11), Color(red: 0.22, green: 0.125, blue: 0.07)]),
                    startPoint: .zero,
                    endPoint: CGPoint(x: 0, y: size.height)
                )
            )
            // Fixed seed values, so the grain doesn't shimmer when the view redraws.
            var seed: UInt64 = 0x5EED
            func next() -> CGFloat {
                seed = seed &* 6364136223846793005 &+ 1442695040888963407
                return CGFloat(seed >> 40) / CGFloat(1 << 24)
            }
            for _ in 0..<12 {
                let y = next() * size.height
                let start = next() * size.width
                var line = Path()
                line.move(to: CGPoint(x: start - 200, y: y))
                line.addCurve(
                    to: CGPoint(x: start + 400, y: y + next() * 2 - 1),
                    control1: CGPoint(x: start, y: y + next() * 3 - 1.5),
                    control2: CGPoint(x: start + 200, y: y + next() * 3 - 1.5)
                )
                context.stroke(line, with: .color(.black.opacity(0.1 + next() * 0.14)), lineWidth: 0.5 + next() * 0.7)
            }
        }
    }
}

// MARK: Cloud

/// Where each cover sits in the cloud. A plain class shared with the library window, which needs the
/// positions to move the selection toward whichever cover lies in a direction.
@MainActor
final class CloudMap {
    private(set) var frames: [String: CGRect] = [:]
    private var key = ""

    /// Packs one collection into a cluster that fits the area. The games you've played most are the
    /// biggest and sit in the middle.
    func place(_ games: [Game], in area: CGSize, coverScale: CGFloat) -> [String: CGRect] {
        let newKey = "\(games.map { "\($0.id):\(Int($0.playtime))" }.joined(separator: "|"))#\(Int(area.width))x\(Int(area.height))#\(coverScale)"
        guard newKey != key else { return frames }
        key = newKey
        frames = [:]
        guard area.width > 0, area.height > 0, !games.isEmpty else { return frames }

        let most = games.map { log(1 + $0.playtime / 60) }.max() ?? 0
        let sized = games.map { game -> (game: Game, size: CGSize) in
            let played = most > 0 ? log(1 + game.playtime / 60) / most : 0
            // A little variety of their own, so a shelf of unplayed games still clusters instead of forming a grid.
            let variety = Double(game.id.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xFFFF } % 100) / 100
            let height = 150 * (0.55 + 0.7 * played + 0.2 * variety)
            return (game, CGSize(width: height * game.platform.caseAspect, height: height))
        }
        .sorted { $0.size.height > $1.size.height }

        // Each cover takes the first free spot on a spiral out from the centre, stretched to the area's shape.
        let stretch = max(min(area.width / area.height, 2.4), 1)
        let gap: CGFloat = 9
        var placed: [CGRect] = []
        for item in sized {
            var rect = CGRect.zero
            for step in 0..<6000 {
                let angle = Double(step) * 0.3
                let radius = 3 * angle
                rect = CGRect(
                    x: cos(angle) * radius * stretch - item.size.width / 2, y: sin(angle) * radius - item.size.height / 2,
                    width: item.size.width, height: item.size.height
                )
                let padded = rect.insetBy(dx: -gap, dy: -gap)
                if !placed.contains(where: padded.intersects) { break }
            }
            placed.append(rect)
        }
        // The spiral leaves gaps, so everything then shuffles toward the middle until the covers are touching.
        for _ in 0..<60 {
            var moved = false
            for index in placed.indices {
                for shift in [CGSize(width: placed[index].midX > 0 ? -4 : 4, height: 0), CGSize(width: 0, height: placed[index].midY > 0 ? -4 : 4)] {
                    let rect = placed[index]
                    guard abs(shift.width == 0 ? rect.midY : rect.midX) > 4 else { continue }
                    let padded = rect.offsetBy(dx: shift.width, dy: shift.height).insetBy(dx: -gap, dy: -gap)
                    if !placed.indices.contains(where: { $0 != index && padded.intersects(placed[$0]) }) {
                        placed[index] = rect.offsetBy(dx: shift.width, dy: shift.height)
                        moved = true
                    }
                }
            }
            if !moved { break }
        }

        // Then the whole cloud grows or shrinks to fill the area.
        let bounds = placed.reduce(placed[0]) { $0.union($1) }
        let scale = min(area.width / bounds.width, area.height / bounds.height, 1.5) * coverScale
        for (item, rect) in zip(sized, placed) {
            frames[item.game.id] = CGRect(
                x: area.width / 2 + (rect.minX - bounds.midX) * scale, y: area.height / 2 + (rect.minY - bounds.midY) * scale,
                width: rect.width * scale, height: rect.height * scale
            )
        }
        return frames
    }

    /// The closest cover in a direction, favouring ones straight ahead.
    func neighbor(of id: String, dx: Int, dy: Int) -> String? {
        guard let from = frames[id] else { return nil }
        var best: (id: String, cost: CGFloat)?
        for (candidate, frame) in frames where candidate != id {
            let along = (frame.midX - from.midX) * CGFloat(dx) + (frame.midY - from.midY) * CGFloat(dy)
            let across = abs((frame.midX - from.midX) * CGFloat(dy)) + abs((frame.midY - from.midY) * CGFloat(dx))
            guard along > 1, across < along * 2 else { continue }
            let cost = along + across * 2
            if cost < best?.cost ?? .infinity { best = (candidate, cost) }
        }
        return best?.id
    }
}

/// One collection at a time, gathered into a cluster of upright covers in different sizes.
struct CloudLayout: View {
    @Environment(\.theme) private var theme
    let context: LayoutContext
    @State private var hoveredID: String?

    var body: some View {
        let collection = context.collections.first { $0.id == context.focusedCollection }
        VStack(spacing: 0) {
            CollectionTabs(
                collections: context.collections,
                selected: context.focusedCollection,
                select: context.selectCollection
            )
            .padding(.top, 14)

            GeometryReader { proxy in
                if let collection {
                    let frames = context.cloud.place(collection.games, in: proxy.size, coverScale: theme.coverScale)
                    ZStack(alignment: .topLeading) {
                        ForEach(collection.games) { game in
                            let frame = frames[game.id] ?? .zero
                            let isFocused = context.isFocused(game, in: collection.id)
                            CoverCard(game: game, collection: collection.id, size: frame.size, isFocused: isFocused, showsTitle: false)
                                // The cover under the pointer swells and comes forward.
                                .scaleEffect(theme.animations && hoveredID == game.id ? 1.12 : 1)
                                .onHover { inside in
                                    if inside { hoveredID = game.id } else if hoveredID == game.id { hoveredID = nil }
                                }
                                .position(x: frame.midX, y: frame.midY)
                                .zIndex(isFocused ? 2 : (hoveredID == game.id ? 1 : 0))
                        }
                    }
                    .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
                    .animation(theme.animations ? .spring(duration: 0.45, bounce: 0.2) : nil, value: collection.id)
                    .animation(theme.animations ? .spring(duration: 0.25) : nil, value: hoveredID)
                }
            }
            .padding(.horizontal, 40)
            .padding(.vertical, 22)

            if let game = context.focusedGame {
                VStack(spacing: 8) {
                    Text(game.title)
                        .font(theme.font(.title, weight: .bold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                    Text(GameStats.line(game, showPlaytime: theme.showPlaytime))
                        .font(theme.font(.callout, weight: .medium))
                        .foregroundStyle(theme.secondaryText.color)
                    GameButtons(game: game)
                        .padding(.top, 4)
                }
                .padding(.horizontal, 40)
                .padding(.bottom, 26)
            }
        }
    }
}
