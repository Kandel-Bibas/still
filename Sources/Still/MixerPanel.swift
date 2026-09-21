import AppKit
import SwiftUI

/// Shared metrics so the panel, its rows, and its chrome stay on one grid.
enum PanelMetrics {
    static let width: CGFloat = 320
    /// Inset of the panel's own edges. Rows add `rowInset` on top of it so every
    /// label, icon, and control shares the same left edge.
    static let edgeInset: CGFloat = 12
    static let rowInset: CGFloat = 8
    static let controlColumn: CGFloat = 26
    static let defaultMaxListHeight: CGFloat = 420
}

private struct ListHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

struct MixerPanel: View {
    @Bindable var store: MixerStore
    var maxListHeight: CGFloat = PanelMetrics.defaultMaxListHeight
    var onOpenSettings: () -> Void = {}
    var onQuit: () -> Void = { NSApplication.shared.terminate(nil) }

    @State private var listHeight: CGFloat = 0

    private var visibleApps: [MixerApp] {
        store.apps.filter { store.showAllApps || $0.isActive || $0.isPinned }
    }

    private var favorites: [MixerApp] {
        visibleApps.filter(\.isPinned)
    }

    private var otherApps: [MixerApp] {
        visibleApps.filter { !$0.isPinned }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            separator
            list
            separator
            footer
        }
        .frame(width: PanelMetrics.width)
    }

    private var separator: some View {
        Divider().padding(.horizontal, PanelMetrics.edgeInset)
    }

    /// The list keeps its natural height until it outgrows the space the panel was
    /// given, and only then becomes a scroller of exactly that height. Measuring in
    /// the background means the measurement never depends on the frame it drives.
    @ViewBuilder private var list: some View {
        let measured = content
            .background(
                GeometryReader { proxy in
                    Color.clear.preference(key: ListHeightKey.self, value: proxy.size.height)
                }
            )
            .onPreferenceChange(ListHeightKey.self) { listHeight = $0 }

        if listHeight > maxListHeight {
            ScrollView(.vertical) { measured }
                .frame(height: maxListHeight)
        } else {
            measured
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let error = store.errorMessage {
                errorNotice(error)
            }

            if !store.isEnabled {
                enableNotice
            } else if store.isLoading && store.apps.isEmpty {
                loadingNotice
            } else if visibleApps.isEmpty {
                emptyState
            } else {
                if !favorites.isEmpty {
                    appSection(otherApps.isEmpty ? nil : "Favorites", apps: favorites)
                }
                if !otherApps.isEmpty {
                    appSection(favorites.isEmpty ? nil : "Apps", apps: otherApps)
                }
            }
        }
        .padding(.horizontal, PanelMetrics.edgeInset)
        .padding(.vertical, 8)
        .frame(width: PanelMetrics.width, alignment: .leading)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("Still")
                    .font(.system(size: 13, weight: .semibold))
                Spacer(minLength: 0)
                Toggle(isOn: Binding(get: { store.isEnabled }, set: store.setEnabled)) { EmptyView() }
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .controlSize(.small)
                    .accessibilityLabel("Per-app audio control")
                    .help("Turning off Still restores each app’s original volume and output. Muted apps may become audible.")
            }

            HStack(spacing: 5) {
                Image(systemName: "speaker.wave.2")
                    .font(.system(size: 10))
                    .accessibilityHidden(true)
                Text(store.defaultOutputName)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(store.defaultOutputName)
                Spacer(minLength: 0)
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .accessibilityElement(children: .combine)
        }
        .padding(.horizontal, PanelMetrics.edgeInset + PanelMetrics.rowInset)
        .padding(.top, 11)
        .padding(.bottom, 10)
    }

    private var loadingNotice: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text("Finding audio apps…")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 92)
    }

    private var enableNotice: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("App volume and output")
                .font(.system(size: 13, weight: .semibold))
            Text("Set each app’s volume and choose where it plays. macOS will ask for System Audio Recording access so Still can control your audio.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("Audio stays on this Mac and is never saved.")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Enable Still") { store.setEnabled(true) }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
                .padding(.top, 2)
        }
        .padding(.horizontal, PanelMetrics.rowInset)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var emptyState: some View {
        VStack(spacing: 7) {
            Image(systemName: "waveform")
                .font(.system(size: 22, weight: .light))
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
            Text("No apps playing audio")
                .font(.system(size: 12, weight: .medium))
            Text("Play something and its volume controls appear here.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if !store.showAllApps {
                Button("Show inactive apps") { store.showAllApps = true }
                    .buttonStyle(.link)
                    .font(.system(size: 11))
                    .padding(.top, 1)
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 18)
        .frame(maxWidth: .infinity)
    }

    private func appSection(_ title: String?, apps: [MixerApp]) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            if let title {
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, PanelMetrics.rowInset)
                    .padding(.bottom, 2)
            }
            ForEach(apps) { app in
                MixerAppRow(app: app, store: store)
            }
        }
    }

    private func errorNotice(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11))
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            Text(message)
                .font(.system(size: 11))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button { store.dismissError() } label: {
                Image(systemName: "xmark").font(.system(size: 9, weight: .semibold))
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .accessibilityLabel("Dismiss error")
        }
        .padding(9)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.primary.opacity(0.06))
        )
    }

    private var footer: some View {
        HStack(spacing: 4) {
            Button(action: onOpenSettings) {
                Text("Still Settings…")
            }
            .buttonStyle(PanelRowButtonStyle())
            .keyboardShortcut(",", modifiers: .command)
            .accessibilityLabel("Still settings")
            .help("Settings… (⌘,)")

            Spacer(minLength: 0)

            HoverHighlight {
                Menu {
                    Toggle("Show inactive apps", isOn: $store.showAllApps)
                    Button("Refresh apps", action: store.refresh)
                        .keyboardShortcut("r", modifiers: .command)
                    Divider()
                    Button("Quit Still", action: onQuit)
                        .keyboardShortcut("q", modifiers: .command)
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 12, weight: .semibold))
                        .frame(width: 24, height: 18)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .accessibilityLabel("More options")
            }
        }
        .font(.system(size: 12))
        .padding(.horizontal, PanelMetrics.edgeInset)
        .padding(.vertical, 7)
    }
}

/// Gives a control that cannot take a `ButtonStyle` — a `Menu`, for instance — the
/// same hover highlight as the panel's rows.
struct HoverHighlight<Content: View>: View {
    var cornerRadius: CGFloat = 6
    @ViewBuilder var content: Content
    @State private var isHovering = false

    var body: some View {
        content
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(Color.primary.opacity(isHovering ? 0.07 : 0))
            )
            .onHover { isHovering = $0 }
    }
}

/// A borderless control that picks up the hover and pressed highlight macOS uses
/// for rows inside menu bar panels.
struct PanelRowButtonStyle: ButtonStyle {
    var horizontalPadding: CGFloat = PanelMetrics.rowInset
    var verticalPadding: CGFloat = 4

    func makeBody(configuration: Configuration) -> some View {
        Highlight(configuration: configuration, horizontalPadding: horizontalPadding, verticalPadding: verticalPadding)
    }

    private struct Highlight: View {
        let configuration: PanelRowButtonStyle.Configuration
        let horizontalPadding: CGFloat
        let verticalPadding: CGFloat
        @State private var isHovering = false

        private var fill: Double {
            if configuration.isPressed { return 0.12 }
            return isHovering ? 0.07 : 0
        }

        var body: some View {
            configuration.label
                .padding(.horizontal, horizontalPadding)
                .padding(.vertical, verticalPadding)
                .contentShape(Rectangle())
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.primary.opacity(fill))
                )
                .onHover { isHovering = $0 }
        }
    }
}

private struct MixerAppRow: View {
    let app: MixerApp
    let store: MixerStore
    @State private var isHovering = false

    private var unavailableOutput: Bool {
        guard let uid = app.outputUID else { return false }
        return !store.devices.contains { $0.id == uid }
    }

    private var outputLabel: String {
        guard app.outputUID != nil else { return "System output" }
        return app.outputName ?? "Saved output"
    }

    private var percentText: String {
        "\(Int((app.volume * 100).rounded()))%"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .center, spacing: 10) {
                appIcon
                VStack(alignment: .leading, spacing: 0) {
                    Text(app.name)
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    outputMenu
                }
                Spacer(minLength: 4)
                pinButton
            }

            HStack(spacing: 10) {
                muteButton
                Slider(value: Binding(get: { app.volume }, set: { store.setVolume(app.id, $0) }), in: 0...1)
                    .controlSize(.small)
                    .accessibilityLabel("\(app.name) volume")
                    .accessibilityValue("\(Int((app.volume * 100).rounded())) percent\(app.isMuted ? ", muted" : "")")
                Text(percentText)
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 34, alignment: .trailing)
            }
            .opacity(app.isMuted ? 0.5 : 1)
            .disabled(!store.isEnabled)

            routeStatus
        }
        .padding(.horizontal, PanelMetrics.rowInset)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.primary.opacity(isHovering ? 0.055 : 0))
        )
        .onHover { isHovering = $0 }
    }

    private var appIcon: some View {
        Group {
            if let icon = app.icon {
                Image(nsImage: icon).resizable().scaledToFit()
            } else {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.primary.opacity(0.10))
                    .overlay(
                        Image(systemName: "waveform")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    )
            }
        }
        .frame(width: PanelMetrics.controlColumn, height: PanelMetrics.controlColumn)
        .opacity(app.isActive ? 1 : 0.55)
        .accessibilityHidden(true)
    }

    private var muteButton: some View {
        Button { store.toggleMute(app.id) } label: {
            Image(systemName: app.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                .font(.system(size: 11))
                .frame(width: PanelMetrics.controlColumn, height: 16)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
        .accessibilityLabel("\(app.isMuted ? "Unmute" : "Mute") \(app.name)")
        .help(app.isMuted ? "Unmute" : "Mute")
    }

    private var pinButton: some View {
        Button { store.togglePin(app.id) } label: {
            Image(systemName: app.isPinned ? "pin.fill" : "pin")
                .font(.system(size: 11))
                .frame(width: 18, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .foregroundStyle(app.isPinned ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
        .opacity(app.isPinned || isHovering ? 1 : 0)
        .allowsHitTesting(app.isPinned || isHovering)
        .accessibilityLabel(app.isPinned ? "Unpin \(app.name)" : "Pin \(app.name)")
        .accessibilityHidden(!(app.isPinned || isHovering))
        .help(app.isPinned ? "Remove from Favorites" : "Keep in Favorites")
    }

    private var outputMenu: some View {
        Menu {
            Button { store.setOutput(app.id, nil) } label: {
                Label("System output", systemImage: app.outputUID == nil ? "checkmark" : "speaker.wave.2")
            }
            Divider()
            ForEach(store.devices) { device in
                Button { store.setOutput(app.id, device) } label: {
                    Label(device.name, systemImage: app.outputUID == device.id ? "checkmark" : device.symbol)
                }
            }
            if unavailableOutput {
                Divider()
                Label(outputLabel, systemImage: "checkmark")
            }
        } label: {
            Text(outputLabel)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .controlSize(.small)
        .menuStyle(.borderlessButton)
        .menuIndicator(.visible)
        .fixedSize(horizontal: false, vertical: true)
        .disabled(!store.isEnabled)
        .accessibilityLabel("Output for \(app.name): \(outputLabel)")
        .help("Choose the output for \(app.name)")
    }

    @ViewBuilder private var routeStatus: some View {
        switch app.state {
        case .waiting(let name):
            statusLine("Muted · waiting for \(name)", symbol: "speaker.slash", prominent: true)
        case .failed(let message):
            HStack(alignment: .top, spacing: 8) {
                statusLine(message, symbol: "exclamationmark.triangle", prominent: true)
                Spacer(minLength: 0)
                Button("Retry") { store.retry(app.id) }
                    .controlSize(.small)
                    .font(.system(size: 11))
                    .disabled(!store.isEnabled)
            }
        case .inactive:
            statusLine("Not playing", symbol: nil, prominent: false)
        case .direct, .managed:
            EmptyView()
        }
    }

    @ViewBuilder private func statusLine(_ text: String, symbol: String?, prominent: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            if let symbol {
                Image(systemName: symbol)
                    .font(.system(size: 9))
                    .accessibilityHidden(true)
            }
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.system(size: 11))
        .foregroundStyle(prominent ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tertiary))
        .padding(.leading, PanelMetrics.controlColumn + 10)
        .accessibilityElement(children: .combine)
    }
}
