import AppKit
import SwiftUI

/// The pet's window and everything it does (Idea2do's PetController, without edge docking): click for the input bubble,
/// hover for the card, drag to move (the place is remembered), right-click for the menu, drop text or files on it.
@MainActor
final class PetController: NSObject {
    let state = PetState()
    private let jot: Jot
    private let panel: NSPanel
    private let host: PetHostView
    private var quick: FloatingPanel?
    private var card: FloatingPanel?
    private var hoverTimer: Timer?, closeTimer: Timer?, blinkTimer: Timer?, reactionTimer: Timer?, workTimer: Timer?
    private var lastActive = Date()
    private var mouseMonitor: Any?
    private var cardHovered = false
    var openPage: () -> Void = {}
    var menu: () -> NSMenu = { NSMenu() }

    init(jot: Jot) {
        self.jot = jot
        panel = NSPanel(contentRect: NSRect(origin: .zero, size: PetLayout.panelSize), styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        host = PetHostView(frame: NSRect(origin: .zero, size: PetLayout.panelSize))
        super.init()
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        let drawing = NSHostingView(rootView: PetView(state: state))
        drawing.frame = host.bounds
        drawing.autoresizingMask = [.width, .height]
        host.addSubview(drawing)
        host.controller = self
        panel.contentView = host
        panel.setFrameOrigin(origin(for: savedCenter()))
        breathe(drawing)
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.recoverPosition() }
        }
        scheduleBlink()
        Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.state.sleeping = Date().timeIntervalSince(self.lastActive) > 600 && self.quick?.isVisible != true
            }
        }
        mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved) { [weak self] _ in
            MainActor.assumeIsolated { self?.look() }
        }
    }

    var visible: Bool { panel.isVisible }

    func show() { panel.orderFrontRegardless(); UserDefaults.standard.set(false, forKey: "petHidden") }
    func hide() { panel.orderOut(nil); closeCard(); UserDefaults.standard.set(true, forKey: "petHidden") }

    // MARK: What the server says

    func update() {
        state.hasDraft = jot.hasDraft
        state.hasPendingSuggestions = (jot.status?.pending ?? 0) > 0
        state.failedCount = jot.status?.failed ?? 0
        let working = (jot.status?.organizing ?? 0) > 0 || jot.busy
        workTimer?.invalidate()
        if working, state.activity == .idle {  // only work that lasts is shown
            workTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.state.activity = .processing }
            }
        } else if !working {
            state.activity = .idle
        }
    }

    func react(_ reaction: PetReaction, for seconds: Double) {
        wake()
        state.reaction = reaction
        if reaction == .reject || { if case .worried = reaction { return true } else { return false } }() { shake() }
        reactionTimer?.invalidate()
        reactionTimer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { if self?.state.reaction == reaction { self?.state.reaction = nil } }
        }
    }

    // MARK: Mouse

    func clicked() {
        wake()
        react(.hop, for: 0.18)
        kick(0.6)
        showQuickCapture()
    }

    func pressed(_ down: Bool) { state.pressed = down; if down { wake() } }

    func dragged(by delta: NSPoint) {
        state.dragging = true
        state.dragTilt = max(-16, min(16, Double(delta.x) * 1.5))
        closeCard()
        panel.setFrameOrigin(NSPoint(x: panel.frame.origin.x + delta.x, y: panel.frame.origin.y + delta.y))
    }

    func dragEnded() {
        state.dragging = false; state.dragTilt = 0
        react(.land, for: 0.16)
        kick(0.8)
        recoverPosition()
        UserDefaults.standard.set(NSStringFromPoint(center), forKey: "petCenter")
    }

    func hovering(_ on: Bool) {
        state.hovering = on
        hoverTimer?.invalidate()
        if on {
            wake()
            closeTimer?.invalidate()
            hoverTimer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.showCard() }
            }
        } else {
            scheduleCardClose()
        }
    }

    func rightClicked(_ event: NSEvent) {
        wake()
        closeCard()
        NSMenu.popUpContextMenu(menu(), with: event, for: host)
    }

    /// Text is kept at once (as material); files and pictures go into the input bubble's draft.
    func dropped(_ pasteboard: NSPasteboard) -> Bool {
        state.dropTargeted = false
        if jot.add(pasteboard: pasteboard) {
            react(.gulp, for: 1.6)
            showQuickCapture()
            return true
        }
        if let text = pasteboard.string(forType: .string), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            jot.keep(material: text)
            return true
        }
        react(.reject, for: 1.6)
        return false
    }

    // MARK: The input bubble and the card

    func showQuickCapture() {
        closeCard()
        if quick == nil {
            let view = QuickCaptureView(jot: jot, onClose: { [weak self] in self?.closeQuickCapture() }, onOpenPage: { [weak self] in
                self?.closeQuickCapture(); self?.openPage()
            })
            quick = FloatingPanel(view, takesKeyboard: true)
            quick?.onResign = { [weak self] in
                DispatchQueue.main.async { if NSApp.modalWindow == nil { self?.closeQuickCapture() } }
            }
        }
        guard let quick else { return }
        jot.error = nil
        quick.fit()
        place(quick)
        state.cardShowing = true
        quick.makeKeyAndOrderFront(nil)
    }

    func closeQuickCapture() {
        quick?.orderOut(nil)
        state.cardShowing = card?.isVisible == true
        update()
    }

    private func showCard() {
        guard quick?.isVisible != true, !state.dragging else { return }
        if card == nil {
            card = FloatingPanel(PeekCard(jot: jot, onCapture: { [weak self] in self?.showQuickCapture() },
                                          onOpenPage: { [weak self] in self?.closeCard(); self?.openPage() },
                                          onHover: { [weak self] on in self?.cardHovered = on; if !on { self?.scheduleCardClose() } }),
                                 takesKeyboard: false)
        }
        guard let card else { return }
        Task { await jot.refresh() }
        card.fit()
        place(card)
        state.cardShowing = true
        card.orderFrontRegardless()
    }

    private func scheduleCardClose() {
        closeTimer?.invalidate()
        closeTimer = Timer.scheduledTimer(withTimeInterval: 0.35, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.state.hovering, !self.cardHovered else { return }
                self.closeCard()
            }
        }
    }

    func closeCard() {
        card?.orderOut(nil)
        state.cardShowing = quick?.isVisible == true
    }

    /// Above the pet, or below it near the top of the screen; on another screen than the pet, high in the middle of the
    /// screen the user is on.
    private func place(_ window: NSWindow) {
        let size = window.frame.size
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        guard let area = screen?.visibleFrame else { return }
        var origin: NSPoint
        if area.contains(center) {
            let top = panel.frame.origin.y + PetLayout.bodyCenter.y + PetLayout.hitRadius + 6
            origin = NSPoint(x: center.x - size.width / 2, y: top + size.height > area.maxY ? panel.frame.origin.y + 4 - size.height : top)
        } else {
            origin = NSPoint(x: area.midX - size.width / 2, y: area.maxY - area.height * 0.28 - size.height)
        }
        origin.x = max(area.minX + 8, min(origin.x, area.maxX - size.width - 8))
        origin.y = max(area.minY + 8, min(origin.y, area.maxY - size.height - 8))
        window.setFrameOrigin(origin)
    }

    // MARK: Life

    private var center: NSPoint { NSPoint(x: panel.frame.origin.x + PetLayout.bodyCenter.x, y: panel.frame.origin.y + PetLayout.bodyCenter.y) }

    private func origin(for center: NSPoint) -> NSPoint {
        NSPoint(x: center.x - PetLayout.bodyCenter.x, y: center.y - PetLayout.bodyCenter.y)
    }

    private func savedCenter() -> NSPoint {
        if let s = UserDefaults.standard.string(forKey: "petCenter") { return NSPointFromString(s) }
        let area = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        return NSPoint(x: area.maxX - 61, y: area.minY + 134)
    }

    /// Back onto a screen after a display went away or the pet was dragged off the edge.
    private func recoverPosition() {
        let c = center
        guard !NSScreen.screens.contains(where: { $0.visibleFrame.insetBy(dx: 20, dy: 20).contains(c) }) else { return }
        let area = (NSScreen.screens.min { distance($0.visibleFrame, c) < distance($1.visibleFrame, c) } ?? NSScreen.main)?.visibleFrame ?? .zero
        let r = PetLayout.hitRadius
        let fixed = NSPoint(x: max(area.minX + r, min(c.x, area.maxX - r)), y: max(area.minY + r, min(c.y, area.maxY - r)))
        panel.setFrameOrigin(origin(for: fixed))
        UserDefaults.standard.set(NSStringFromPoint(fixed), forKey: "petCenter")
    }

    private func distance(_ rect: NSRect, _ p: NSPoint) -> CGFloat {
        hypot(max(rect.minX - p.x, 0, p.x - rect.maxX), max(rect.minY - p.y, 0, p.y - rect.maxY))
    }

    private func wake() { lastActive = Date(); state.sleeping = false }

    private func kick(_ strength: Double) { state.sproutKick = Date(); state.sproutKickStrength = strength }

    private func shake() {
        guard !state.reduceMotion else { return }
        for i in 1...6 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.06 * Double(i)) { [weak self] in self?.state.shakePhase = i == 6 ? 0 : i }
        }
    }

    /// Random blinks every 2.2–5.5 s, a quarter of them double.
    private func scheduleBlink() {
        blinkTimer = Timer.scheduledTimer(withTimeInterval: .random(in: 2.2...5.5), repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let twice = Double.random(in: 0...1) < 0.25
                self.blink(); if twice { DispatchQueue.main.asyncAfter(deadline: .now() + 0.28) { self.blink() } }
                self.scheduleBlink()
            }
        }
    }

    private func blink() {
        state.blinking = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in self?.state.blinking = false }
    }

    /// Eyes follow the pointer when it is near (420 pt), otherwise look ahead.
    private func look() {
        let p = NSEvent.mouseLocation, c = center
        let dx = p.x - c.x, dy = p.y - c.y, d = hypot(dx, dy)
        let gaze = d < 420 && d > 1 ? CGVector(dx: dx / d, dy: -dy / d) : .zero
        if abs(gaze.dx - state.gaze.dx) > 0.15 || abs(gaze.dy - state.gaze.dy) > 0.15 { state.gaze = gaze }
    }

    /// A slow up-and-down squash, slower while asleep.
    private func breathe(_ view: NSView) {
        view.wantsLayer = true
        guard let layer = view.layer, !state.reduceMotion else { return }
        let anim = CABasicAnimation(keyPath: "sublayerTransform")
        anim.fromValue = CATransform3DIdentity
        anim.toValue = CATransform3DMakeScale(1.0, 1.025, 1)
        anim.duration = 1.7
        anim.autoreverses = true
        anim.repeatCount = .infinity
        anim.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        layer.add(anim, forKey: "breathe")
    }
}

/// Takes the mouse only on the pet's body (the rest of the panel clicks through), and drops of text, files and pictures.
final class PetHostView: NSView {
    weak var controller: PetController?
    private var downAt: NSPoint?
    private var moved = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.string, .fileURL, .png, .tiff])
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        return hypot(local.x - PetLayout.bodyCenter.x, local.y - PetLayout.bodyCenter.y) <= PetLayout.hitRadius ? self : nil
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control) { return rightMouseDown(with: event) }
        downAt = NSEvent.mouseLocation; moved = false
        MainActor.assumeIsolated { controller?.pressed(true) }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = downAt else { return }
        let now = NSEvent.mouseLocation
        if !moved, hypot(now.x - start.x, now.y - start.y) < 3 { return }
        moved = true
        MainActor.assumeIsolated { controller?.dragged(by: NSPoint(x: event.deltaX, y: -event.deltaY)) }
    }

    override func mouseUp(with event: NSEvent) {
        MainActor.assumeIsolated {
            controller?.pressed(false)
            if moved { controller?.dragEnded() } else if downAt != nil { controller?.clicked() }
        }
        downAt = nil
    }

    override func rightMouseDown(with event: NSEvent) { MainActor.assumeIsolated { controller?.rightClicked(event) } }
    override func mouseEntered(with event: NSEvent) { MainActor.assumeIsolated { controller?.hovering(true) } }
    override func mouseExited(with event: NSEvent) { MainActor.assumeIsolated { controller?.hovering(false) } }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        MainActor.assumeIsolated { controller?.state.dropTargeted = true }
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) { MainActor.assumeIsolated { controller?.state.dropTargeted = false } }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        MainActor.assumeIsolated { controller?.dropped(sender.draggingPasteboard) ?? false }
    }
}
