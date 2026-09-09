//
//  EdgeArrow.swift
//  Siiv
//

import AppKit

/// A faint chevron over the left or right edge of the image, shown while the
/// pointer is in the strip that clicks through to the previous or next image.
final class EdgeArrowView: NSView {
    enum Direction {
        case previous, next

        var symbolName: String {
            self == .previous ? "chevron.left" : "chevron.right"
        }
    }

    static let diameter: CGFloat = 46
    /// Gap between the arrow and the edge of the image.
    static let inset: CGFloat = 22

    private let chevron = NSImageView()

    init(direction: Direction) {
        super.init(frame: NSRect(x: 0, y: 0, width: Self.diameter, height: Self.diameter))
        wantsLayer = true
        alphaValue = 0

        chevron.image = NSImage(systemSymbolName: direction.symbolName,
                                accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 19, weight: .semibold))
        chevron.image?.isTemplate = true
        chevron.contentTintColor = .white
        chevron.imageScaling = .scaleNone
        chevron.frame = bounds
        addSubview(chevron)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// The strip behind it takes the clicks, not the arrow itself.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.4).setFill()
        NSBezierPath(ovalIn: bounds).fill()
    }

    /// Fade in or out. Nothing happens if it is already in that state.
    func setShown(_ shown: Bool) {
        let target: CGFloat = shown ? 1 : 0
        guard abs(alphaValue - target) > 0.01 else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = shown ? 0.12 : 0.25
            animator().alphaValue = target
        }
    }
}
