import ClementineKit
import MediaPlayer
import UIKit

/// The lock screen and Control Center while Clementine plays on this phone: what's playing, and
/// buttons that control Clementine, which decides what the phone plays next.
@MainActor
final class NowPlaying {
    private unowned let model: AppModel
    /// Commands start enabled once they have targets.
    private var commandsEnabled = true
    private var seekEnabled = true
    /// The cover last shown, kept so it isn't decoded again on every update.
    private var cover: (data: Data, artwork: MPMediaItemArtwork)?

    init(model: AppModel) {
        self.model = model
        let center = MPRemoteCommandCenter.shared()
        let session = model.session
        center.playCommand.addTarget { _ in
            MainActor.assumeIsolated { session.play() }
            return .success
        }
        center.pauseCommand.addTarget { _ in
            MainActor.assumeIsolated { session.pause() }
            return .success
        }
        center.togglePlayPauseCommand.addTarget { _ in
            MainActor.assumeIsolated { session.playPause() }
            return .success
        }
        center.nextTrackCommand.addTarget { _ in
            MainActor.assumeIsolated { session.next() }
            return .success
        }
        center.previousTrackCommand.addTarget { _ in
            MainActor.assumeIsolated { session.previous() }
            return .success
        }
        center.changePlaybackPositionCommand.addTarget { event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            let seconds = Int(event.positionTime)
            MainActor.assumeIsolated { session.seek(to: seconds) }
            return .success
        }
        setCommandsEnabled(false)
    }

    /// Shows what the renderer plays, or nothing once it stops.
    func update() {
        let renderer = model.renderer
        guard let item = renderer.item else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            cover = nil
            setCommandsEnabled(false)
            return
        }
        let song = item.song
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: song.title,
            MPMediaItemPropertyArtist: song.artist,
            MPMediaItemPropertyAlbumTitle: song.album,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: Double(renderer.positionMs) / 1000,
            MPNowPlayingInfoPropertyPlaybackRate: renderer.isPlaying ? 1.0 : 0.0,
        ]
        if item.lengthMs > 0 {
            info[MPMediaItemPropertyPlaybackDuration] = Double(item.lengthMs) / 1000
        } else {
            info[MPNowPlayingInfoPropertyIsLiveStream] = true
        }
        if let artwork = artwork(for: item) {
            info[MPMediaItemPropertyArtwork] = artwork
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        setCommandsEnabled(true)
        setSeekEnabled(item.lengthMs > 0)
    }

    /// The cover of [item]'s song. Clementine sends the cover with the song playing, rather than
    /// with the item, and the two can arrive in either order: the cover is only the item's once
    /// they're the same song.
    private func artwork(for item: RenderItem) -> MPMediaItemArtwork? {
        guard let song = model.session.song, song.url == item.song.url, let data = song.artData else {
            return nil
        }
        if let cover, cover.data == data {
            return cover.artwork
        }
        guard let size = UIImage(data: data)?.size else { return nil }
        // iOS asks for the image off the main thread: the closure holds only the data.
        let made = MPMediaItemArtwork(boundsSize: size) { @Sendable _ in
            UIImage(data: data) ?? UIImage()
        }
        cover = (data, made)
        return made
    }

    private func setCommandsEnabled(_ enabled: Bool) {
        guard enabled != commandsEnabled else { return }
        commandsEnabled = enabled
        let center = MPRemoteCommandCenter.shared()
        for command in [center.playCommand, center.pauseCommand, center.togglePlayPauseCommand,
                        center.nextTrackCommand, center.previousTrackCommand] {
            command.isEnabled = enabled
        }
        if !enabled {
            setSeekEnabled(false)
        }
    }

    /// Seeking needs the song's length: without it the lock screen shows no position to drag.
    private func setSeekEnabled(_ enabled: Bool) {
        guard enabled != seekEnabled else { return }
        seekEnabled = enabled
        MPRemoteCommandCenter.shared().changePlaybackPositionCommand.isEnabled = enabled
    }
}
