enum NotchPresentationState: Equatable, Sendable {
    case hidden
    case open

    var isVisible: Bool { self == .open }
}
