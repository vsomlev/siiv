//
//  HUDToast.swift
//  Siiv
//

import AppKit

/// A small translucent HUD in the style of the system volume overlay: it
/// fades in over the image, then leaves on its own. It sits inside the image
/// view rather than in its own window, so it shows in fullscreen as well.
final class HUDToastView: NSView {
    private let background = NSVisualEffectView()
    private let label = NSTextField(labelWithString: "")
    private var hideWork: DispatchWorkItem?

    private let horizontalPadding: CGFloat = 18
    private let verticalPadding: CGFloat = 11
    private let bottomInset: CGFloat = 28

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        alphaValue = 0

        background.material = .hudWindow
        background.blendingMode = .withinWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 11
        background.layer?.cornerCurve = .continuous
        background.layer?.masksToBounds = true
        addSubview(background)

        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.alignment = .center
        background.addSubview(label)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Decoration only: clicks belong to the image underneath.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func show(_ text: String, in parent: NSView, for duration: TimeInterval = 1.4) {
        label.stringValue = text
        if superview !== parent {
            removeFromSuperview()
            parent.addSubview(self)
        }
        reposition()

        hideWork?.cancel()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            animator().alphaValue = 1
        }
        let work = DispatchWorkItem { [weak self] in
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.45
                self?.animator().alphaValue = 0
            }
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)
    }

    /// Keep it centred along the bottom as the view around it changes size.
    func reposition() {
        guard let parent = superview else { return }
        let unbounded = CGFloat.greatestFiniteMagnitude
        let text = label.sizeThatFits(NSSize(width: unbounded, height: unbounded))
        let size = NSSize(width: (ceil(text.width) + horizontalPadding * 2).rounded(),
                          height: (ceil(text.height) + verticalPadding * 2).rounded())
        frame = NSRect(x: ((parent.bounds.width - size.width) / 2).rounded(),
                       y: bottomInset,
                       width: size.width,
                       height: size.height)
        background.frame = bounds
        label.frame = NSRect(x: horizontalPadding,
                             y: verticalPadding,
                             width: size.width - horizontalPadding * 2,
                             height: size.height - verticalPadding * 2)
    }
}
