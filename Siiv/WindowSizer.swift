//
//  WindowSizer.swift
//  Siiv
//

import AppKit
import Combine
import SwiftUI

/// Applies the window-size setting to the image window.
@MainActor
final class WindowSizer {
    static let shared = WindowSizer()

    private enum Reason {
        case initial
        case imageChanged
        case settingsChanged
    }

    private weak var window: NSWindow?
    private var didApplyInitial = false
    private var lastImageSize: NSSize?
    private var observers: [NSObjectProtocol] = []
    private var cancellables: Set<AnyCancellable> = []

    private let defaults = UserDefaults.standard
    private let savedFrameKey = "mainWindowFrame"
    /// Matches the minimum size ContentView declares.
    private let minContentSize = NSSize(width: 400, height: 300)

    private init() {
        let settings = AppSettings.shared
        // Re-apply when the mode changes, or when per-image sizing is turned on.
        // Deferred to the next runloop pass so the new value is readable.
        settings.$windowSizeMode
            .sink { [weak self] _ in
                DispatchQueue.main.async { self?.apply(reason: .settingsChanged) }
            }
            .store(in: &cancellables)
        settings.$resizeWindowPerImage
            .sink { [weak self] enabled in
                guard enabled else { return }
                DispatchQueue.main.async { self?.apply(reason: .settingsChanged) }
            }
            .store(in: &cancellables)
    }

    // MARK: - Wiring

    func attach(to window: NSWindow) {
        guard self.window !== window else { return }
        self.window = window

        // The size setting is authoritative, so turn off AppKit's own frame
        // autosave and state restoration; "Remember last size" is handled here.
        window.setFrameAutosaveName("")
        window.isRestorable = false

        observers.forEach(NotificationCenter.default.removeObserver)
        observers = [
            observe(NSWindow.didEndLiveResizeNotification, on: window) { $0.saveFrame() },
            observe(NSWindow.didMoveNotification, on: window) { $0.saveFrame() },
            // Catches resizes with no live-resize session, such as zooming.
            observe(NSWindow.didResizeNotification, on: window) { sizer in
                guard window.inLiveResize == false else { return }
                sizer.saveFrame()
            },
            observe(NSWindow.willCloseNotification, on: window) { $0.saveFrame() },
            // Leaving fullscreen for another mode: size the restored window.
            observe(NSWindow.didExitFullScreenNotification, on: window) { sizer in
                if AppSettings.shared.windowSizeMode != .fullscreen {
                    sizer.apply(reason: .settingsChanged)
                }
            },
        ]

        // Modes that don't depend on the image can be applied right away;
        // the others wait for the first image.
        if !AppSettings.shared.windowSizeMode.followsImage {
            apply(reason: .initial)
        }
    }

    /// A different picture is now on screen.
    func imageChanged(size: NSSize?) {
        guard let size, size.width > 0, size.height > 0 else { return }
        lastImageSize = size
        apply(reason: didApplyInitial ? .imageChanged : .initial)
    }

    private func observe(
        _ name: Notification.Name,
        on window: NSWindow,
        handler: @escaping (WindowSizer) -> Void
    ) -> NSObjectProtocol {
        NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                handler(self)
            }
        }
    }

    // MARK: - Applying

    private func apply(reason: Reason) {
        guard let window else { return }
        let settings = AppSettings.shared
        let mode = settings.windowSizeMode

        if reason == .imageChanged {
            guard settings.resizeWindowPerImage, mode.followsImage else { return }
        }
        if reason == .initial {
            didApplyInitial = true
        }

        // Never fight fullscreen: leave it only when the setting says so.
        if window.styleMask.contains(.fullScreen) {
            if mode != .fullscreen, reason == .settingsChanged {
                window.toggleFullScreen(nil) // sizing continues in didExitFullScreen
            }
            return
        }

        switch mode {
        case .fullscreen:
            if reason != .imageChanged {
                window.toggleFullScreen(nil)
            }
        case .maximized:
            window.setFrame(visibleFrame(for: window), display: true)
        case .rememberLast:
            if reason != .imageChanged, let saved = defaults.string(forKey: savedFrameKey) {
                window.setFrame(from: saved)
            }
        case .fitImage, .zoomToFitScreen:
            guard let imageSize = lastImageSize else { return }
            // Size the area the image is drawn in, not the whole content area:
            // the title bar takes a slice off the top, and counting that slice
            // as image space leaves the picture letterboxed in a window that
            // looks like it should fit it exactly.
            let titleBar = titleBarHeight(for: window)
            let maxContent = maxContentSize(for: window)
            var scale = min(maxContent.width / imageSize.width,
                            (maxContent.height - titleBar) / imageSize.height)
            if mode == .fitImage {
                scale = min(scale, 1) // never blow the image up past its own size
            }
            let content = NSSize(
                width: max((imageSize.width * scale).rounded(), minContentSize.width),
                height: max((imageSize.height * scale).rounded() + titleBar,
                            minContentSize.height)
            )
            setContentSize(content, on: window, keepingCenter: reason != .initial)
        }
    }

    private func setContentSize(_ content: NSSize, on window: NSWindow, keepingCenter: Bool) {
        let visible = visibleFrame(for: window)
        let size = window.frameRect(forContentRect: NSRect(origin: .zero, size: content)).size
        let center = keepingCenter
            ? CGPoint(x: window.frame.midX, y: window.frame.midY)
            : CGPoint(x: visible.midX, y: visible.midY)

        var frame = NSRect(
            x: center.x - size.width / 2,
            y: center.y - size.height / 2,
            width: size.width,
            height: size.height
        )
        // Keep the whole window on screen.
        frame.origin.x = min(max(frame.minX, visible.minX), visible.maxX - frame.width)
        frame.origin.y = min(max(frame.minY, visible.minY), visible.maxY - frame.height)
        window.setFrame(frame, display: true)
    }

    /// Slice of the content area the title bar covers. SwiftUI draws content
    /// at full window size and lays the image view out underneath the bar.
    private func titleBarHeight(for window: NSWindow) -> CGFloat {
        guard let contentView = window.contentView else { return 0 }
        return max(0, contentView.bounds.height - window.contentLayoutRect.height)
    }

    /// Largest content size that still leaves the window on screen.
    private func maxContentSize(for window: NSWindow) -> NSSize {
        let visible = visibleFrame(for: window)
        let chromeHeight = window.frame.height
            - window.contentRect(forFrameRect: window.frame).height
        return NSSize(
            width: max(visible.width, minContentSize.width),
            height: max(visible.height - chromeHeight, minContentSize.height)
        )
    }

    private func visibleFrame(for window: NSWindow) -> NSRect {
        window.screen?.visibleFrame
            ?? NSScreen.main?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
    }

    private func saveFrame() {
        guard let window, !window.styleMask.contains(.fullScreen) else { return }
        defaults.set(window.frameDescriptor, forKey: savedFrameKey)
    }
}

/// Hands the enclosing NSWindow to the sizer.
struct WindowAccessor: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async {
            if let window = view.window {
                WindowSizer.shared.attach(to: window)
            }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        if let window = nsView.window {
            WindowSizer.shared.attach(to: window)
        }
    }
}
