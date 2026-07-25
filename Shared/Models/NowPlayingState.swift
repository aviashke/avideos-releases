import Foundation

/// A snapshot of the iPhone's player, pushed to the watch so it can act as a live
/// remote — showing what's playing and driving transport from the wrist. Kept
/// small so it rides comfortably over WatchConnectivity.
struct NowPlayingState: Codable, Equatable {
    var sender: String          // show / sender name (e.g. "Sharp Tech")
    var subject: String         // episode / subject line
    var senderAddress: String   // used to load the artwork on the watch
    /// Most recent inline image reached by playback. The watch keeps showing it
    /// until a later image replaces it, matching the lock-screen artwork behavior.
    var artworkURL: URL?
    /// Current spoken sentence, shown in the watch's expanded reading surface.
    var currentSentence: String?
    var isPlaying: Bool
    var progress: Double         // 0...1 through the email
    var secondsRemaining: Int
    var speed: Double            // 0.5...2.5×

    /// Sentinel meaning "nothing is loaded on the phone".
    static let empty = NowPlayingState(
        sender: "", subject: "", senderAddress: "",
        artworkURL: nil, currentSentence: nil,
        isPlaying: false, progress: 0, secondsRemaining: 0, speed: 1
    )

    var hasContent: Bool { !subject.isEmpty || !sender.isEmpty }

    var minutesRemaining: Int { max(0, Int((Double(secondsRemaining) / 60).rounded())) }
}
