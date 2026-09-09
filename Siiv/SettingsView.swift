//
//  SettingsView.swift
//  Siiv
//

import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        Form {
            Section("Navigation") {
                Toggle("Arrow keys switch images instantly",
                       isOn: $settings.instantArrowSwitching)
                Text("Trackpad swipes always slide between images.")
                    .font(.callout)
                    .foregroundStyle(.secondary)

                Toggle("Wrap around at the first and last image",
                       isOn: $settings.wrapAround)
            }

            Section("Deleting") {
                Toggle("Ask before moving an image to the Bin",
                       isOn: $settings.confirmBeforeDelete)
            }

            Section("Window") {
                Picker("Window size:", selection: $settings.windowSizeMode) {
                    ForEach(WindowSizeMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                Text(settings.windowSizeMode.detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)

                Toggle("Resize window to fit each image",
                       isOn: $settings.resizeWindowPerImage)
                    .disabled(!settings.windowSizeMode.followsImage)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
    }
}

#Preview {
    SettingsView()
        .environmentObject(AppSettings.shared)
}
