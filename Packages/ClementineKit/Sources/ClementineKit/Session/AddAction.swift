/// What's done with songs added to a playlist, besides putting them at its end.
public enum AddAction: Sendable, CaseIterable {
    /// Nothing more.
    case append
    /// Clementine plays the first of them unless it's playing already, as it does when you
    /// double-click a song in it.
    case playIfStopped
    /// Clementine plays the first of them.
    case playNow
    /// They're queued to play after anything queued already.
    case queue
    /// They're queued to play straight after the current song, in front of anything queued already.
    /// Needs a Clementine that can ([RemoteSession.canEnqueueNext]); others just add them.
    case playNext
    /// The playlist is emptied first, then Clementine plays the first of them.
    case replace
}
