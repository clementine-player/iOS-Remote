import ClementineKit
import SwiftUI

/// Chooses where Clementine plays. It shows the device's icon, in the accent colour, when
/// Clementine plays somewhere other than its own computer.
struct OutputButton: View {
    @Environment(RemoteSession.self) private var session
    var size: CGFloat = 48
    let action: () -> Void

    var body: some View {
        let elsewhere = session.activeOutput.flatMap { $0.isLocal ? nil : $0 }
        Button(action: action) {
            Image(systemName: elsewhere.map { OutputRow.icon(for: $0, session: session) } ?? "laptopcomputer.and.iphone")
                .font(size < 48 ? .body : .title3)
                .foregroundStyle(elsewhere == nil ? Palette.onSurfaceVariant : Palette.primary)
                .frame(width: size, height: size)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(elsewhere.map { Text("Playing on \(OutputRow.name(of: $0, session: session))") }
            ?? Text("Choose where to play"))
        .accessibilityIdentifier("outputs")
    }
}

/// Where Clementine can play: its own computer, this phone, or another device (remote streaming).
/// Picking one plays there.
struct OutputSheet: View {
    @Environment(RemoteSession.self) private var session
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(session.outputs) { output in
                        OutputRow(output: output) {
                            session.setOutput(output.id)
                            dismiss()
                        }
                    }
                } footer: {
                    Text("Clementine plays on its computer, or sends its music to a device that's connected to it.")
                }
            }
            .scrollContentBackground(.hidden)
            .navigationTitle("Play on")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", systemImage: "checkmark") { dismiss() }
                        .filledButtonTint()
                }
            }
        }
    }
}

struct OutputRow: View {
    @Environment(RemoteSession.self) private var session
    let output: Output
    let pick: () -> Void

    var body: some View {
        Button(action: pick) {
            HStack(spacing: Metrics.space4) {
                IconTile(systemImage: Self.icon(for: output, session: session))
                VStack(alignment: .leading, spacing: 2) {
                    Text(Self.name(of: output, session: session))
                        .textStyle(.bodyLarge)
                        .foregroundStyle(Palette.onSurface)
                    if output.state == .activating {
                        Text("Switching…")
                            .textStyle(.bodyMedium)
                            .foregroundStyle(Palette.onSurfaceVariant)
                    }
                }
                Spacer(minLength: 0)
                if output.state == .active {
                    Image(systemName: "checkmark")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(Palette.primary)
                }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(output.state == .active ? .isSelected : [])
        .accessibilityIdentifier("output-\(output.id)")
    }

    /// Clementine's computer by the name Clementine gives it, or "Clementine" when it doesn't say;
    /// this device marked as such, and others as Clementine names them.
    static func name(of output: Output, session: RemoteSession) -> String {
        if output.isLocal {
            return output.name.isEmpty ? "Clementine" : output.name
        }
        if isThisDevice(output, session: session) {
            return UIDevice.current.userInterfaceIdiom == .pad
                ? String(localized: "\(output.name) (this iPad)")
                : String(localized: "\(output.name) (this phone)")
        }
        return output.name
    }

    /// Clementine doesn't say what the other devices are, so they show as speakers.
    static func icon(for output: Output, session: RemoteSession) -> String {
        if output.isLocal {
            return "desktopcomputer"
        }
        if isThisDevice(output, session: session) {
            return UIDevice.current.userInterfaceIdiom == .pad ? "ipad" : "iphone"
        }
        return "hifispeaker"
    }

    private static func isThisDevice(_ output: Output, session: RemoteSession) -> Bool {
        session.renderer?.rendererID == output.id
    }
}
