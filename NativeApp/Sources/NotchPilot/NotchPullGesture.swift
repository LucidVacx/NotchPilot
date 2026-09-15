import Foundation

enum NotchPullGestureAction: Equatable, Sendable {
    case expand
    case dismiss
}

enum NotchWheelGesture {
    static func action(deltaX: Double, deltaY: Double) -> NotchPullGestureAction? {
        guard deltaX.isFinite, deltaY.isFinite, deltaY != 0,
              abs(deltaY) >= abs(deltaX) * 1.2 else { return nil }
        return deltaY < 0 ? .expand : .dismiss
    }
}

struct NotchPullGestureAccumulator: Sendable {
    let activationDistance: Double
    let verticalDominanceRatio: Double

    private var verticalTravel = 0.0
    private var horizontalTravel = 0.0
    private var didRecognize = false

    init(
        activationDistance: Double = 46,
        verticalDominanceRatio: Double = 1.2
    ) {
        self.activationDistance = activationDistance
        self.verticalDominanceRatio = verticalDominanceRatio
    }

    mutating func begin() {
        verticalTravel = 0
        horizontalTravel = 0
        didRecognize = false
    }

    mutating func ingest(deltaX: Double, deltaY: Double) -> NotchPullGestureAction? {
        guard !didRecognize else { return nil }

        verticalTravel += deltaY
        horizontalTravel += abs(deltaX)
        guard abs(verticalTravel) >= activationDistance,
              abs(verticalTravel) >= horizontalTravel * verticalDominanceRatio else {
            return nil
        }

        didRecognize = true
        return verticalTravel < 0 ? .expand : .dismiss
    }

    mutating func end() {
        begin()
    }
}
