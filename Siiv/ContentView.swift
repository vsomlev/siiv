//
//  ContentView.swift
//  Siiv
//

import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var model: ViewerModel
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        Group {
            if model.image != nil {
                ImageCanvas(
                    image: model.image,
                    imageID: model.currentURL,
                    instantArrowSwitching: settings.instantArrowSwitching,
                    onNavigate: { model.navigate(by: $0) },
                    onDelete: { model.deleteCurrentImage() },
                    onJump: { target in
                        switch target {
                        case .first: model.goToFirst()
                        case .last: model.goToLast()
                        }
                    },
                    wrapNotice: model.wrapNotice,
                    neighborProvider: { model.peekImage(delta: $0) },
                    onZoomChanged: { model.zoomChanged($0) }
                )
            } else {
                ContentUnavailableView {
                    Label("No Image", systemImage: "photo")
                } description: {
                    Text("Open an image from Finder or press ⌘O.")
                }
            }
        }
        .frame(minWidth: 400, minHeight: 300)
        .navigationTitle(model.title)
        .modifier(DocumentProxyIcon(url: model.currentURL))
        .background(WindowAccessor())
        .onChange(of: model.currentURL) {
            WindowSizer.shared.imageChanged(size: model.image?.size)
        }
    }
}

/// Puts the file's proxy icon in the title bar, so it can be cmd-clicked for
/// the path or dragged elsewhere. Nothing open means no icon: an empty URL
/// would otherwise stand for the root of the disk.
private struct DocumentProxyIcon: ViewModifier {
    let url: URL?

    func body(content: Content) -> some View {
        if let url {
            content.navigationDocument(url)
        } else {
            content
        }
    }
}

#Preview {
    ContentView()
        .environmentObject(ViewerModel.shared)
        .environmentObject(AppSettings.shared)
}
