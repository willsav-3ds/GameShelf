import SwiftUI

/// Where the pointer is over the library. A plain class rather than view state: the backdrop reads it
/// once per frame, so moving the mouse never re-renders the window.
@MainActor
final class PointerField {
    struct Sample {
        /// 0...1 across the window, resting at the centre when the pointer is elsewhere.
        var position = CGPoint(x: 0.5, y: 0.5)
        /// 1 while the pointer is over the library, easing to 0 after it leaves.
        var presence = 0.0
    }

    var size: CGSize = .zero
    var location: CGPoint?
    private var eased = Sample()
    private var lastTime: TimeInterval?

    /// The pointer eased toward where it really is, so effects glide instead of snapping.
    func sample(at time: TimeInterval) -> Sample {
        let elapsed = min(max(time - (lastTime ?? time), 0), 0.1)
        lastTime = time
        var goal = Sample()
        if let location, size.width > 0, size.height > 0 {
            goal = Sample(position: CGPoint(x: location.x / size.width, y: location.y / size.height), presence: 1)
        }
        let blend = 1 - exp(-elapsed * 6)
        eased.position.x += (goal.position.x - eased.position.x) * blend
        eased.position.y += (goal.position.y - eased.position.y) * blend
        eased.presence += (goal.presence - eased.presence) * blend
        return eased
    }
}

/// The theme's moving backdrop, drawn over its colours or artwork. Everything is a pure function of
/// time, so there's no simulation to keep in step and a paused frame still looks right.
struct AmbientLayer: View {
    @Environment(\.theme) private var theme
    @Environment(\.controlActiveState) private var activeState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let pointer: PointerField?
    @State private var start = Date()

    var body: some View {
        if theme.ambience != .none {
            // Stops drawing while another app is in front, which is whenever a game is running.
            let paused = !theme.animations || reduceMotion || activeState == .inactive
            // Code rain reads better at a terminal's pace, and it's the most drawing per frame.
            let interval: Double? = theme.ambience == .rain ? 1.0 / 20 : nil
            TimelineView(.animation(minimumInterval: interval, paused: paused)) { timeline in
                let time = timeline.date.timeIntervalSince(start)
                let sample = pointer?.sample(at: time) ?? PointerField.Sample()
                Canvas { context, size in
                    switch theme.ambience {
                    case .none: break
                    case .stars: drawStars(context, size: size, time: time, pointer: sample)
                    case .grid: drawGrid(context, size: size, time: time, pointer: sample)
                    case .rain: drawRain(context, size: size, time: time, pointer: sample)
                    case .embers: drawEmbers(context, size: size, time: time, pointer: sample)
                    case .bubbles: drawBubbles(context, size: size, time: time, pointer: sample)
                    case .moon: drawMoon(context, size: size, time: time, pointer: sample)
                    case .fog: drawFog(context, size: size, time: time, pointer: sample)
                    case .ash: drawAsh(context, size: size, time: time, pointer: sample)
                    case .wisps: drawWisps(context, size: size, time: time, pointer: sample)
                    }
                    drawPointerGlow(context, size: size, pointer: sample)
                }
            }
            .allowsHitTesting(false)
        }
    }

    private var accent: Color { theme.accent.color }

    /// A stable pseudo-random value in 0..<1 for a particle and one of its properties.
    private func noise(_ index: Int, _ salt: Int) -> Double {
        var value = UInt64(truncatingIfNeeded: (index &+ 1) &* 73_856_093 ^ (salt &+ 1) &* 19_349_663)
        value = (value ^ (value >> 33)) &* 0xFF51_AFD7_ED55_8CCD
        value = (value ^ (value >> 33)) &* 0xC4CE_B9FE_1A85_EC53
        value ^= value >> 33
        return Double(value >> 11) / Double(1 << 53)
    }

    private func fraction(_ value: Double) -> Double { value - value.rounded(.down) }

    /// A soft light that follows the pointer.
    private func drawPointerGlow(_ context: GraphicsContext, size: CGSize, pointer: PointerField.Sample) {
        guard pointer.presence > 0.01 else { return }
        var context = context
        if !theme.isLight { context.blendMode = .plusLighter }
        let center = CGPoint(x: pointer.position.x * size.width, y: pointer.position.y * size.height)
        let radius: CGFloat = 340
        context.fill(
            Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)),
            with: .radialGradient(
                Gradient(colors: [accent.opacity(0.11 * pointer.presence), accent.opacity(0)]),
                center: center, startRadius: 0, endRadius: radius
            )
        )
    }

    // MARK: Starfield

    /// Twinkling stars in layers that shift against each other as the pointer moves.
    private func drawStars(_ context: GraphicsContext, size: CGSize, time: Double, pointer: PointerField.Sample) {
        for index in 0..<150 {
            let depth = 0.25 + noise(index, 0) * 0.75
            let x = fraction(noise(index, 1) + time * 0.003 * depth - (pointer.position.x - 0.5) * 0.05 * depth)
            let y = noise(index, 2) - (pointer.position.y - 0.5) * 0.05 * depth
            let twinkle = 0.55 + 0.45 * sin(time * (0.6 + noise(index, 3) * 1.8) + noise(index, 4) * 2 * .pi)
            let radius = 0.5 + depth * 1.3
            let color = index % 4 == 0 ? accent : theme.text.color
            context.fill(
                Path(ellipseIn: CGRect(x: x * size.width - radius, y: y * size.height - radius, width: radius * 2, height: radius * 2)),
                with: .color(color.opacity(twinkle * depth))
            )
        }

        // One shooting star every so often, from a different spot each time.
        let period = 9.0
        let cycle = Int((time / period).rounded(.down))
        let progress = fraction(time / period) * period / 0.9
        guard progress < 1 else { return }
        let origin = CGPoint(x: (0.1 + noise(cycle, 5) * 0.7) * size.width, y: noise(cycle, 6) * 0.35 * size.height)
        let travel = CGVector(dx: size.width * 0.26, dy: size.width * 0.12)
        let head = CGPoint(x: origin.x + travel.dx * progress, y: origin.y + travel.dy * progress)
        let tail = CGPoint(x: head.x - travel.dx * 0.3, y: head.y - travel.dy * 0.3)
        var streak = Path()
        streak.move(to: tail)
        streak.addLine(to: head)
        context.stroke(
            streak,
            with: .linearGradient(
                Gradient(colors: [theme.text.color.opacity(0), theme.text.color.opacity(sin(progress * .pi))]),
                startPoint: tail, endPoint: head
            ),
            style: StrokeStyle(lineWidth: 1.6, lineCap: .round)
        )
    }

    // MARK: Neon grid

    /// A striped sun setting over a floor of lines that rush toward you. The vanishing point follows the pointer.
    private func drawGrid(_ context: GraphicsContext, size: CGSize, time: Double, pointer: PointerField.Sample) {
        let horizon = size.height * 0.58
        let lean = pointer.position.x - 0.5
        let vanish = CGPoint(x: size.width * (0.5 - lean * 0.14), y: horizon)

        let sunRadius = min(size.width, size.height) * 0.2
        let sunCenter = CGPoint(x: size.width * (0.5 - lean * 0.04), y: horizon - sunRadius * 0.3)
        let sunRect = CGRect(x: sunCenter.x - sunRadius, y: sunCenter.y - sunRadius, width: sunRadius * 2, height: sunRadius * 2)
        var sun = context
        sun.opacity = 0.5
        sun.drawLayer { layer in
            layer.clip(to: Path(CGRect(x: 0, y: 0, width: size.width, height: horizon)))
            layer.fill(
                Path(ellipseIn: sunRect),
                with: .linearGradient(
                    Gradient(colors: [Color(red: 1, green: 0.86, blue: 0.45), accent]),
                    startPoint: CGPoint(x: sunCenter.x, y: sunRect.minY), endPoint: CGPoint(x: sunCenter.x, y: horizon)
                )
            )
            // Gaps cut out of the lower half, widening as they sink.
            layer.blendMode = .destinationOut
            for band in 0..<5 {
                let depth = (Double(band) + fraction(time * 0.12)) / 5
                let y = sunCenter.y - sunRadius * 0.1 + depth * sunRadius * 1.1
                layer.fill(Path(CGRect(x: sunRect.minX, y: y, width: sunRect.width, height: 1.5 + depth * 7)), with: .color(.black))
            }
        }

        let floor = size.height - horizon
        let fade = GraphicsContext.Shading.linearGradient(
            Gradient(colors: [accent.opacity(0), accent.opacity(0.45)]),
            startPoint: vanish, endPoint: CGPoint(x: vanish.x, y: size.height)
        )
        let spacing = size.width / 9
        for column in -16...16 {
            var line = Path()
            line.move(to: vanish)
            line.addLine(to: CGPoint(x: size.width / 2 + CGFloat(column) * spacing * 2.4 - lean * size.width * 0.3, y: size.height))
            context.stroke(line, with: fade, lineWidth: 1)
        }
        let rows = 14
        for row in 0..<rows {
            let depth = (Double(row) + fraction(time * 0.6)) / Double(rows)
            let y = horizon + floor * pow(depth, 2.4)
            var line = Path()
            line.move(to: CGPoint(x: 0, y: y))
            line.addLine(to: CGPoint(x: size.width, y: y))
            context.stroke(line, with: .color(accent.opacity(0.08 + 0.4 * depth)), lineWidth: 1)
        }
        // The glow where the floor meets the sky.
        context.fill(
            Path(CGRect(x: 0, y: horizon - 40, width: size.width, height: 80)),
            with: .linearGradient(
                Gradient(colors: [accent.opacity(0), accent.opacity(0.28), accent.opacity(0)]),
                startPoint: CGPoint(x: 0, y: horizon - 40), endPoint: CGPoint(x: 0, y: horizon + 40)
            )
        )
    }

    // MARK: Code rain

    private static let glyphs = Array("ｱｲｳｴｵｶｷｸｹｺｻｼｽｾｿﾀ0123456789")

    /// Falling columns of characters that burn brighter near the pointer.
    private func drawRain(_ context: GraphicsContext, size: CGSize, time: Double, pointer: PointerField.Sample) {
        var context = context
        let cell: CGFloat = 20
        let font = Font.system(size: 14, weight: .medium, design: .monospaced)
        let trail = Self.glyphs.map { context.resolve(Text(String($0)).font(font).foregroundStyle(accent)) }
        let heads = Self.glyphs.map { context.resolve(Text(String($0)).font(font).foregroundStyle(theme.text.color)) }
        let rows = Int(size.height / cell) + 1
        let pointerX = pointer.position.x * size.width

        for column in 0..<Int(size.width / cell) + 1 where noise(column, 4) < 0.65 {
            let x = (CGFloat(column) + 0.5) * cell
            let length = 8 + Int(noise(column, 1) * 14)
            let span = Double(rows + length)
            let head = Int(fraction((time * (4 + noise(column, 0) * 8) + noise(column, 2) * span) / span) * span)
            let boost = pointer.presence * max(0, 1 - abs(x - pointerX) / 180)
            for step in 0..<length {
                let row = head - step
                guard row >= 0, row < rows else { continue }
                // Each cell swaps its character now and then, on its own schedule.
                let glyph = Int(noise(column &* 977 &+ row, Int(time * 0.7 + noise(column &* 977 &+ row, 9) * 50)) * Double(trail.count))
                let strength = 1 - Double(step) / Double(length)
                context.opacity = step == 0 ? 0.55 + 0.4 * boost : strength * (0.24 + 0.5 * boost)
                context.draw(step == 0 ? heads[glyph] : trail[glyph], at: CGPoint(x: x, y: (CGFloat(row) + 0.5) * cell))
            }
        }
    }

    // MARK: Embers and bubbles

    /// A particle rising from the bottom of the window (or falling from the top), swaying as it goes
    /// and steering around the pointer.
    private func rising(
        _ index: Int, size: CGSize, time: Double, pointer: PointerField.Sample, speed: ClosedRange<Double>, sway: Double,
        falling: Bool = false
    ) -> (point: CGPoint, life: Double) {
        let life = fraction(time * (speed.lowerBound + noise(index, 0) * (speed.upperBound - speed.lowerBound)) + noise(index, 1))
        var x = noise(index, 2) * size.width + sin(time * (0.4 + noise(index, 3)) + noise(index, 4) * 2 * .pi) * sway * (0.5 + life)
        var y = size.height * (falling ? life * 1.1 - 0.05 : 1.05 - life * 1.1)
        let dx = x - pointer.position.x * size.width
        let dy = y - pointer.position.y * size.height
        let distance = max(hypot(dx, dy), 1)
        let push = pointer.presence * max(0, 1 - distance / 190) * 70
        x += dx / distance * push
        y += dy / distance * push
        return (CGPoint(x: x, y: y), life)
    }

    private func drawEmbers(_ context: GraphicsContext, size: CGSize, time: Double, pointer: PointerField.Sample) {
        var context = context
        if !theme.isLight { context.blendMode = .plusLighter }
        for index in 0..<70 {
            let (point, life) = rising(index, size: size, time: time, pointer: pointer, speed: 0.03...0.09, sway: 30)
            let radius = 1 + noise(index, 5) * 2.2
            // Flickers, and fades in and out at each end of its climb.
            let flicker = 0.7 + 0.3 * sin(time * (3 + noise(index, 7) * 5) + noise(index, 8) * 2 * .pi)
            let alpha = sin(life * .pi) * (0.35 + 0.65 * noise(index, 6)) * flicker
            let halo = radius * 5
            context.fill(
                Path(ellipseIn: CGRect(x: point.x - halo, y: point.y - halo, width: halo * 2, height: halo * 2)),
                with: .radialGradient(
                    Gradient(colors: [accent.opacity(alpha * 0.4), accent.opacity(0)]),
                    center: point, startRadius: 0, endRadius: halo
                )
            )
            context.fill(
                Path(ellipseIn: CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2)),
                with: .color(accent.opacity(alpha))
            )
        }
    }

    private func drawBubbles(_ context: GraphicsContext, size: CGSize, time: Double, pointer: PointerField.Sample) {
        for index in 0..<36 {
            let (point, life) = rising(index, size: size, time: time, pointer: pointer, speed: 0.02...0.05, sway: 22)
            let radius = 3 + noise(index, 5) * 12
            let alpha = sin(life * .pi) * (0.3 + 0.5 * noise(index, 6))
            let rect = CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2)
            context.fill(Path(ellipseIn: rect), with: .color(accent.opacity(alpha * 0.1)))
            context.stroke(Path(ellipseIn: rect), with: .color(accent.opacity(alpha * 0.7)), lineWidth: 1)
            // The glint on its upper left.
            let glint = radius * 0.22
            context.fill(
                Path(ellipseIn: CGRect(x: point.x - radius * 0.45 - glint, y: point.y - radius * 0.45 - glint, width: glint * 2, height: glint * 2)),
                with: .color(theme.text.color.opacity(alpha * 0.8))
            )
        }
    }

    // MARK: Dark fantasy

    /// A soft-edged patch of colour, stretched sideways into a cloud or a bank of fog.
    private func drawHaze(_ context: GraphicsContext, at center: CGPoint, radius: CGFloat, stretch: CGFloat, color: Color, alpha: Double) {
        var context = context
        context.translateBy(x: center.x, y: center.y)
        context.scaleBy(x: stretch, y: 1)
        context.fill(
            Path(ellipseIn: CGRect(x: -radius, y: -radius, width: radius * 2, height: radius * 2)),
            with: .radialGradient(
                Gradient(colors: [color.opacity(alpha), color.opacity(alpha * 0.5), color.opacity(0)]),
                center: .zero, startRadius: 0, endRadius: radius
            )
        )
    }

    /// A huge moon in the accent colour, with clouds crossing its face. It hangs back as the pointer moves.
    private func drawMoon(_ context: GraphicsContext, size: CGSize, time: Double, pointer: PointerField.Sample) {
        let lean = CGPoint(x: pointer.position.x - 0.5, y: pointer.position.y - 0.5)
        for index in 0..<36 {
            let x = noise(index, 1) * size.width - lean.x * 12
            let y = noise(index, 2) * size.height * 0.7 - lean.y * 12
            let twinkle = 0.4 + 0.3 * sin(time * (0.5 + noise(index, 3)) + noise(index, 4) * 2 * .pi)
            context.fill(Path(ellipseIn: CGRect(x: x, y: y, width: 1.6, height: 1.6)), with: .color(theme.text.color.opacity(twinkle * 0.6)))
        }

        let radius = min(size.width, size.height) * 0.19
        let center = CGPoint(x: size.width * 0.7 - lean.x * 34, y: size.height * 0.3 - lean.y * 34)
        var glow = context
        glow.blendMode = .plusLighter
        let halo = radius * (3.2 + 0.15 * sin(time * 0.5))
        glow.fill(
            Path(ellipseIn: CGRect(x: center.x - halo, y: center.y - halo, width: halo * 2, height: halo * 2)),
            with: .radialGradient(
                Gradient(colors: [accent.opacity(0.38), accent.opacity(0.1), accent.opacity(0)]),
                center: center, startRadius: radius * 0.8, endRadius: halo
            )
        )
        let disc = Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
        context.fill(
            disc,
            with: .radialGradient(
                Gradient(colors: [theme.text.color.opacity(0.4), accent.opacity(0.95), accent.opacity(0.75)]),
                center: CGPoint(x: center.x - radius * 0.3, y: center.y - radius * 0.3), startRadius: 0, endRadius: radius * 1.5
            )
        )
        // Seas on the surface.
        var surface = context
        surface.clip(to: disc)
        for index in 0..<7 {
            let position = CGPoint(x: center.x + (noise(index, 21) - 0.5) * radius * 1.5, y: center.y + (noise(index, 22) - 0.5) * radius * 1.5)
            drawHaze(surface, at: position, radius: radius * (0.14 + noise(index, 20) * 0.2), stretch: 1 + noise(index, 23) * 0.8,
                     color: .black, alpha: 0.26)
        }

        // Clouds in the sky's own colour, so they read as silhouettes against the moon.
        for index in 0..<7 {
            let x = fraction(noise(index, 30) + time * (0.004 + noise(index, 31) * 0.006)) * (size.width + 800) - 400 - lean.x * 60
            let y = size.height * (0.12 + noise(index, 32) * 0.4) - lean.y * 30
            drawHaze(context, at: CGPoint(x: x, y: y), radius: 34 + noise(index, 33) * 40, stretch: 5 + noise(index, 34) * 3,
                     color: theme.backgroundEnd.color, alpha: 0.8)
        }
    }

    /// Banks of fog sliding past at different speeds. It thins out around the pointer.
    private func drawFog(_ context: GraphicsContext, size: CGSize, time: Double, pointer: PointerField.Sample) {
        let pointerAt = CGPoint(x: pointer.position.x * size.width, y: pointer.position.y * size.height)
        for index in 0..<14 {
            let direction: Double = index % 3 == 0 ? -1 : 1
            let x = fraction(noise(index, 1) + direction * time * (0.005 + noise(index, 2) * 0.012)) * (size.width + 1200) - 600
            let y = size.height * (0.25 + noise(index, 3) * 0.8) + sin(time * 0.2 + noise(index, 4) * 2 * .pi) * 14
            let parted = 1 - pointer.presence * max(0, 1 - hypot(x - pointerAt.x, (y - pointerAt.y) * 2) / 420) * 0.85
            let breathing = 0.75 + 0.25 * sin(time * 0.3 + noise(index, 5) * 2 * .pi)
            drawHaze(context, at: CGPoint(x: x, y: y), radius: 70 + noise(index, 6) * 80, stretch: 4 + noise(index, 7) * 3,
                     color: theme.text.color, alpha: (0.16 + noise(index, 8) * 0.14) * parted * breathing)
        }
    }

    /// Grey ash drifting down, with the odd flake still burning.
    private func drawAsh(_ context: GraphicsContext, size: CGSize, time: Double, pointer: PointerField.Sample) {
        for index in 0..<110 {
            let (point, life) = rising(index, size: size, time: time, pointer: pointer, speed: 0.015...0.05, sway: 40, falling: true)
            let radius = 1.4 + noise(index, 5) * 2.6
            let alpha = sin(life * .pi) * (0.45 + 0.55 * noise(index, 6))
            // Flakes are flat, so they narrow and widen as they tumble.
            let tumble = 0.35 + 0.65 * abs(sin(time * (0.8 + noise(index, 7) * 2) + noise(index, 8) * 2 * .pi))
            let flake = Path(ellipseIn: CGRect(x: point.x - radius, y: point.y - radius * tumble, width: radius * 2, height: radius * 2 * tumble))
            if index % 9 == 0 {
                var glow = context
                if !theme.isLight { glow.blendMode = .plusLighter }
                let halo = radius * 6
                glow.fill(
                    Path(ellipseIn: CGRect(x: point.x - halo, y: point.y - halo, width: halo * 2, height: halo * 2)),
                    with: .radialGradient(Gradient(colors: [accent.opacity(alpha * 0.5), accent.opacity(0)]), center: point, startRadius: 0, endRadius: halo)
                )
                glow.fill(flake, with: .color(accent.opacity(alpha)))
            } else {
                context.fill(flake, with: .color(theme.text.color.opacity(alpha * 0.85)))
            }
        }
    }

    /// Lights that wander on their own paths and drift toward the pointer, each trailing a tail.
    private func drawWisps(_ context: GraphicsContext, size: CGSize, time: Double, pointer: PointerField.Sample) {
        var context = context
        if !theme.isLight { context.blendMode = .plusLighter }
        func position(_ index: Int, at time: Double) -> CGPoint {
            let x = 0.5 + 0.46 * sin(time * (0.07 + noise(index, 1) * 0.09) + noise(index, 2) * 2 * .pi)
                + 0.05 * sin(time * (0.5 + noise(index, 3) * 0.4) + noise(index, 4) * 2 * .pi)
            let y = 0.5 + 0.42 * sin(time * (0.06 + noise(index, 5) * 0.08) + noise(index, 6) * 2 * .pi)
                + 0.05 * cos(time * (0.45 + noise(index, 7) * 0.4) + noise(index, 8) * 2 * .pi)
            // Each is drawn in by a different amount, so they gather loosely rather than stacking up.
            let pull = pointer.presence * (0.15 + noise(index, 9) * 0.4)
            return CGPoint(
                x: (x + (pointer.position.x - x) * pull) * size.width,
                y: (y + (pointer.position.y - y) * pull) * size.height
            )
        }
        for index in 0..<9 {
            let pulse = 0.7 + 0.3 * sin(time * (0.9 + noise(index, 10)) + noise(index, 11) * 2 * .pi)
            for step in (1...8).reversed() {
                let point = position(index, at: time - Double(step) * 0.07)
                let radius = 4.5 * (1 - Double(step) / 9)
                context.fill(
                    Path(ellipseIn: CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2)),
                    with: .color(accent.opacity(0.45 * (1 - Double(step) / 9) * pulse))
                )
            }
            let point = position(index, at: time)
            let halo = (80 + noise(index, 12) * 90) * pulse
            context.fill(
                Path(ellipseIn: CGRect(x: point.x - halo, y: point.y - halo, width: halo * 2, height: halo * 2)),
                with: .radialGradient(
                    Gradient(colors: [accent.opacity(0.55 * pulse), accent.opacity(0.14 * pulse), accent.opacity(0)]),
                    center: point, startRadius: 0, endRadius: halo
                )
            )
            context.fill(
                Path(ellipseIn: CGRect(x: point.x - 5, y: point.y - 5, width: 10, height: 10)),
                with: .color(theme.text.color.opacity(0.85 * pulse))
            )
        }
    }
}

/// Tilts a cover under the pointer like a card pressed with a fingertip, with a sheen that follows it.
struct PointerTilt: ViewModifier {
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let size: CGSize
    var maxAngle: Double = 8
    /// Lets you grab the cover and turn it. It swings back when you let go.
    var draggable = false
    /// The pointer's position over the cover, -1...1 on each axis.
    @State private var lean: CGPoint?
    @GestureState private var pull: CGSize = .zero

    private var isEnabled: Bool { theme.tilt && theme.animations && !reduceMotion }

    func body(content: Content) -> some View {
        let yaw = min(max((lean?.x ?? 0) * maxAngle + pull.width * 0.45, -60), 60)
        let pitch = min(max(-(lean?.y ?? 0) * maxAngle - pull.height * 0.3, -35), 35)
        content
            .overlay {
                if let lean {
                    RadialGradient(
                        colors: [.white.opacity(0.3), .white.opacity(0)],
                        center: UnitPoint(x: (lean.x + 1) / 2, y: (lean.y + 1) / 2),
                        startRadius: 0,
                        endRadius: max(size.width, size.height) * 0.75
                    )
                    .blendMode(.plusLighter)
                    .clipShape(RoundedRectangle(cornerRadius: theme.cornerRadius))
                    .allowsHitTesting(false)
                    .transition(.opacity)
                }
            }
            .rotation3DEffect(.degrees(yaw), axis: (x: 0, y: 1, z: 0), perspective: 0.6)
            .rotation3DEffect(.degrees(pitch), axis: (x: 1, y: 0, z: 0), perspective: 0.6)
            .animation(.interactiveSpring(response: 0.35, dampingFraction: 0.6), value: lean)
            .animation(.spring(response: 0.5, dampingFraction: 0.45), value: pull)
            // Outside the rotation, so the tilt doesn't move the area being tracked.
            .onContinuousHover { phase in
                guard isEnabled, case .active(let location) = phase, size.width > 0, size.height > 0 else {
                    lean = nil
                    return
                }
                lean = CGPoint(
                    x: min(max(location.x / size.width * 2 - 1, -1), 1),
                    y: min(max(location.y / size.height * 2 - 1, -1), 1)
                )
            }
            .gesture(
                DragGesture(minimumDistance: 2).updating($pull) { value, pull, _ in pull = value.translation },
                isEnabled: draggable && isEnabled
            )
    }
}
