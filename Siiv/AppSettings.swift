//
//  AppSettings.swift
//  Siiv
//

import Combine
import Foundation

enum WindowSizeMode: String, CaseIterable, Identifiable {
    /// Window takes the image's proportions, capped at the image's own size
    /// and at the screen.
    case fitImage
    /// Window keeps the image's proportions and grows as large as the screen
    /// allows, zooming the image up to match.
    case zoomToFitScreen
    /// Window fills the screen's usable area.
    case maximized
    /// Native macOS fullscreen.
    case fullscreen
    /// Whatever size and position the window had last time.
    case rememberLast

    var id: String { rawValue }

    var label: String {
        switch self {
        case .fitImage: return "Fit to image"
        case .zoomToFitScreen: return "Zoom image to fit screen"
        case .maximized: return "Maximized"
        case .fullscreen: return "Fullscreen"
        case .rememberLast: return "Remember last size"
        }
    }

    var detail: String {
        switch self {
        case .fitImage:
            return "The window takes the image's shape and shows it at its own size, never bigger than the screen."
        case .zoomToFitScreen:
            return "The image is zoomed in until the window is as large as the screen allows. Images smaller than the screen can look soft."
        case .maximized:
            return "The window fills the screen below the menu bar."
        case .fullscreen:
            return "The window opens in macOS fullscreen."
        case .rememberLast:
            return "The window reopens at the size and position you left it."
        }
    }

    /// Modes whose size depends on the image being shown.
    var followsImage: Bool {
        self == .fitImage || self == .zoomToFitScreen
    }
}

@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    /// Arrow keys jump straight to the next image. Trackpad swipes keep
    /// their sliding transition either way.
    @Published var instantArrowSwitching: Bool {
        didSet { defaults.set(instantArrowSwitching, forKey: Keys.instantArrowSwitching) }
    }

    @Published var windowSizeMode: WindowSizeMode {
        didSet { defaults.set(windowSizeMode.rawValue, forKey: Keys.windowSizeMode) }
    }

    /// Re-size the window for every image, not just the first one.
    @Published var resizeWindowPerImage: Bool {
        didSet { defaults.set(resizeWindowPerImage, forKey: Keys.resizeWindowPerImage) }
    }

    /// Move on from the last image to the first, and the other way round.
    @Published var wrapAround: Bool {
        didSet { defaults.set(wrapAround, forKey: Keys.wrapAround) }
    }

    /// Ask first when moving an image to the Bin.
    @Published var confirmBeforeDelete: Bool {
        didSet { defaults.set(confirmBeforeDelete, forKey: Keys.confirmBeforeDelete) }
    }

    private let defaults: UserDefaults

    private enum Keys {
        static let instantArrowSwitching = "instantArrowSwitching"
        static let windowSizeMode = "windowSizeMode"
        static let resizeWindowPerImage = "resizeWindowPerImage"
        static let confirmBeforeDelete = "confirmBeforeDelete"
        static let wrapAround = "wrapAround"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        instantArrowSwitching = defaults.bool(forKey: Keys.instantArrowSwitching)
        windowSizeMode = defaults.string(forKey: Keys.windowSizeMode)
            .flatMap(WindowSizeMode.init(rawValue:)) ?? .fitImage
        resizeWindowPerImage = defaults.bool(forKey: Keys.resizeWindowPerImage)
        wrapAround = defaults.object(forKey: Keys.wrapAround) as? Bool ?? true
        // Deleting is destructive, so ask unless the user has said otherwise.
        confirmBeforeDelete = defaults.object(forKey: Keys.confirmBeforeDelete) as? Bool ?? true
    }
}
