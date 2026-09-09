//
//  ViewerModel.swift
//  Siiv
//

import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class ViewerModel: ObservableObject {
    static let shared = ViewerModel()

    @Published private(set) var image: NSImage?
    @Published private(set) var currentURL: URL?
    @Published private(set) var title = "Siiv"

    /// Set when browsing runs off one end of the folder and comes back in at
    /// the other, so the view can say so. The id makes repeats distinct.
    struct WrapNotice: Equatable {
        let id = UUID()
        let text: String
    }
    @Published private(set) var wrapNotice: WrapNotice?

    private var siblings: [URL] = []
    private var index = 0

    // Cache of display-sized (screen-resolution) images. Neighbors are
    // decoded off the main thread so switching hits a warm cache.
    private var cache: [URL: NSImage] = [:]
    private var cacheOrder: [URL] = []
    private var prefetching: Set<URL> = []
    private let cacheLimit = 6

    /// URL whose full-resolution image is currently loaded (or being loaded).
    private var fullResURL: URL?
    private var fullResInflight: URL?

    /// Enough pixels to look sharp at fit-to-window on the largest screen.
    private static let displayMaxPixel: CGFloat = {
        let screenMax = NSScreen.screens
            .map { max($0.frame.width, $0.frame.height) * $0.backingScaleFactor }
            .max() ?? 2560
        return max(screenMax, 2560)
    }()

    private static let imageExtensions: Set<String> = [
        "jpg", "jpeg", "png", "gif", "heic", "heif",
        "tiff", "tif", "bmp", "webp", "avif", "jp2", "icns",
    ]

    func open(url: URL) {
        let directory = url.deletingLastPathComponent()
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []

        siblings = contents
            .filter { Self.imageExtensions.contains($0.pathExtension.lowercased()) }
            .sorted {
                $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
            }
        if siblings.isEmpty {
            siblings = [url]
        }
        index = siblings.firstIndex { $0.standardizedFileURL == url.standardizedFileURL } ?? 0
        cache.removeAll()
        cacheOrder.removeAll()
        load()
    }

    /// Index `delta` steps away, wrapping around the ends when that is turned
    /// on. Nil when there is nothing there.
    private func index(offsetBy delta: Int) -> Int? {
        let count = siblings.count
        guard count > 0 else { return nil }
        let target = index + delta
        if (0..<count).contains(target) { return target }
        guard AppSettings.shared.wrapAround, count > 1 else { return nil }
        return ((target % count) + count) % count
    }

    /// Image `delta` steps away from the current one, without navigating.
    func peekImage(delta: Int) -> NSImage? {
        guard let peekIndex = index(offsetBy: delta) else { return nil }
        return displayImage(for: siblings[peekIndex])
    }

    func navigate(by delta: Int) {
        guard let newIndex = index(offsetBy: delta) else { return }
        // Crossing an end means the list wrapped; say so.
        let wrappedForward = index + delta >= siblings.count
        let wrappedBack = index + delta < 0
        if wrappedForward || wrappedBack {
            wrapNotice = WrapNotice(text: wrappedForward
                                    ? "Back to the first image"
                                    : "Back to the last image")
        }
        index = newIndex
        load()
    }

    func goToFirst() {
        guard !siblings.isEmpty, index != 0 else { return }
        index = 0
        load()
    }

    func goToLast() {
        guard !siblings.isEmpty, index != siblings.count - 1 else { return }
        index = siblings.count - 1
        load()
    }

    /// Canvas reports zoom changes; past ~fit we swap in the full-resolution
    /// image so zooming stays sharp.
    func zoomChanged(_ zoom: CGFloat) {
        if zoom > 1.25 {
            ensureFullResolution()
        }
    }

    // MARK: - Deleting

    var canDelete: Bool { currentURL != nil }

    /// Move the current image to the Bin, asking first if the setting says so.
    func deleteCurrentImage() {
        guard let url = currentURL else { return }
        guard AppSettings.shared.confirmBeforeDelete else {
            moveToBin(url)
            return
        }

        let alert = NSAlert()
        alert.messageText = "Move \u{201C}\(url.lastPathComponent)\u{201D} to the Bin?"
        alert.informativeText = "You can put it back from the Bin."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Move to Bin")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true

        guard let window = NSApp.keyWindow ?? NSApp.windows.first else {
            if alert.runModal() == .alertFirstButtonReturn { moveToBin(url) }
            return
        }
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            self?.moveToBin(url)
        }
    }

    private func moveToBin(_ url: URL) {
        Task { @MainActor in
            do {
                _ = try await NSWorkspace.shared.recycle([url])
                forgetDeletedImage(at: url)
            } catch {
                presentDeleteFailure(url, error)
            }
        }
    }

    /// Drop a deleted image from the list and show whatever took its place.
    private func forgetDeletedImage(at url: URL) {
        guard let removed = siblings.firstIndex(where: {
            $0.standardizedFileURL == url.standardizedFileURL
        }) else { return }

        siblings.remove(at: removed)
        cache[url] = nil
        cacheOrder.removeAll { $0 == url }

        guard !siblings.isEmpty else {
            index = 0
            currentURL = nil
            image = nil
            title = "Siiv"
            return
        }
        // Hold the position: show the image that slid into this slot, or the
        // last one when the deleted image was at the end.
        index = min(removed, siblings.count - 1)
        load()
    }

    private func presentDeleteFailure(_ url: URL, _ error: Error) {
        let alert = NSAlert()
        alert.messageText = "Could not move \u{201C}\(url.lastPathComponent)\u{201D} to the Bin."
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .warning
        if let window = NSApp.keyWindow ?? NSApp.windows.first {
            alert.beginSheetModal(for: window, completionHandler: nil)
        } else {
            alert.runModal()
        }
    }

    // MARK: - Open With / Share (menu bar)

    struct OpenWithCandidate: Identifiable {
        let appURL: URL
        let name: String
        let icon: NSImage
        let isDefault: Bool
        var id: URL { appURL }
    }

    /// Cached per file extension: SwiftUI re-evaluates the command menus on
    /// every published change, and the LaunchServices lookup isn't free.
    private var openWithCache: [String: [OpenWithCandidate]] = [:]

    func openWithCandidates() -> [OpenWithCandidate] {
        guard let url = currentURL else { return [] }
        let key = url.pathExtension.lowercased()
        if let cached = openWithCache[key] {
            return cached
        }
        let workspace = NSWorkspace.shared
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

        func candidate(_ appURL: URL, isDefault: Bool) -> OpenWithCandidate {
            let icon = workspace.icon(forFile: appURL.path)
            icon.size = NSSize(width: 16, height: 16)
            return OpenWithCandidate(
                appURL: appURL,
                name: FileManager.default.displayName(atPath: appURL.path),
                icon: icon,
                isDefault: isDefault
            )
        }

        var result: [OpenWithCandidate] = []
        if let defaultApp,
           let match = apps.first(where: { $0.standardizedFileURL == defaultApp.standardizedFileURL }) {
            result.append(candidate(match, isDefault: true))
            apps.removeAll { $0.standardizedFileURL == defaultApp.standardizedFileURL }
        }
        result += apps
            .map { candidate($0, isDefault: false) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        openWithCache[key] = result
        return result
    }

    func openCurrentImage(with appURL: URL) {
        guard let url = currentURL else { return }
        NSWorkspace.shared.open([url], withApplicationAt: appURL,
                                configuration: NSWorkspace.OpenConfiguration())
    }

    private var sharingPicker: NSSharingServicePicker?

    /// Share picker anchored at the center of the image window (used from the
    /// menu bar; the canvas has its own mouse-anchored variant).
    func showSharePicker() {
        guard let url = currentURL,
              let view = (NSApp.keyWindow ?? NSApp.windows.first)?.contentView
        else { return }
        let picker = NSSharingServicePicker(items: [url])
        sharingPicker = picker // keep alive while the popover is up
        picker.show(relativeTo: NSRect(x: view.bounds.midX, y: view.bounds.midY, width: 1, height: 1),
                    of: view, preferredEdge: .minY)
    }

    func showOpenPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        if panel.runModal() == .OK, let url = panel.url {
            open(url: url)
        }
    }

    // MARK: - Loading

    private func load() {
        let url = siblings[index]
        currentURL = url
        fullResURL = nil
        image = displayImage(for: url)
        title = "\(url.lastPathComponent) (\(index + 1)/\(siblings.count))"
        prefetchNeighbors()
    }

    private func displayImage(for url: URL) -> NSImage? {
        if let cached = cache[url] {
            touch(url)
            return cached
        }
        let decoded = Self.decodeImage(at: url, maxPixel: Self.displayMaxPixel)
        if let decoded {
            insert(url, decoded)
        }
        return decoded
    }

    private func prefetchNeighbors() {
        let maxPixel = Self.displayMaxPixel
        for delta in [1, -1, 2, -2] {
            guard let neighborIndex = index(offsetBy: delta) else { continue }
            let url = siblings[neighborIndex]
            guard cache[url] == nil, !prefetching.contains(url) else { continue }
            prefetching.insert(url)
            Task.detached(priority: .userInitiated) {
                let decoded = Self.decodeImage(at: url, maxPixel: maxPixel)
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.prefetching.remove(url)
                    if let decoded, self.cache[url] == nil {
                        self.insert(url, decoded)
                    }
                }
            }
        }
    }

    private func ensureFullResolution() {
        guard let url = currentURL, fullResURL != url, fullResInflight != url else { return }
        // Skip when the original has no more pixels than the display version.
        if let current = image, max(current.size.width, current.size.height) < Self.displayMaxPixel - 1 {
            return
        }
        fullResInflight = url
        Task.detached(priority: .userInitiated) {
            let decoded = Self.decodeImage(at: url, maxPixel: nil)
            await MainActor.run { [weak self] in
                guard let self else { return }
                if self.fullResInflight == url {
                    self.fullResInflight = nil
                }
                guard let decoded, self.currentURL == url else { return }
                self.fullResURL = url
                self.image = decoded
            }
        }
    }

    /// Decode fully into memory (no lazy decode at draw time), downsampled to
    /// `maxPixel` on the long side, or at original size when `maxPixel` is nil.
    /// The thumbnail API also applies EXIF rotation.
    nonisolated private static func decodeImage(at url: URL, maxPixel: CGFloat?) -> NSImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            return NSImage(contentsOf: url)
        }
        var pixelLimit = maxPixel
        if pixelLimit == nil,
           let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
           let width = props[kCGImagePropertyPixelWidth] as? CGFloat,
           let height = props[kCGImagePropertyPixelHeight] as? CGFloat {
            pixelLimit = max(width, height)
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: pixelLimit ?? 20000,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return NSImage(contentsOf: url)
        }
        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }

    // MARK: - LRU cache

    private func insert(_ url: URL, _ image: NSImage) {
        cache[url] = image
        cacheOrder.removeAll { $0 == url }
        cacheOrder.append(url)
        while cacheOrder.count > cacheLimit {
            cache[cacheOrder.removeFirst()] = nil
        }
    }

    private func touch(_ url: URL) {
        cacheOrder.removeAll { $0 == url }
        cacheOrder.append(url)
    }
}
