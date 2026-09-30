import ClementineKit
import SwiftUI

/// Everything Clementine says about the song playing, its rating, and its lyrics.
struct SongDetailsView: View {
    enum Page: Hashable {
        case details, lyrics
    }

    @Binding var page: Page
    @Environment(AppModel.self) private var model
    @Environment(RemoteSession.self) private var session
    @AppStorage(SettingKey.showLastFM) private var showLastFM = true
    @State private var isCoverZoomed = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Metrics.space4) {
                header
                Picker("Show", selection: $page) {
                    Text("Details").tag(Page.details)
                    Text("Lyrics").tag(Page.lyrics)
                }
                .pickerStyle(.segmented)
                if let song = session.song {
                    switch page {
                    case .details:
                        details(song)
                    case .lyrics:
                        LyricsView()
                    }
                }
            }
            .padding(.horizontal, Metrics.space6)
            .padding(.top, Metrics.space6)
            .padding(.bottom, Metrics.space6)
        }
        .toasts(model.toasts)
        .fullScreenCover(isPresented: $isCoverZoomed) {
            ZoomedCover(artData: session.song?.artData)
        }
    }

    private var header: some View {
        HStack(spacing: Metrics.space4) {
            Button {
                if session.song?.artData != nil {
                    isCoverZoomed = true
                }
            } label: {
                Artwork(song: session.song, cornerRadius: Metrics.shapeLarge)
                    .frame(width: 72, height: 72)
            }
            .buttonStyle(.plain)
            .accessibilityHint("Shows the cover full size")
            VStack(alignment: .leading, spacing: 2) {
                Text(session.song?.title ?? String(localized: "No song playing"))
                    .textStyle(.titleLarge)
                    .foregroundStyle(Palette.onSurface)
                    .lineLimit(2)
                if let song = session.song {
                    Text([song.artist, song.album].filter { !$0.isEmpty }.joined(separator: " · "))
                        .textStyle(.bodyMedium)
                        .foregroundStyle(Palette.onSurfaceVariant)
                        .lineLimit(1)
                }
            }
        }
    }

    @ViewBuilder
    private func details(_ song: Song) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            DetailRow(label: "Album", value: song.album)
            DetailRow(label: "Genre", value: song.genre)
            DetailRow(label: "Year", value: song.year)
            DetailRow(label: "Track", value: song.track > 0 ? String(song.track) : "")
            DetailRow(label: "Disc", value: song.disc > 0 ? String(song.disc) : "")
            DetailRow(label: "Length", value: song.prettyLength)
            DetailRow(label: "Play count", value: String(song.playCount))
            DetailRow(label: "Size", value: song.size > 0 ? formatBytes(song.size) : "")
            DetailRow(label: "File", value: song.filename)
        }

        HStack(spacing: 0) {
            Text("Rating")
                .textStyle(.bodyMedium)
                .foregroundStyle(Palette.onSurfaceVariant)
                .frame(width: 96, alignment: .leading)
            Rating(stars: song.rating * 5) { stars in
                session.rate(stars: stars)
                model.toasts.show("Rated \(stars) stars")
            }
        }

        if showLastFM {
            HStack(spacing: Metrics.space3) {
                Button {
                    session.love()
                    model.toasts.show("Loved on Last.fm")
                } label: {
                    Label("Love", systemImage: session.isLoved ? "heart.fill" : "heart")
                }
                .disabled(session.isLoved)
                Button {
                    session.ban()
                    model.toasts.show("Banned on Last.fm")
                } label: {
                    Label("Ban", systemImage: "hand.thumbsdown")
                }
            }
            .buttonStyle(.bordered)
        }
    }
}

private struct DetailRow: View {
    let label: LocalizedStringResource
    let value: String

    var body: some View {
        if !value.isEmpty {
            HStack(alignment: .firstTextBaseline, spacing: Metrics.space4) {
                Text(label)
                    .textStyle(.bodyMedium)
                    .foregroundStyle(Palette.onSurfaceVariant)
                    .frame(width: 96, alignment: .leading)
                Text(value)
                    .textStyle(.bodyLarge)
                    .foregroundStyle(Palette.onSurface)
                    .lineLimit(2)
                    .textSelection(.enabled)
                Spacer(minLength: 0)
            }
            .padding(.vertical, 10)
            .overlay(alignment: .bottom) {
                Rectangle().fill(Palette.outlineVariant).frame(height: 1)
            }
            .accessibilityElement(children: .combine)
        }
    }
}

/// Clementine's rating in half stars. Tapping a star rates the song that many stars.
private struct Rating: View {
    let stars: Float
    let rate: (Int) -> Void

    var body: some View {
        HStack(spacing: 0) {
            ForEach(1...5, id: \.self) { star in
                Button {
                    rate(star)
                } label: {
                    Image(systemName: symbol(star))
                        .font(.title3)
                        .foregroundStyle(Palette.primary)
                        .frame(width: 44, height: 44)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Rate \(star) stars")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Rating")
        .accessibilityValue("\(stars.formatted(.number.precision(.fractionLength(0...1)))) stars")
    }

    private func symbol(_ star: Int) -> String {
        if stars >= Float(star) - 0.25 {
            return "star.fill"
        }
        if stars >= Float(star) - 0.75 {
            return "star.leadinghalf.filled"
        }
        return "star"
    }
}

/// The song's lyrics, asking Clementine for them the first time.
private struct LyricsView: View {
    @Environment(RemoteSession.self) private var session
    @State private var gaveUp = false

    var body: some View {
        Group {
            if let lyrics = session.lyrics.flatMap(Lyrics.best(of:)), !lyrics.content.isEmpty {
                VStack(alignment: .leading, spacing: Metrics.space3) {
                    Text(lyrics.content)
                        .textStyle(.bodyLarge)
                        .foregroundStyle(Palette.onSurface)
                        .textSelection(.enabled)
                    Text(lyrics.title.isEmpty ? lyrics.provider : lyrics.title)
                        .textStyle(.labelMedium)
                        .foregroundStyle(Palette.onSurfaceVariant)
                }
            } else if session.lyrics != nil || gaveUp {
                Text("No lyrics found.")
                    .textStyle(.bodyLarge)
                    .foregroundStyle(Palette.onSurfaceVariant)
            } else {
                HStack(spacing: Metrics.space3) {
                    ProgressView()
                    Text("Looking for lyrics…")
                        .textStyle(.bodyLarge)
                        .foregroundStyle(Palette.onSurfaceVariant)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task(id: session.song) {
            gaveUp = false
            session.requestLyrics()
            // Clementine doesn't always answer when it finds nothing.
            try? await Task.sleep(for: .seconds(15))
            gaveUp = true
        }
    }
}

private struct ZoomedCover: View {
    let artData: Data?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let image = ArtCache.shared.image(for: artData) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .padding(Metrics.space4)
                    .accessibilityLabel("Cover art")
            }
        }
        .onTapGesture { dismiss() }
        .accessibilityAction(.escape) { dismiss() }
    }
}
