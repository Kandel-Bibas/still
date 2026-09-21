import AppKit
import SwiftUI

struct SettingsView: View {
    @Bindable var store: MixerStore

    var body: some View {
        Form {
            Section {
                Toggle("Enable per-app audio control", isOn: Binding(get: { store.isEnabled }, set: store.setEnabled))
                Toggle("Open Still at login", isOn: Binding(get: { store.launchAtLogin }, set: store.setLaunchAtLogin))
                Toggle("Show inactive apps", isOn: $store.showAllApps)
            } header: {
                Text("General")
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Pin an app to keep it in Favorites. Still remembers its volume, mute setting, and output for the next time it opens.")
                    Text("Turning off or quitting Still restores each app’s original volume and output. Apps muted by Still may become audible.")
                }
            }

            Section {
                LabeledContent("Current system output", value: store.defaultOutputName)
            } header: {
                Text("Audio outputs")
            } footer: {
                Text("Apps set to System output follow your Mac’s selected output. If an app’s chosen device disconnects, Still keeps that app muted until the device reconnects or you choose another output.")
            }

            Section {
                VStack(alignment: .leading, spacing: 10) {
                    Text("System Audio Recording access")
                    Text("Still needs macOS permission to adjust and route each app’s audio. Audio is processed on this Mac and is never saved or sent anywhere.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Open Privacy & Security…") {
                        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") else { return }
                        NSWorkspace.shared.open(url)
                    }
                    Text("In System Settings, allow Still under Screen & System Audio Recording. On some macOS versions this is called Screen Recording. If macOS asks you to quit and reopen Still, do so before enabling the mixer.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, 4)
            } header: {
                Text("Privacy")
            }

            if let error = store.errorMessage {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.callout)
                    Button("Dismiss", action: store.dismissError)
                } header: {
                    Text("Needs attention")
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 480, height: 550)
    }
}
