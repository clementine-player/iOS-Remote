import ClementineKit
import SwiftUI

/// Where to add songs.
enum PlaylistTarget: Equatable {
    /// The playlist selected in the queue.
    case selected
    case existing(Playlist)
    /// A playlist to create, with this name.
    case new(String)
}

extension AppModel {
    /// The playlist [target] means, creating it first if it's new. Nil if it couldn't be created.
    func playlist(for target: PlaylistTarget) async -> Playlist? {
        switch target {
        case .selected:
            return selectedPlaylist
        case .existing(let playlist):
            return playlist
        case .new(let name):
            guard let created = await session.createPlaylist(named: name) else {
                toasts.show("Couldn't create the playlist. Creating playlists needs Clementine 1.4 or later.")
                return nil
            }
            return created
        }
    }

    /// Says that [count] songs were added to [playlist].
    func showAdded(_ count: Int, to playlist: Playlist) {
        toasts.show("\(count) songs added to \(playlist.name)")
    }
}

/// "Add to playlist": a tap adds to the playlist selected in the queue; the menu picks another, or a new one.
struct AddToPlaylistMenu: View {
    enum Style {
        /// The prominent button of an opened group's header.
        case prominent
        /// An icon, in a toolbar.
        case icon
    }

    var style = Style.icon
    let add: (PlaylistTarget) -> Void

    @Environment(AppModel.self) private var model
    @Environment(RemoteSession.self) private var session
    @State private var isNaming = false

    var body: some View {
        Menu {
            let selected = model.selectedPlaylist
            if let selected {
                Button(selected.name, systemImage: "checkmark") { add(.selected) }
            }
            ForEach(session.playlists.filter { $0.id != selected?.id }) { playlist in
                if playlist.id == session.activePlaylistID {
                    Button("\(playlist.name) (playing)", systemImage: "waveform") { add(.existing(playlist)) }
                } else {
                    Button(playlist.name, systemImage: "list.bullet") { add(.existing(playlist)) }
                }
            }
            Divider()
            Button("New playlist…", systemImage: "plus") { isNaming = true }
        } label: {
            Label("Add to playlist", systemImage: "plus")
        } primaryAction: {
            add(.selected)
        }
        .modifier(AddButtonStyle(style: style))
        .accessibilityHint("Adds to the playlist selected in the queue. Touch and hold to pick another.")
        .newPlaylistAlert(isPresented: $isNaming) { name in
            add(.new(name))
        }
    }
}

private struct AddButtonStyle: ViewModifier {
    let style: AddToPlaylistMenu.Style

    func body(content: Content) -> some View {
        switch style {
        case .prominent:
            content
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("addAll")
        case .icon:
            content
        }
    }
}

private struct NewPlaylistAlert: ViewModifier {
    @Binding var isPresented: Bool
    let create: (String) -> Void
    @State private var name = ""

    func body(content: Content) -> some View {
        content.alert("New playlist", isPresented: $isPresented) {
            TextField("Name", text: $name)
            Button("Cancel", role: .cancel) { name = "" }
            Button("Create") {
                let trimmed = name.trimmingCharacters(in: .whitespaces)
                name = ""
                if !trimmed.isEmpty {
                    create(trimmed)
                }
            }
        } message: {
            Text("Clementine creates the playlist and shows it.")
        }
    }
}

extension View {
    /// Asks for a new playlist's name, then calls [create] with it.
    func newPlaylistAlert(isPresented: Binding<Bool>, create: @escaping (String) -> Void) -> some View {
        modifier(NewPlaylistAlert(isPresented: isPresented, create: create))
    }
}
