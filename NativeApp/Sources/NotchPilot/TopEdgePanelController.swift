import AppKit
import Combine
import CoreGraphics
import SwiftUI

@MainActor
final class TopEdgePanelController: NSObject {
    private enum Lifecycle {
        case hidden
        case revealing
        case shown
        case collapsing
    }

    private struct DisplayGeometry {
        let screen: NSScreen
        let hasNotch: Bool
        let notchWidth: CGFloat
        let notchDepth: CGFloat
        let menuBarHeight: CGFloat
        let panelFrame: CGRect
        let attachmentCenterX: CGFloat
        let collapseAnchorY: CGFloat

        var screenID: CGDirectDisplayID { screen.displayID }
    }

    let terminalPanel: NSPanel
    var externalMarkerCount: Int { externalMarkers.count }

    private let model: AppModel
    private let transitionView: NotchPanelTransitionView
    private let animator = NotchPanelRevealAnimator()
    private var lifecycle: Lifecycle = .hidden
    private var transitionGeneration = 0
    private var targetScreen: NSScreen?
    private var installedPanelSize: CGSize?
    private var currentGeometry: DisplayGeometry?
    private var externalMarkers: [CGDirectDisplayID: NSPanel] = [:]
    private var localScrollMonitor: Any?
    private var globalScrollMonitor: Any?
    private var shortcutMonitor: GlobalShortcutMonitor?
    private var cancellables = Set<AnyCancellable>()

    private var pullAccumulator = NotchPullGestureAccumulator(activationDistance: 46)
    private var pullScreenID: CGDirectDisplayID?
    private var lastPreciseScrollDate: Date?

    init(model: AppModel) {
        self.model = model
        let hostingView = TransparentHostingView(rootView: PanelRootView(model: model))
        transitionView = NotchPanelTransitionView(hostedView: hostingView)
        terminalPanel = TerminalPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        super.init()

        configureTerminalPanel()
        terminalPanel.contentView = transitionView
        targetScreen = preferredStartupScreen()
        installModelBindings()
        installInputMonitors()
        installScreenObservation()
        reconcileMarkers()
    }

    deinit {
        if let localScrollMonitor { NSEvent.removeMonitor(localScrollMonitor) }
        if let globalScrollMonitor { NSEvent.removeMonitor(globalScrollMonitor) }
        let panel = terminalPanel
        let markers = Array(externalMarkers.values)
        Task { @MainActor in
            panel.orderOut(nil)
            panel.close()
            for marker in markers {
                marker.orderOut(nil)
                marker.close()
            }
        }
    }

    func moveToBuiltInDisplay() {
        targetScreen = builtInScreen() ?? NSScreen.main ?? targetScreen
        guard let targetScreen else { return }
        if lifecycle == .hidden {
            model.showPanel()
        } else {
            beginReveal(on: targetScreen)
        }
    }

    private func configureTerminalPanel() {
        terminalPanel.isOpaque = false
        terminalPanel.backgroundColor = .clear
        terminalPanel.hasShadow = false
        terminalPanel.isMovable = false
        terminalPanel.isMovableByWindowBackground = false
        terminalPanel.hidesOnDeactivate = false
        terminalPanel.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
        terminalPanel.collectionBehavior = [.canJoinAllSpaces, .canJoinAllApplications, .fullScreenAuxiliary]
        terminalPanel.isReleasedWhenClosed = false
    }

    private func installModelBindings() {
        model.onPanelShowRequest = { [weak self] in
            self?.requestShowFromModel()
        }
        model.onPanelDismissRequest = { [weak self] in
            self?.requestDismissal()
        }

        model.$shortcutEnabled
            .combineLatest(model.$shortcutChoice)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] enabled, choice in
                self?.configureShortcut(enabled: enabled, choice: choice)
            }
            .store(in: &cancellables)

        model.$presentationState
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.reconcileVisibility() }
            .store(in: &cancellables)
        model.$isManuallyHidden
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.reconcileVisibility() }
            .store(in: &cancellables)
    }

    private func installInputMonitors() {
        localScrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self else { return event }
            return self.handleScroll(event, isLocal: true) ? nil : event
        }
        globalScrollMonitor = NSEvent.addGlobalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            _ = self?.handleScroll(event, isLocal: false)
        }
    }

    private func installScreenObservation() {
        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.screenParametersDidChange() }
            .store(in: &cancellables)
    }

    private func configureShortcut(enabled: Bool, choice: String) {
        shortcutMonitor = nil
        guard enabled else { return }
        shortcutMonitor = GlobalShortcutMonitor(choice: choice) { [weak self] in
            guard let self else { return }
            self.targetScreen = self.screen(containing: NSEvent.mouseLocation) ?? self.targetScreen
            if self.lifecycle == .collapsing {
                self.model.showPanel()
            } else {
                self.model.toggleVisibilityFromShortcut()
            }
        }
    }

    private func requestShowFromModel() {
        guard lifecycle == .hidden || lifecycle == .collapsing else { return }
        targetScreen = targetScreen ?? preferredStartupScreen()
        guard let screen = targetScreen ?? NSScreen.main else { return }
        beginReveal(on: screen)
    }

    private func reconcileVisibility() {
        guard !model.isManuallyHidden, model.presentationState.isVisible else { return }
        guard lifecycle == .hidden else { return }
        requestShowFromModel()
    }

    private func requestDismissal() {
        guard lifecycle != .hidden, lifecycle != .collapsing else { return }
        transitionGeneration &+= 1
        let token = transitionGeneration
        lifecycle = .collapsing
        let geometry = currentGeometry ?? geometry(for: targetScreen ?? preferredStartupScreen())
        applyDisplayModel(geometry)
        animator.collapse(in: transitionView, context: revealContext(for: geometry)) { [weak self] in
            guard let self,
                  self.transitionGeneration == token,
                  self.lifecycle == .collapsing else { return }
            self.terminalPanel.orderOut(nil)
            self.lifecycle = .hidden
            self.pullAccumulator.end()
            self.pullScreenID = nil
            self.lastPreciseScrollDate = nil
            self.model.completePanelDismissal()
        }
    }

    private func beginReveal(on screen: NSScreen) {
        let reversingCollapse = lifecycle == .collapsing
        let geometry = geometry(for: screen)
        targetScreen = screen
        if !reversingCollapse,
           (lifecycle == .revealing || lifecycle == .shown),
           let currentGeometry,
           currentGeometry.screenID == geometry.screenID,
           currentGeometry.panelFrame == geometry.panelFrame {
            applyDisplayModel(geometry)
            model.theme.update(for: screen)
            return
        }
        transitionGeneration &+= 1
        let token = transitionGeneration
        applyDisplayModel(geometry)
        model.theme.update(for: screen)
        installPanelFrame(geometry.panelFrame)
        currentGeometry = geometry

        lifecycle = .revealing
        if !reversingCollapse {
            animator.prepareReveal(in: transitionView)
        }
        animator.reveal(in: transitionView, context: revealContext(for: geometry)) { [weak self] in
            guard let self,
                  self.transitionGeneration == token,
                  self.lifecycle == .revealing else { return }
            self.lifecycle = .shown
        }
        terminalPanel.orderFrontRegardless()
        terminalPanel.makeKey()
        scheduleTerminalActivation(generation: token)
    }

    private func scheduleTerminalActivation(generation: Int) {
        DispatchQueue.main.async { [weak self] in
            guard let self,
                  self.transitionGeneration == generation,
                  (self.lifecycle == .revealing || self.lifecycle == .shown),
                  self.terminalPanel.isVisible else { return }
            self.model.terminal.focus()
            self.model.terminal.ensureStarted()
            self.model.terminal.startAfterLayoutIfNeeded()
        }
    }

    private func installPanelFrame(_ frame: CGRect) {
        let sizeChanged = installedPanelSize.map { $0 != frame.size } ?? true
        terminalPanel.setFrame(frame, display: false)
        guard sizeChanged else { return }
        installedPanelSize = frame.size
        transitionView.layoutSubtreeIfNeeded()
    }

    private func screenParametersDidChange() {
        reconcileMarkers()
        guard lifecycle != .hidden else {
            let replacement = resolvedScreen(targetScreen) ?? preferredStartupScreen()
            targetScreen = replacement
            if let replacement {
                applyDisplayModel(geometry(for: replacement))
                model.theme.update(for: replacement)
            }
            return
        }

        transitionGeneration &+= 1
        animator.cancel()
        if lifecycle == .collapsing {
            terminalPanel.orderOut(nil)
            lifecycle = .hidden
            model.completePanelDismissal()
            return
        }
        lifecycle = .hidden
        let replacement = resolvedScreen(targetScreen) ?? preferredStartupScreen()
        if let replacement { beginReveal(on: replacement) }
    }

    private func resolvedScreen(_ candidate: NSScreen?) -> NSScreen? {
        guard let candidate else { return nil }
        return NSScreen.screens.first(where: { $0.displayID == candidate.displayID })
    }

    private func handleScroll(_ event: NSEvent, isLocal: Bool) -> Bool {
        let point = NSEvent.mouseLocation
        guard let screen = screen(containing: point) else {
            resetPullGesture()
            return false
        }
        let geometry = geometry(for: screen)
        guard activationZone(for: geometry).contains(point) else {
            resetPullGesture()
            return false
        }

        if event.hasPreciseScrollingDeltas {
            handlePreciseScroll(event, geometry: geometry)
            return isLocal
        }
        guard !geometry.hasNotch,
              let action = NotchWheelGesture.action(
                deltaX: event.scrollingDeltaX,
                deltaY: physicalDeltaY(for: event)
              ) else { return false }
        perform(action: action, target: screen)
        return isLocal
    }

    private func handlePreciseScroll(_ event: NSEvent, geometry: DisplayGeometry) {
        guard event.momentumPhase.isEmpty else { return }
        let now = event.timestamp > 0
            ? Date(timeIntervalSinceReferenceDate: event.timestamp)
            : Date()
        if event.phase.contains(.began)
            || pullScreenID != geometry.screenID
            || lastPreciseScrollDate.map({ now.timeIntervalSince($0) > 0.4 }) == true {
            pullAccumulator.begin()
        }
        pullScreenID = geometry.screenID
        lastPreciseScrollDate = now
        if let action = pullAccumulator.ingest(
            deltaX: event.scrollingDeltaX,
            deltaY: physicalDeltaY(for: event)
        ) {
            perform(action: action, target: geometry.screen)
        }
        if event.phase.contains(.ended) || event.phase.contains(.cancelled) {
            resetPullGesture()
        }
    }

    private func physicalDeltaY(for event: NSEvent) -> Double {
        event.isDirectionInvertedFromDevice ? -event.scrollingDeltaY : event.scrollingDeltaY
    }

    private func perform(action: NotchPullGestureAction, target screen: NSScreen) {
        targetScreen = screen
        switch action {
        case .expand:
            guard lifecycle == .hidden || lifecycle == .collapsing else { return }
            performGestureHapticIfEnabled()
            model.showPanel()
        case .dismiss:
            guard lifecycle == .revealing || lifecycle == .shown else { return }
            performGestureHapticIfEnabled()
            model.hidePanel()
        }
    }

    private func performGestureHapticIfEnabled() {
        guard model.hapticsEnabled else { return }
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
    }

    private func resetPullGesture() {
        pullAccumulator.end()
        pullScreenID = nil
        lastPreciseScrollDate = nil
    }

    private func geometry(for screen: NSScreen?) -> DisplayGeometry {
        let screen = screen ?? preferredStartupScreen() ?? NSScreen.main ?? NSScreen.screens[0]
        let notch = notchMetrics(for: screen)
        let usable = screen.visibleFrame
        let width = min(900, max(1, usable.width * 0.92))
        let height = min(640, max(1, usable.height * 0.92))
        let top = screen.frame.maxY + (notch.hasNotch ? 0 : 14)
        let frame = CGRect(
            x: screen.frame.midX - width / 2,
            y: top - height,
            width: width,
            height: height
        )
        let attachmentX = notch.hasNotch ? frame.width / 2 : frame.width / 2
        return DisplayGeometry(
            screen: screen,
            hasNotch: notch.hasNotch,
            notchWidth: notch.width,
            notchDepth: notch.depth,
            menuBarHeight: screen.frame.maxY - screen.visibleFrame.maxY,
            panelFrame: frame,
            attachmentCenterX: attachmentX,
            collapseAnchorY: notch.hasNotch ? height : height - 14
        )
    }

    private func revealContext(for geometry: DisplayGeometry) -> NotchRevealContext {
        NotchRevealContext(
            attachmentCenterX: geometry.attachmentCenterX,
            collapseAnchorY: geometry.collapseAnchorY,
            isNotchedDisplay: geometry.hasNotch,
            reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
            collapseScaleX: geometry.hasNotch
                ? min(1, max(0.08, geometry.notchWidth / geometry.panelFrame.width))
                : 72 / geometry.panelFrame.width,
            collapseScaleY: geometry.hasNotch
                ? min(1, max(0.04, geometry.notchDepth / geometry.panelFrame.height))
                : 13 / geometry.panelFrame.height
        )
    }

    private func applyDisplayModel(_ geometry: DisplayGeometry) {
        model.activeDisplayHasNotch = geometry.hasNotch
        model.activeNotchWidth = geometry.notchWidth
        model.activeNotchDepth = geometry.notchDepth
        model.activeMenuBarHeight = geometry.menuBarHeight
    }

    private func activationZone(for geometry: DisplayGeometry) -> CGRect {
        let width: CGFloat = geometry.hasNotch
            ? min(260, max(1, geometry.notchWidth + 64))
            : 220
        return CGRect(
            x: geometry.screen.frame.midX - width / 2,
            y: geometry.screen.frame.maxY - 48,
            width: width,
            height: 48
        )
    }

    private func preferredStartupScreen() -> NSScreen? {
        builtInScreen() ?? NSScreen.main ?? NSScreen.screens.first
    }

    private func builtInScreen() -> NSScreen? {
        NSScreen.screens.first(where: { CGDisplayIsBuiltin($0.displayID) != 0 })
    }

    private func screen(containing point: CGPoint) -> NSScreen? {
        NSScreen.screens.first(where: { $0.frame.contains(point) })
    }

    private func notchMetrics(for screen: NSScreen) -> (hasNotch: Bool, width: CGFloat, depth: CGFloat) {
        let left = screen.auxiliaryTopLeftArea ?? .zero
        let right = screen.auxiliaryTopRightArea ?? .zero
        let auxiliaryGap = right.minX - left.maxX
        let safeTop = screen.safeAreaInsets.top
        let hasAuxiliaryGap = auxiliaryGap > 1 && left.width > 0 && right.width > 0
        let hasSafeAreaNotch = CGDisplayIsBuiltin(screen.displayID) != 0 && safeTop > 1
        let hasNotch = hasAuxiliaryGap || hasSafeAreaNotch
        let width = hasAuxiliaryGap ? auxiliaryGap : (hasNotch ? 180 : 72)
        let depth = hasNotch ? max(safeTop, screen.frame.maxY - screen.visibleFrame.maxY, 24) : 13
        return (hasNotch, width, depth)
    }

    private func reconcileMarkers() {
        let required = Dictionary(uniqueKeysWithValues: NSScreen.screens.compactMap { screen -> (CGDirectDisplayID, NSScreen)? in
            guard CGDisplayIsBuiltin(screen.displayID) == 0,
                  !notchMetrics(for: screen).hasNotch else { return nil }
            return (screen.displayID, screen)
        })

        let obsoleteMarkerIDs = externalMarkers.keys.filter { required[$0] == nil }
        for identifier in obsoleteMarkerIDs {
            guard let marker = externalMarkers.removeValue(forKey: identifier) else { continue }
            marker.orderOut(nil)
            marker.close()
        }
        for (identifier, screen) in required {
            let marker = externalMarkers[identifier] ?? makeExternalMarker()
            externalMarkers[identifier] = marker
            marker.setFrame(markerFrame(for: screen), display: false)
            marker.orderFrontRegardless()
        }
    }

    private func makeExternalMarker() -> NSPanel {
        let marker = DecorativeMarkerPanel(
            contentRect: CGRect(x: 0, y: 0, width: 72, height: 13),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        marker.isOpaque = false
        marker.backgroundColor = .clear
        marker.hasShadow = false
        marker.ignoresMouseEvents = true
        marker.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 2)
        marker.collectionBehavior = [.canJoinAllSpaces, .canJoinAllApplications, .fullScreenAuxiliary]
        marker.isReleasedWhenClosed = false
        marker.contentView = ExternalMarkerView(frame: CGRect(x: 0, y: 0, width: 72, height: 13))
        return marker
    }

    private func markerFrame(for screen: NSScreen) -> CGRect {
        CGRect(x: screen.frame.midX - 36, y: screen.frame.maxY - 13, width: 72, height: 13)
    }
}

private final class TerminalPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

private final class DecorativeMarkerPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private final class TransparentHostingView<Content: View>: NSHostingView<Content> {
    override var isOpaque: Bool { false }

    required init(rootView: Content) {
        super.init(rootView: rootView)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

private final class ExternalMarkerView: NSView {
    override var isOpaque: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.setFill()
        let radius: CGFloat = 7
        let path = NSBezierPath()
        path.move(to: CGPoint(x: bounds.minX, y: bounds.maxY))
        path.line(to: CGPoint(x: bounds.maxX, y: bounds.maxY))
        path.line(to: CGPoint(x: bounds.maxX, y: bounds.minY + radius))
        path.curve(
            to: CGPoint(x: bounds.maxX - radius, y: bounds.minY),
            controlPoint1: CGPoint(x: bounds.maxX, y: bounds.minY + radius * 0.45),
            controlPoint2: CGPoint(x: bounds.maxX - radius * 0.45, y: bounds.minY)
        )
        path.line(to: CGPoint(x: bounds.minX + radius, y: bounds.minY))
        path.curve(
            to: CGPoint(x: bounds.minX, y: bounds.minY + radius),
            controlPoint1: CGPoint(x: bounds.minX + radius * 0.45, y: bounds.minY),
            controlPoint2: CGPoint(x: bounds.minX, y: bounds.minY + radius * 0.45)
        )
        path.close()
        path.fill()
    }
}

private extension NSScreen {
    var displayID: CGDirectDisplayID {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)
            .map { CGDirectDisplayID($0.uint32Value) } ?? 0
    }
}
