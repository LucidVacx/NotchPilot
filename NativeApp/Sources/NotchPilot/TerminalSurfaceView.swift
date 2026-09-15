import AppKit
import SwiftUI

struct TerminalSurfaceView: NSViewRepresentable {
    @ObservedObject var session: HermesTerminalSession

    func makeNSView(context: Context) -> NSView {
        let container = TerminalContainer(session: session)
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.clear.cgColor
        container.appearance = NSAppearance(named: .darkAqua)

        let terminal = session.terminalView
        terminal.removeFromSuperview()
        terminal.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(terminal)
        NSLayoutConstraint.activate([
            terminal.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            terminal.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            terminal.topAnchor.constraint(equalTo: container.topAnchor),
            terminal.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])

        session.ensureStarted()
        DispatchQueue.main.async {
            session.startAfterLayoutIfNeeded()
        }
        return container
    }

    func updateNSView(_ nsView: NSView, context: Context) {
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: ()) {
    }
}

@MainActor
private final class TerminalContainer: NSView {
    private weak var session: HermesTerminalSession?
    private var launchCheckScheduled = false

    init(session: HermesTerminalSession) {
        self.session = session
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        guard bounds.width > 1, bounds.height > 1, !launchCheckScheduled else { return }
        launchCheckScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.launchCheckScheduled = false
            self.session?.startAfterLayoutIfNeeded()
        }
    }
}
