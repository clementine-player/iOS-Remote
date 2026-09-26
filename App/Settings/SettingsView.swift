import ClementineKit
import SwiftUI

/// The app's settings, from the connect screen or the connection sheet.
struct SettingsView: View {
    @AppStorage(SettingKey.volumeButtons) private var volumeButtons = true
    @AppStorage(SettingKey.volumeStep) private var volumeStep = 10
    @AppStorage(SettingKey.showLastFM) private var showLastFM = true
    @AppStorage(SettingKey.libraryGrouping) private var grouping = LibraryGrouping.artistAlbum.rawValue
    @AppStorage(SettingKey.librarySorting) private var sorting = LibrarySorting.ascending.rawValue
    @AppStorage(SettingKey.wifiOnly) private var wifiOnly = false
    @AppStorage(SettingKey.replaceExisting) private var replaceExisting = false
    @AppStorage(SettingKey.playlistFolder) private var playlistFolder = false
    @AppStorage(SettingKey.artistFolder) private var artistFolder = true
    @AppStorage(SettingKey.albumFolder) private var albumFolder = true
    @AppStorage(SettingKey.autoConnect) private var autoConnect = false
    @AppStorage(SettingKey.port) private var port = Int(RemoteProtocol.defaultPort)
    @AppStorage(SettingKey.keepScreenOn) private var keepScreenOn = false

    var body: some View {
        Form {
            Section("Player") {
                Toggle(isOn: $volumeButtons) {
                    Text("Volume buttons control Clementine")
                    Text("The phone's volume buttons change Clementine's volume while the app is open.")
                }
                Picker("Volume step", selection: $volumeStep) {
                    ForEach(1...20, id: \.self) { step in
                        Text("\(step)%").tag(step)
                    }
                }
                Toggle(isOn: $showLastFM) {
                    Text("Last.fm")
                    Text("Show buttons to love and ban songs.")
                }
            }

            Section("Library") {
                Picker("Grouping", selection: $grouping) {
                    ForEach(LibraryGrouping.allCases, id: \.rawValue) { grouping in
                        Text(grouping.title).tag(grouping.rawValue)
                    }
                }
                Picker("Sorting", selection: $sorting) {
                    Text("Ascending").tag(LibrarySorting.ascending.rawValue)
                    Text("Descending").tag(LibrarySorting.descending.rawValue)
                }
            }

            Section {
                Toggle(isOn: $wifiOnly) {
                    Text("Only on Wi-Fi")
                    Text("Download songs only when connected to Wi-Fi.")
                }
                Toggle("Replace existing files", isOn: $replaceExisting)
                Toggle(isOn: $playlistFolder) {
                    Text("Playlist folder")
                    Text("Save a playlist's songs in a folder named after it.")
                }
                Toggle(isOn: $artistFolder) {
                    Text("Artist folders")
                    Text("Save each song in a folder named after its artist.")
                }
                Toggle(isOn: $albumFolder) {
                    Text("Album folders")
                    Text("Inside the artist's folder, save each song in a folder named after its album.")
                }
                .disabled(!artistFolder)
            } header: {
                Text("Downloads")
            } footer: {
                Text("Songs are saved in Clementine Remote's folder, in the Files app.")
            }

            Section("Connection") {
                Toggle(isOn: $autoConnect) {
                    Text("Connect automatically")
                    Text("Connect to the last Clementine when the app starts.")
                }
                LabeledContent("Port") {
                    TextField("Port", value: $port, format: .number.grouping(.never))
                        .keyboardType(.numberPad)
                        .multilineTextAlignment(.trailing)
                        .onChange(of: port) { _, value in
                            if !(1...65535).contains(value) {
                                port = Int(RemoteProtocol.defaultPort)
                            }
                        }
                }
            }

            Section("Advanced") {
                Toggle(isOn: $keepScreenOn) {
                    Text("Keep the screen on")
                    Text("While connected to Clementine.")
                }
            }

            Section("About") {
                NavigationLink("About Clementine Remote") {
                    AboutView()
                }
                Link(destination: URL(string: "https://www.clementine-player.org/")!) {
                    LabeledContent("Clementine", value: "clementine-player.org")
                }
            }
        }
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .scrollContentBackground(.hidden)
        .background(Palette.surface)
    }
}

extension LibraryGrouping {
    var title: LocalizedStringResource {
        switch self {
        case .artist: "Artist"
        case .artistAlbum: "Artist / Album"
        case .albumArtistAlbum: "Album artist / Album"
        case .artistYear: "Artist / Year"
        case .album: "Album"
        case .genreAlbum: "Genre / Album"
        case .genreArtistAlbum: "Genre / Artist / Album"
        }
    }
}

struct AboutView: View {
    private var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? ""
        let build = info?["CFBundleVersion"] as? String ?? ""
        return "\(short) (\(build))"
    }

    var body: some View {
        List {
            Section {
                VStack(spacing: Metrics.space3) {
                    Image("ClementineMark")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 96, height: 96)
                        .accessibilityHidden(true)
                    Text("Clementine Remote")
                        .textStyle(.titleLarge)
                    Text("Version \(version)")
                        .textStyle(.bodyMedium)
                        .foregroundStyle(Palette.onSurfaceVariant)
                    Text("Clementine Remote controls the Clementine music player on your computer. It collects no data: it only talks to your own Clementine, on your own network.")
                        .textStyle(.bodyMedium)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(Palette.onSurfaceVariant)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, Metrics.space2)
            }

            Section("Authors") {
                Text(verbatim: "Andreas Muttscheller")
                Text("David Sansome (Clementine)")
                Text("John Maguire (Clementine)")
                Text("Arnaud Bienner (Clementine)")
                Link("And everyone who contributed to and translated the Android remote",
                     destination: URL(string: "https://github.com/clementine-player/Android-Remote/graphs/contributors")!)
            }

            Section {
                Link(destination: URL(string: "https://www.gnu.org/licenses/gpl-3.0.html")!) {
                    LabeledContent("Licence", value: "GNU GPL v3")
                }
                NavigationLink("Open-source software") {
                    List {
                        Section {
                            Text(verbatim: "SwiftProtobuf")
                                .textStyle(.bodyLarge)
                            Text("Copyright Apple Inc. and the SwiftProtobuf project authors. Licensed under the Apache License, Version 2.0.")
                                .textStyle(.bodyMedium)
                                .foregroundStyle(Palette.onSurfaceVariant)
                        }
                        Section {
                            Text("Clementine's remote control protocol")
                                .textStyle(.bodyLarge)
                            Text("Copyright David Sansome and Andreas Muttscheller. Licensed under the Apache License, Version 2.0.")
                                .textStyle(.bodyMedium)
                                .foregroundStyle(Palette.onSurfaceVariant)
                        }
                    }
                    .navigationTitle("Open-source software")
                }
            } footer: {
                Text("This program is distributed in the hope that it will be useful, but without any warranty.")
            }
        }
        .navigationTitle("About")
        .navigationBarTitleDisplayMode(.inline)
    }
}
