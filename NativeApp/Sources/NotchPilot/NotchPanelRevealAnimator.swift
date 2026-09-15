import AppKit
import QuartzCore

struct NotchRevealContext {
    let attachmentCenterX: CGFloat
    let collapseAnchorY: CGFloat
    let isNotchedDisplay: Bool
    let reduceMotion: Bool
    let collapseScaleX: CGFloat
    let collapseScaleY: CGFloat
}

final class NotchPanelTransitionView: NSView {
    let hostedView: NSView

    init(hostedView: NSView) {
        self.hostedView = hostedView
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        hostedView.frame = bounds
        hostedView.autoresizingMask = [.width, .height]
        addSubview(hostedView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var isOpaque: Bool { false }
}

@MainActor
final class NotchPanelRevealAnimator {
    private weak var activeView: NotchPanelTransitionView?
    private var generation = 0
    private var prepared = false
    private static let animationKey = "notchpilot.reveal"

    func prepareReveal(in view: NotchPanelTransitionView) {
        cancel()
        activeView = view
        prepared = true
        withoutActions { view.layer?.opacity = 0 }
    }

    func reveal(in view: NotchPanelTransitionView, context: NotchRevealContext, completion: (() -> Void)? = nil) {
        animate(in: view, context: context, opening: true, completion: completion)
    }

    func collapse(in view: NotchPanelTransitionView, context: NotchRevealContext, completion: (() -> Void)? = nil) {
        animate(in: view, context: context, opening: false, completion: completion)
    }

    func cancel() {
        generation += 1
        if let layer = activeView?.layer {
            withoutActions {
                layer.removeAnimation(forKey: Self.animationKey)
                layer.mask = nil
                layer.opacity = 1
            }
        }
        activeView = nil
        prepared = false
    }

    private func animate(in view: NotchPanelTransitionView, context: NotchRevealContext, opening: Bool, completion: (() -> Void)?) {
        generation += 1
        let token = generation
        activeView = view
        guard let layer = view.layer else { completion?(); return }
        let full = layer.bounds
        let small = CGRect(x: context.attachmentCenterX - full.width * context.collapseScaleX / 2,
                           y: context.collapseAnchorY - full.height * context.collapseScaleY,
                           width: full.width * context.collapseScaleX,
                           height: full.height * context.collapseScaleY)
        func path(_ rect: CGRect) -> CGPath {
            let radius = min(20, rect.width / 2, rect.height / 2)
            return CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
        }
        let oldMask = layer.mask as? CAShapeLayer
        let startPath = (oldMask?.presentation() as? CAShapeLayer)?.path ?? oldMask?.path
            ?? path(opening ? small : full)
        let startOpacity = prepared ? Float(0) : (layer.presentation()?.opacity ?? layer.opacity)
        prepared = false
        let duration: CFTimeInterval = context.reduceMotion ? 0.12 : (opening ? 0.28 : 0.20)
        withoutActions {
            layer.removeAnimation(forKey: Self.animationKey)
            layer.opacity = opening || !context.reduceMotion ? 1 : 0
            if context.reduceMotion {
                layer.mask = nil
                let fade = CABasicAnimation(keyPath: "opacity")
                fade.fromValue = startOpacity
                fade.toValue = opening ? 1 : 0
                fade.duration = duration
                layer.add(fade, forKey: Self.animationKey)
            } else {
                let mask = CAShapeLayer()
                mask.frame = full
                mask.fillColor = NSColor.black.cgColor
                mask.path = path(opening ? full : small)
                layer.mask = mask
                let motion = CABasicAnimation(keyPath: "path")
                motion.fromValue = startPath
                motion.toValue = mask.path
                motion.duration = duration
                motion.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.8, 0.2, 1)
                mask.add(motion, forKey: Self.animationKey)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [weak self, weak view] in
            guard let self, let view, self.generation == token else { return }
            completion?()
            guard self.generation == token else { return }
            self.withoutActions {
                view.layer?.mask = nil
                view.layer?.opacity = 1
                view.layer?.removeAnimation(forKey: Self.animationKey)
            }
            self.activeView = nil
            self.prepared = false
        }
    }

    private func withoutActions(_ body: () -> Void) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        body()
        CATransaction.commit()
    }
}
