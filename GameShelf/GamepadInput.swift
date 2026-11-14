import GameController
import Observation

/// Turns any connected controller into library navigation: d-pad or left stick to move,
/// A for details, X or Start to play, Y to favourite, B to go back and the shoulders to switch collections.
@MainActor
@Observable
final class GamepadInput {
    enum Action {
        case move(dx: Int, dy: Int)
        case switchCollection(Int)
        case confirm, play, favorite, back
    }

    @ObservationIgnored var handler: (Action) -> Void = { _ in }
    @ObservationIgnored private var repeatTask: Task<Void, Never>?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    init() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: .GCControllerDidConnect, object: nil, queue: .main) { [weak self] note in
            guard let controller = note.object as? GCController else { return }
            MainActor.assumeIsolated { self?.attach(controller) }
        })
        GCController.controllers().forEach(attach)
        GCController.startWirelessControllerDiscovery()
    }

    private func attach(_ controller: GCController) {
        guard let pad = controller.extendedGamepad else { return }
        bindDirection(pad.dpad)
        bindDirection(pad.leftThumbstick)
        bind(pad.buttonA) { .confirm }
        bind(pad.buttonB) { .back }
        bind(pad.buttonX) { .play }
        bind(pad.buttonMenu) { .play }
        bind(pad.buttonY) { .favorite }
        bind(pad.leftShoulder) { .switchCollection(-1) }
        bind(pad.rightShoulder) { .switchCollection(1) }
    }

    private func bind(_ button: GCControllerButtonInput, action: @escaping @MainActor () -> Action) {
        button.pressedChangedHandler = { [weak self] _, _, pressed in
            guard pressed else { return }
            MainActor.assumeIsolated { self?.handler(action()) }
        }
    }

    /// Directions repeat while held, like a menu on a console.
    private func bindDirection(_ pad: GCControllerDirectionPad) {
        let directions: [(GCControllerButtonInput, Int, Int)] = [
            (pad.left, -1, 0), (pad.right, 1, 0), (pad.up, 0, -1), (pad.down, 0, 1),
        ]
        for (button, dx, dy) in directions {
            button.pressedChangedHandler = { [weak self] _, _, pressed in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.repeatTask?.cancel()
                    guard pressed else { return }
                    self.handler(.move(dx: dx, dy: dy))
                    self.repeatTask = Task { [weak self] in
                        try? await Task.sleep(for: .milliseconds(380))
                        while !Task.isCancelled {
                            self?.handler(.move(dx: dx, dy: dy))
                            try? await Task.sleep(for: .milliseconds(110))
                        }
                    }
                }
            }
        }
    }
}
