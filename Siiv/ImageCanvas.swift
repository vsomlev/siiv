//
//  ImageCanvas.swift
//  Siiv
//

import AppKit
import QuartzCore
import SwiftUI
import UniformTypeIdentifiers

/// AppKit-backed image canvas: pinch zoom, Photos-style sliding swipe
/// navigation, scroll-to-pan when zoomed, arrow keys, double-click fullscreen.
final class ImageCanvasView: NSView {
    var onNavigate: ((Int) -> Void)?
    /// Peek at the image `delta` steps away without navigating.
    var neighborProvider: ((Int) -> NSImage?)?
    var onZoomChanged: ((CGFloat) -> Void)?
    /// File URL of the displayed image, for Open With / Share.
    var currentURL: URL?
    /// Arrow keys skip the slide transition. Swipes slide regardless.
    var instantArrowSwitching = false
    var onDelete: (() -> Void)?
    var onJump: ((NavigationJump) -> Void)?

    enum NavigationJump { case first, last }

    private lazy var toast = HUDToastView()
    private lazy var previousArrow = EdgeArrowView(direction: .previous)
    private lazy var nextArrow = EdgeArrowView(direction: .next)
    /// Which edge strip the pointer is in, if any.
    private var hoveredEdge: Int?

    /// Fraction of the width on each side that clicks through to another image.
    private let edgeStripFraction: CGFloat = 0.25

    private var sharingPicker: NSSharingServicePicker?

    private(set) var image: NSImage?

    /// `resetView: false` swaps the bitmap (e.g. a full-resolution upgrade of
    /// the same picture) while preserving zoom, pan, and slide state.
    func setImage(_ newImage: NSImage?, resetView: Bool) {
        image = newImage
        if resetView {
            zoom = 1
            panOffset = .zero
            resetSlideState()
        }
        let edge = hoveredEdge
        hoveredEdge = nil // force a re-check against the new neighbours
        updateArrows(for: edge.map { CGPoint(x: $0 < 0 ? bounds.minX : bounds.maxX, y: bounds.midY) })
        needsDisplay = true
    }

    private var zoom: CGFloat = 1
    private var panOffset = CGPoint.zero

    private let minZoom: CGFloat = 1
    private let maxZoom: CGFloat = 64

    // MARK: - Slide transition state

    /// Horizontal displacement of the current image (0 = at rest).
    private var slideOffset: CGFloat = 0
    /// Direction (-1/+1) the transition will commit at animation end; 0 = snap back.
    private var pendingCommit = 0
    private var lastSwipeDelta: CGFloat = 0
    private var slideAnimation: (start: CGFloat, target: CGFloat, startTime: CFTimeInterval)?
    private var slideDisplayLink: CADisplayLink?
    /// Neighbor image cache for the gesture in progress.
    private var neighborImage: NSImage?
    private var neighborDelta = 0

    private let slideGap: CGFloat = 40
    private let slideDuration: CFTimeInterval = 0.25

    private var slideTravel: CGFloat { bounds.width + slideGap }

    private var keyMonitor: Any?

    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
        guard window != nil else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            window?.makeFirstResponder(self)
        }
        // First-responder status inside SwiftUI hosting is unreliable;
        // a local monitor guarantees arrow keys always work.
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === window else { return event }
            return handleNavigationKey(event) ? nil : event
        }
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        toast.reposition()
        layOutArrows()
        clampPan()
        needsDisplay = true
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.setFill()
        bounds.fill()
        guard let image else { return }
        NSGraphicsContext.current?.imageInterpolation = .high
        image.draw(in: drawRect(for: image).offsetBy(dx: slideOffset, dy: 0))

        // Incoming neighbor during a slide.
        if slideOffset != 0, let neighbor = neighbor(for: slideOffset < 0 ? 1 : -1) {
            let shift = slideOffset < 0 ? slideOffset + slideTravel : slideOffset - slideTravel
            let fitted = fittedSize(for: neighbor)
            neighbor.draw(in: NSRect(
                x: bounds.midX - fitted.width / 2 + shift,
                y: bounds.midY - fitted.height / 2,
                width: fitted.width,
                height: fitted.height
            ))
        }
    }

    private func fittedSize(for image: NSImage) -> NSSize {
        let size = image.size
        guard size.width > 0, size.height > 0, bounds.width > 0, bounds.height > 0 else {
            return size
        }
        let scale = min(bounds.width / size.width, bounds.height / size.height)
        return NSSize(width: size.width * scale, height: size.height * scale)
    }

    private func drawRect(for image: NSImage) -> NSRect {
        let fitted = fittedSize(for: image)
        let size = NSSize(width: fitted.width * zoom, height: fitted.height * zoom)
        return NSRect(
            x: bounds.midX - size.width / 2 + panOffset.x,
            y: bounds.midY - size.height / 2 + panOffset.y,
            width: size.width,
            height: size.height
        )
    }

    private func clampPan() {
        guard let image else {
            panOffset = .zero
            return
        }
        let fitted = fittedSize(for: image)
        let maxX = max(0, (fitted.width * zoom - bounds.width) / 2)
        let maxY = max(0, (fitted.height * zoom - bounds.height) / 2)
        panOffset.x = min(max(panOffset.x, -maxX), maxX)
        panOffset.y = min(max(panOffset.y, -maxY), maxY)
    }

    // MARK: - Zoom

    override func magnify(with event: NSEvent) {
        setZoom(zoom * (1 + event.magnification),
                anchor: convert(event.locationInWindow, from: nil))
    }

    /// Two-finger double tap: toggle between fit and 2x.
    override func smartMagnify(with event: NSEvent) {
        let target: CGFloat = zoom > 1.001 ? 1 : 2
        setZoom(target, anchor: convert(event.locationInWindow, from: nil))
    }

    private func setZoom(_ newZoom: CGFloat, anchor: CGPoint) {
        guard image != nil else { return }
        finishSlide()
        let oldZoom = zoom
        zoom = min(max(newZoom, minZoom), maxZoom)
        // Keep the image point under the anchor stationary.
        let factor = zoom / oldZoom
        let d = CGPoint(x: anchor.x - bounds.midX, y: anchor.y - bounds.midY)
        panOffset.x = (panOffset.x - d.x) * factor + d.x
        panOffset.y = (panOffset.y - d.y) * factor + d.y
        clampPan()
        needsDisplay = true
        onZoomChanged?(zoom)
    }

    // MARK: - Scroll: pan when zoomed, slide between images at fit

    override func scrollWheel(with event: NSEvent) {
        guard image != nil else { return }
        if zoom > 1.001 {
            panOffset.x += event.scrollingDeltaX
            panOffset.y -= event.scrollingDeltaY
            clampPan()
            needsDisplay = true
            return
        }
        switch event.phase {
        case .began:
            finishSlide()
            invalidateNeighborCache()
        case .changed:
            let delta = event.scrollingDeltaX
            lastSwipeDelta = delta
            let direction = (slideOffset + delta) < 0 ? 1 : -1
            // Rubber-band resistance when there is no image on that side.
            slideOffset += neighbor(for: direction) == nil ? delta * 0.25 : delta
            needsDisplay = true
        case .ended, .cancelled:
            endSwipe()
        default:
            break // ignore momentum-phase events
        }
    }

    private func endSwipe() {
        let direction = slideOffset < 0 ? 1 : -1
        let dragged = abs(slideOffset) > bounds.width * 0.25
        let flicked = abs(lastSwipeDelta) > 10 && abs(slideOffset) > 20
        if neighbor(for: direction) != nil, dragged || flicked {
            pendingCommit = direction
            animateSlide(to: CGFloat(-direction) * slideTravel)
        } else {
            pendingCommit = 0
            animateSlide(to: 0)
        }
    }

    // MARK: - Slide animation

    /// The cached neighbour is only good for as long as the neighbours are:
    /// deleting one, or turning wrapping on or off, changes them underneath.
    private func invalidateNeighborCache() {
        neighborImage = nil
        neighborDelta = 0
    }

    private func neighbor(for delta: Int) -> NSImage? {
        if neighborDelta != delta {
            neighborImage = neighborProvider?(delta)
            neighborDelta = delta
        }
        return neighborImage
    }

    private func animateSlide(to target: CGFloat) {
        slideDisplayLink?.invalidate()
        slideAnimation = (slideOffset, target, CACurrentMediaTime())
        let link = displayLink(target: self, selector: #selector(slideTick))
        link.add(to: .main, forMode: .common)
        slideDisplayLink = link
    }

    @objc private func slideTick() {
        guard let animation = slideAnimation else {
            slideDisplayLink?.invalidate()
            slideDisplayLink = nil
            return
        }
        let t = min(1, (CACurrentMediaTime() - animation.startTime) / slideDuration)
        let eased = 1 - pow(1 - t, 3) // ease-out cubic
        slideOffset = animation.start + (animation.target - animation.start) * CGFloat(eased)
        needsDisplay = true
        if t >= 1 {
            finishSlide()
        }
    }

    /// Complete any in-flight slide immediately: commit the pending
    /// navigation or snap back to rest.
    private func finishSlide() {
        slideDisplayLink?.invalidate()
        slideDisplayLink = nil
        slideAnimation = nil
        let commit = pendingCommit
        pendingCommit = 0
        if commit != 0 {
            // Leave slideOffset at the slid position: the neighbor is sitting
            // exactly at center, so the swap to the new image is seamless
            // once it arrives and resets the slide state.
            onNavigate?(commit)
        } else {
            slideOffset = 0
            needsDisplay = true
        }
    }

    private func resetSlideState() {
        slideDisplayLink?.invalidate()
        slideDisplayLink = nil
        slideAnimation = nil
        pendingCommit = 0
        slideOffset = 0
        neighborImage = nil
        neighborDelta = 0
    }

    /// Navigate with a slide animation when possible, instantly otherwise.
    /// Only the arrow keys skip the slide, and only when that is turned on.
    private func navigate(_ delta: Int, instant: Bool = false) {
        guard !instant, zoom <= 1.001, slideAnimation == nil, pendingCommit == 0,
              abs(delta) == 1, neighbor(for: delta) != nil
        else {
            finishSlide()
            onNavigate?(delta)
            return
        }
        pendingCommit = delta
        animateSlide(to: CGFloat(-delta) * slideTravel)
    }

    // MARK: - Keyboard & mouse

    private var isFullScreen: Bool {
        window?.styleMask.contains(.fullScreen) == true
    }

    private func handleNavigationKey(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command, .control, .option])
        let plain = modifiers.isEmpty
        let command = modifiers == .command

        func jump(_ target: NavigationJump) {
            finishSlide() // a jump is not a step, so no slide between them
            onJump?(target)
        }

        switch event.keyCode {
        case 115: // home
            guard plain else { return false }
            jump(.first)
            return true
        case 119: // end
            guard plain else { return false }
            jump(.last)
            return true
        case 123, 126: // left, up
            if command { jump(.first); return true }
            guard plain else { return false }
            navigate(-1, instant: instantArrowSwitching)
            return true
        case 124, 125: // right, down
            if command { jump(.last); return true }
            guard plain else { return false }
            navigate(1, instant: instantArrowSwitching)
            return true
        case 51, 117: // delete, forward delete
            // Modified presses fall through to the File menu's item.
            guard plain else { return false }
            onDelete?()
            return true
        case 53: // escape
            guard plain else { return false }
            if isFullScreen {
                window?.toggleFullScreen(nil)
            } else {
                NSApp.terminate(nil)
            }
            return true
        default:
            guard plain else { return false }
            switch event.charactersIgnoringModifiers {
            case "f":
                window?.toggleFullScreen(nil)
                return true
            case "o":
                showOpenWithMenu()
                return true
            case "s":
                showSharePicker()
                return true
            default:
                return false
            }
        }
    }

    /// Show a passing HUD over the image, e.g. after browsing wraps around.
    func showNotice(_ text: String) {
        toast.show(text, in: self)
    }

    // MARK: - Open With & Share

    /// Point to anchor popups at: the mouse location when it's over the view,
    /// the view center otherwise.
    private var popupAnchor: CGPoint {
        guard let window else { return CGPoint(x: bounds.midX, y: bounds.midY) }
        let mouse = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        return bounds.contains(mouse) ? mouse : CGPoint(x: bounds.midX, y: bounds.midY)
    }

    private func showOpenWithMenu() {
        guard let url = currentURL else { return }
        let workspace = NSWorkspace.shared

        // The URL-based lookups can come up empty; fall back to the content type.
        var apps = workspace.urlsForApplications(toOpen: url)
        var defaultApp = workspace.urlForApplication(toOpen: url)
        if apps.isEmpty {
            let type = (try? url.resourceValues(forKeys: [.contentTypeKey]).contentType)
                ?? UTType(filenameExtension: url.pathExtension)
                ?? .image
            apps = workspace.urlsForApplications(toOpen: type)
            defaultApp = defaultApp ?? workspace.urlForApplication(toOpen: type)
        }
        apps.removeAll { $0.standardizedFileURL == Bundle.main.bundleURL.standardizedFileURL }
        guard !apps.isEmpty else { NSSound.beep(); return }

        func appName(_ appURL: URL) -> String {
            FileManager.default.displayName(atPath: appURL.path)
        }
        func menuItem(_ appURL: URL, suffix: String = "") -> NSMenuItem {
            let item = NSMenuItem(title: appName(appURL) + suffix,
                                  action: #selector(openWithApp(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = appURL
            let icon = workspace.icon(forFile: appURL.path)
            icon.size = NSSize(width: 16, height: 16)
            item.image = icon
            return item
        }

        let menu = NSMenu(title: "Open With")
        if let defaultApp, let first = apps.first(where: {
            $0.standardizedFileURL == defaultApp.standardizedFileURL
        }) {
            menu.addItem(menuItem(first, suffix: " (default)"))
            menu.addItem(.separator())
            apps.removeAll { $0.standardizedFileURL == defaultApp.standardizedFileURL }
        }
        for appURL in apps.sorted(by: {
            appName($0).localizedCaseInsensitiveCompare(appName($1)) == .orderedAscending
        }) {
            menu.addItem(menuItem(appURL))
        }
        menu.popUp(positioning: nil, at: popupAnchor, in: self)
    }

    @objc private func openWithApp(_ sender: NSMenuItem) {
        guard let appURL = sender.representedObject as? URL, let url = currentURL else { return }
        NSWorkspace.shared.open([url], withApplicationAt: appURL,
                                configuration: NSWorkspace.OpenConfiguration())
    }

    private func showSharePicker() {
        guard let url = currentURL else { return }
        let picker = NSSharingServicePicker(items: [url])
        sharingPicker = picker // keep alive while the popover is up
        let anchor = popupAnchor
        picker.show(relativeTo: NSRect(x: anchor.x, y: anchor.y, width: 1, height: 1),
                    of: self, preferredEdge: .minY)
    }

    override func keyDown(with event: NSEvent) {
        if !handleNavigationKey(event) {
            super.keyDown(with: event)
        }
    }

    // MARK: - Edge strips

    /// -1 or 1 when the point is in the strip that goes to the previous or
    /// next image. Zoomed in, the whole view is for panning instead.
    private func edgeStrip(at point: CGPoint) -> Int? {
        guard image != nil, zoom <= 1.001, bounds.width > 0 else { return nil }
        let strip = bounds.width * edgeStripFraction
        if point.x <= bounds.minX + strip { return -1 }
        if point.x >= bounds.maxX - strip { return 1 }
        return nil
    }

    private func layOutArrows() {
        let y = (bounds.midY - EdgeArrowView.diameter / 2).rounded()
        previousArrow.frame.origin = CGPoint(x: EdgeArrowView.inset, y: y)
        nextArrow.frame.origin = CGPoint(
            x: bounds.maxX - EdgeArrowView.inset - EdgeArrowView.diameter, y: y)
    }

    private func updateArrows(for point: CGPoint?) {
        let edge = point.flatMap { edgeStrip(at: $0) }
        guard edge != hoveredEdge else { return }
        hoveredEdge = edge

        for arrow in [previousArrow, nextArrow] where arrow.superview !== self {
            addSubview(arrow)
        }
        layOutArrows()
        // Nothing to go to means nothing to point at.
        invalidateNeighborCache()
        previousArrow.setShown(edge == -1 && neighbor(for: -1) != nil)
        nextArrow.setShown(edge == 1 && neighbor(for: 1) != nil)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self))
    }

    override func mouseMoved(with event: NSEvent) {
        updateArrows(for: convert(event.locationInWindow, from: nil))
    }

    override func mouseEntered(with event: NSEvent) {
        updateArrows(for: convert(event.locationInWindow, from: nil))
    }

    override func mouseExited(with event: NSEvent) {
        updateArrows(for: nil)
    }

    override func mouseDown(with event: NSEvent) {
        if let edge = edgeStrip(at: convert(event.locationInWindow, from: nil)) {
            navigate(edge)
            return
        }
        if event.clickCount == 2 {
            window?.toggleFullScreen(nil)
        }
    }
}

struct ImageCanvas: NSViewRepresentable {
    let image: NSImage?
    /// Identity of the displayed picture; a change resets zoom/pan/slide,
    /// while a new bitmap for the same ID (full-res upgrade) does not.
    let imageID: URL?
    let instantArrowSwitching: Bool
    let onNavigate: (Int) -> Void
    let onDelete: () -> Void
    let onJump: (ImageCanvasView.NavigationJump) -> Void
    let wrapNotice: ViewerModel.WrapNotice?
    let neighborProvider: (Int) -> NSImage?
    let onZoomChanged: (CGFloat) -> Void

    final class Coordinator {
        var lastID: URL?
        var lastNoticeID: UUID?
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> ImageCanvasView {
        let view = ImageCanvasView()
        context.coordinator.lastID = imageID
        context.coordinator.lastNoticeID = wrapNotice?.id
        view.onNavigate = onNavigate
        view.neighborProvider = neighborProvider
        view.onZoomChanged = onZoomChanged
        view.currentURL = imageID
        view.instantArrowSwitching = instantArrowSwitching
        view.onDelete = onDelete
        view.onJump = onJump
        view.setImage(image, resetView: true)
        return view
    }

    func updateNSView(_ view: ImageCanvasView, context: Context) {
        view.onNavigate = onNavigate
        view.neighborProvider = neighborProvider
        view.onZoomChanged = onZoomChanged
        view.currentURL = imageID
        view.instantArrowSwitching = instantArrowSwitching
        view.onDelete = onDelete
        view.onJump = onJump
        if let wrapNotice, context.coordinator.lastNoticeID != wrapNotice.id {
            context.coordinator.lastNoticeID = wrapNotice.id
            view.showNotice(wrapNotice.text)
        }
        if context.coordinator.lastID != imageID {
            context.coordinator.lastID = imageID
            view.setImage(image, resetView: true)
        } else if view.image !== image {
            view.setImage(image, resetView: false)
        }
    }
}
