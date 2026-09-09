//
//  SiivApp.swift
//  Siiv
//

import SwiftUI

@main
struct SiivApp: App {
    @StateObject private var model = ViewerModel.shared
    @StateObject private var settings = AppSettings.shared

    var body: some Scene {
        Window("Siiv", id: "main") {
            ContentView()
                .environmentObject(model)
                .environmentObject(settings)
                .onOpenURL { url in
                    model.open(url: url)
                }
        }
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open…") {
                    model.showOpenPanel()
                }
                .keyboardShortcut("o")

                Menu("Open With") {
                    ForEach(model.openWithCandidates()) { candidate in
                        Button {
                            model.openCurrentImage(with: candidate.appURL)
                        } label: {
                            Label {
                                Text(candidate.isDefault ? "\(candidate.name) (default)" : candidate.name)
                            } icon: {
                                Image(nsImage: candidate.icon)
                            }
                        }
                        if candidate.isDefault {
                            Divider()
                        }
                    }
                }
                .disabled(model.currentURL == nil)

                Divider()

                Button("Share…") {
                    model.showSharePicker()
                }
                .disabled(model.currentURL == nil)

                Divider()

                Button("Move to Bin") {
                    model.deleteCurrentImage()
                }
                .keyboardShortcut(.delete, modifiers: .command)
                .disabled(!model.canDelete)
            }
        }

        Settings {
            SettingsView()
                .environmentObject(settings)
        }
    }
}
