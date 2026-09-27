import ClementineKit
import SwiftUI

/// The Clementine being controlled: where it is, since when, its version and traffic, and the
/// ways out: another Clementine, the settings, or disconnecting.
struct ConnectionSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(RemoteSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var traffic = ""

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(spacing: Metrics.space4) {
                        IconTile(systemImage: "desktopcomputer", size: 56)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Clementine on \(session.hostName)")
                                .textStyle(.titleLarge)
                                .foregroundStyle(Palette.onSurface)
                                .lineLimit(2)
                            Label(
                                session.status == .connected ? "Connected" : "Reconnecting…",
                                systemImage: session.status == .connected ? "checkmark.circle.fill" : "wifi.exclamationmark")
                                .textStyle(.labelLarge)
                                .foregroundStyle(session.status == .connected ? Palette.primary : Palette.error)
                        }
                    }
                    .listRowBackground(Color.clear)
                }

                Section {
                    if let endpoint = session.endpoint {
                        LabeledContent("Address", value: "\(endpoint.host) · port \(String(endpoint.port))")
                    }
                    if !session.clementineVersion.isEmpty {
                        LabeledContent("Version", value: session.clementineVersion)
                    }
                    if let since = session.connectedSince {
                        TimelineView(.periodic(from: since, by: 1)) { context in
                            LabeledContent("Connected for", value: uptime(since: since, now: context.date))
                        }
                    }
                    LabeledContent("Data sent / received", value: traffic)
                }

                Section {
                    Button("Switch Clementine", systemImage: "desktopcomputer") {
                        model.session.disconnect()
                    }
                    NavigationLink {
                        SettingsView()
                    } label: {
                        Label("Settings", systemImage: "gearshape")
                    }
                    Button("Disconnect", systemImage: "rectangle.portrait.and.arrow.right", role: .destructive) {
                        model.session.disconnect()
                    }
                    .accessibilityIdentifier("disconnect")
                }
            }
            .scrollContentBackground(.hidden)
            .navigationTitle("Clementine")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", systemImage: "checkmark") { dismiss() }
                        .filledButtonTint()
                }
            }
            .task {
                while !Task.isCancelled {
                    await updateTraffic()
                    try? await Task.sleep(for: .milliseconds(500))
                }
            }
        }
    }

    private func uptime(since: Date, now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(since)))
        return String(format: "%02d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60)
    }

    private func updateTraffic() async {
        let bytes = await session.byteCounts()
        let seconds = max(1, Int(Date.now.timeIntervalSince(session.connectedSince ?? .now)))
        let rate = Int64(bytes.sent + bytes.received) / Int64(seconds)
        traffic = "\(formatBytes(Int64(bytes.sent))) / \(formatBytes(Int64(bytes.received))) (\(formatBytes(rate))/s)"
    }
}
