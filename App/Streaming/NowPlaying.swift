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
        setCommandsEnabled(false)
    }

    /// Shows what the renderer plays, or nothing once it stops.
    func update() {
        let renderer = model.renderer
        guard let item = renderer.item else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
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
        // Clementine sends the cover with the song playing, rather than with the item.
        if let data = model.session.song?.artData, let size = UIImage(data: data)?.size {
            // iOS asks for the image off the main thread: the closure holds only the data.
            info[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: size) { @Sendable _ in
                UIImage(data: data) ?? UIImage()
            }
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        setCommandsEnabled(true)
    }

    private func setCommandsEnabled(_ enabled: Bool) {
        guard enabled != commandsEnabled else { return }
        commandsEnabled = enabled
        let center = MPRemoteCommandCenter.shared()
        for command in [center.playCommand, center.pauseCommand, center.togglePlayPauseCommand,
                        center.nextTrackCommand, center.previousTrackCommand] {
            command.isEnabled = enabled
        }
    }
}
