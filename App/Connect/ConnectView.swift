import ClementineKit
import SwiftUI

/// The connect screen: Clementine's hero, the Clementines found on the network, and an address
/// to connect to by hand. While connecting, it shows how far along it is.
struct ConnectView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase
    @State private var browser = ServiceBrowser()
    @State private var host = ""
    @State private var authCode = ""
    @State private var isSettingsPresented = false
    @State private var isWelcomePresented = false
    @State private var triedAutoConnect = false
    @FocusState private var isHostFocused: Bool

    var body: some View {
        GeometryReader { geometry in
            let landscape = geometry.size.width > geometry.size.height
            Group {
                if landscape {
                    HStack(spacing: 0) {
                        Header(iconSize: 168, fill: true, topInset: geometry.safeAreaInsets.top, onSettings: showSettings)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        ScrollView {
                            content
                        }
                        .frame(maxWidth: .infinity)
                    }
                } else {
                    ScrollView {
                        VStack(spacing: 0) {
                            Header(
                                iconSize: min(168, max(96, geometry.size.height - 600)),
                                fill: false,
                                topInset: geometry.safeAreaInsets.top,
                                onSettings: showSettings)
                            content
                        }
                    }
                    .ignoresSafeArea(edges: .top)
                    .scrollBounceBehavior(.basedOnSize)
                }
            }
        }
        .background(Palette.surface)
        .onAppear(perform: appeared)
        .onDisappear { browser.stop() }
        .onChange(of: scenePhase) { _, phase in
            // iOS may have stopped the search while the app was in the background.
            if phase == .active {
                browser.start()
            }
        }
        .sheet(isPresented: $isSettingsPresented, onDismiss: { triedAutoConnect = true }) {
            NavigationStack {
                SettingsView()
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done", systemImage: "checkmark") { isSettingsPresented = false }
                        }
                    }
            }
        }
        .alert("Welcome", isPresented: $isWelcomePresented) {
            Button("Continue") {}
        } message: {
            Text("Clementine Remote controls the Clementine music player on your computer. You need Clementine \(Self.clementineVersion) or later, from clementine-player.org.")
        }
        .alert(problemTitle, isPresented: problemPresented, presenting: model.connectProblem) { problem in
            if problem == .authCode {
                TextField("Auth code", text: $authCode)
                    .keyboardType(.numberPad)
                Button("Cancel", role: .cancel) {}
                Button("Connect") {
                    if let code = Int32(authCode) {
                        model.connect(authCode: code)
                    } else {
                        model.toasts.show("That isn't a valid code")
                    }
                }
            } else {
                Button("OK") {}
            }
        } message: { problem in
            Text(problemMessage(problem))
        }
    }

    static let clementineVersion = "1.3"

    private var content: some View {
        let session = model.session
        let connecting = session.status.isConnecting
        return VStack(alignment: .leading, spacing: Metrics.space4) {
            Text("Pick the Clementine you want to control. It needs to be on the same Wi-Fi as this phone.")
                .textStyle(.bodyLarge)
                .foregroundStyle(Palette.onSurfaceVariant)
                .padding(.horizontal, Metrics.space2)

            VStack(alignment: .leading, spacing: Metrics.space1) {
                HStack {
                    SectionTitle("On your network")
                    Spacer()
                    Button("Search again", systemImage: "arrow.clockwise") {
                        browser.start()
                    }
                    .labelStyle(.iconOnly)
                    .foregroundStyle(Palette.onSurfaceVariant)
                    .frame(minWidth: 44, minHeight: 44)
                    .disabled(connecting)
                }
                .padding(.leading, Metrics.space2)

                VStack(spacing: 0) {
                    if browser.servers.isEmpty {
                        Searching()
                    } else {
                        ForEach(browser.servers) { server in
                            ServerRow(server: server) {
                                host = server.host
                                model.connect(host: server.host, port: server.port, name: server.name)
                            }
                            .disabled(connecting)
                        }
                    }
                }
                .background(Palette.surfaceContainerLow, in: .rect(cornerRadius: Metrics.shapeMedium))
            }

            VStack(alignment: .leading, spacing: Metrics.space2) {
                SectionTitle("Or enter its address")
                HStack(spacing: Metrics.space3) {
                    TextField("Address", text: $host, prompt: Text(verbatim: "192.168.1.20"))
                        .textContentType(.URL)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.go)
                        .focused($isHostFocused)
                        .onSubmit(connect)
                        .padding(.horizontal, Metrics.space4)
                        .frame(minHeight: 52)
                        .overlay {
                            RoundedRectangle(cornerRadius: 4)
                                .strokeBorder(isHostFocused ? Palette.primary : Palette.outline, lineWidth: isHostFocused ? 2 : 1)
                        }
                        .accessibilityIdentifier("address")
                        .disabled(connecting)
                    Button("Connect", action: connect)
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .disabled(host.trimmingCharacters(in: .whitespaces).isEmpty || connecting)
                        .accessibilityIdentifier("connect")
                }
                if isHostFocused, !connecting {
                    Suggestions(host: host, known: model.settings.knownHosts) { suggestion in
                        host = suggestion
                    }
                }
                if connecting {
                    Connecting(status: session.status) {
                        model.session.disconnect()
                    }
                }
            }
            .padding(.horizontal, Metrics.space2)

            Text("Needs Clementine \(Self.clementineVersion) or later, with Tools → Preferences → Network Remote turned on.")
                .textStyle(.labelMedium)
                .fontWeight(.regular)
                .foregroundStyle(Palette.onSurfaceVariant)
                .padding(Metrics.space2)
        }
        .padding(.horizontal, Metrics.space4)
        .padding(.top, Metrics.space6)
        .padding(.bottom, Metrics.space6)
    }

    private func appeared() {
        browser.start()
        if host.isEmpty {
            host = model.settings.lastHost
        }
        if model.settings.isFirstLaunch {
            model.settings.isFirstLaunch = false
            isWelcomePresented = true
        } else if !triedAutoConnect, model.settings.autoConnect, !host.isEmpty, model.session.status == .disconnected {
            model.connect(host: host)
        }
        triedAutoConnect = true
    }

    private func connect() {
        isHostFocused = false
        model.connect(host: host)
    }

    private func showSettings() {
        isSettingsPresented = true
    }

    private var problemPresented: Binding<Bool> {
        Binding {
            model.connectProblem != nil
        } set: { presented in
            if !presented {
                model.connectProblem = nil
            }
        }
    }

    private var problemTitle: LocalizedStringKey {
        switch model.connectProblem {
        case .authCode: "Auth code"
        case .oldClementine: "Clementine is too old"
        case .lost: "Lost the connection to Clementine"
        case .unreachable, nil: "Couldn't reach Clementine"
        }
    }

    private func problemMessage(_ problem: ConnectProblem) -> LocalizedStringKey {
        switch problem {
        case .authCode:
            "Enter the auth code shown in Clementine's Network Remote settings."
        case .oldClementine:
            "Please update Clementine. You need Clementine \(Self.clementineVersion) or later."
        case .lost:
            "Clementine stopped answering. Check that it's still running, then connect again."
        case .unreachable(.notOnWiFi):
            "This phone isn't on Wi-Fi. Connect to the same network as Clementine. To reach Clementine over the internet, forward its port and turn off \"Use only local IP addresses\" in Clementine's settings."
        case .unreachable(.noPrivateAddress):
            "This phone doesn't have a local network address. Try turning off \"Use only local IP addresses\" in Clementine's settings."
        case .unreachable(nil):
            "Is Clementine running? Is it version \(Self.clementineVersion) or later, with the network remote turned on in its settings? Is the address right?"
        }
    }
}

/// Clementine's mark and name on the brand gradient.
private struct Header: View {
    let iconSize: CGFloat
    let fill: Bool
    let topInset: CGFloat
    let onSettings: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                Button("Settings", systemImage: "gearshape.fill", action: onSettings)
                    .labelStyle(.iconOnly)
                    .font(.title3)
                    .foregroundStyle(Palette.onBrand)
                    .frame(width: 48, height: 48)
                    .accessibilityIdentifier("settings")
            }
            if fill {
                Spacer()
            }
            Image("ClementineMark")
                .resizable()
                .scaledToFit()
                .frame(width: iconSize, height: iconSize)
                .accessibilityHidden(true)
            Text("Clementine Remote")
                .textStyle(.display)
                .foregroundStyle(Palette.onBrand)
                .multilineTextAlignment(.center)
                .padding(.top, Metrics.space3)
                .accessibilityAddTraits(.isHeader)
            if fill {
                Spacer()
            }
        }
        .padding(.horizontal, Metrics.space2)
        .padding(.top, topInset + Metrics.space2)
        .padding(.bottom, 28)
        .frame(maxWidth: .infinity)
        .background(Palette.brandGradient)
    }
}

struct SectionTitle: View {
    let title: LocalizedStringKey

    init(_ title: LocalizedStringKey) {
        self.title = title
    }

    var body: some View {
        Text(title)
            .textStyle(.labelLarge)
            .foregroundStyle(Palette.onSurfaceVariant)
            .accessibilityAddTraits(.isHeader)
    }
}

private struct ServerRow: View {
    let server: DiscoveredServer
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: Metrics.space4) {
                IconTile(systemImage: "desktopcomputer")
                VStack(alignment: .leading, spacing: 2) {
                    Text(server.name)
                        .textStyle(.bodyLarge)
                        .foregroundStyle(Palette.onSurface)
                    Text("\(server.host) · port \(String(server.port))")
                        .textStyle(.bodyMedium)
                        .foregroundStyle(Palette.onSurfaceVariant)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Metrics.space4)
            .padding(.vertical, Metrics.space3)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("server-\(server.name)")
    }
}

private struct Searching: View {
    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.space1) {
            HStack(spacing: Metrics.space3) {
                ProgressView()
                    .controlSize(.small)
                Text("Looking for Clementine…")
                    .textStyle(.bodyLarge)
                    .foregroundStyle(Palette.onSurface)
            }
            Text("Not showing up? Check that its network remote is turned on, or enter its address below.")
                .textStyle(.bodyMedium)
                .foregroundStyle(Palette.onSurfaceVariant)
        }
        .padding(Metrics.space4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("searching")
    }
}

/// Addresses connected to before that match what's typed.
private struct Suggestions: View {
    let host: String
    let known: [String]
    let pick: (String) -> Void

    var body: some View {
        let matches = known.filter { $0 != host && (host.isEmpty || $0.localizedCaseInsensitiveContains(host)) }
        if !matches.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(matches.prefix(5), id: \.self) { suggestion in
                    Button {
                        pick(suggestion)
                    } label: {
                        Label(suggestion, systemImage: "clock.arrow.circlepath")
                            .textStyle(.bodyLarge)
                            .foregroundStyle(Palette.onSurface)
                            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                            .padding(.horizontal, Metrics.space3)
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                }
            }
            .background(Palette.surfaceContainerHigh, in: .rect(cornerRadius: Metrics.shapeSmall))
        }
    }
}

private struct Connecting: View {
    let status: RemoteSession.Status
    let cancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.space2) {
            ProgressView()
                .progressViewStyle(.linear)
            HStack {
                Text(status == .downloadingData ? "Downloading data…" : "Connecting to Clementine…")
                    .textStyle(.bodyMedium)
                    .foregroundStyle(Palette.onSurface)
                Spacer()
                Button("Cancel", action: cancel)
                    .accessibilityIdentifier("cancel")
            }
        }
        .padding(.top, Metrics.space2)
        .accessibilityIdentifier("connecting")
    }
}
