//
//  MediaController.swift
//  FunNotch
//
//  A backend that can report and drive "what is playing right now".
//

import AppKit
import Foundation

struct MediaCapabilities: OptionSet {
    let rawValue: Int
    static let playPause = Self(rawValue: 1)
    static let next = Self(rawValue: 2)
    static let previous = Self(rawValue: 4)
    static let seek = Self(rawValue: 8)
    static let standard: Self = [.playPause, .next, .previous, .seek]
}

struct BrowserTabChoice: Identifiable, Equatable {
    let id: String
    let title: String
    let browser: String
}

/// Everything the UI needs to know about the current track.
struct TrackInfo: Equatable {
    var title: String = ""
    var artist: String = ""
    var album: String = ""
    var artwork: NSImage?
    var duration: TimeInterval = 0
    var elapsed: TimeInterval = 0
    var isPlaying: Bool = false
    var isShuffled: Bool = false
    var repeatMode: RepeatMode = .off
    var bundleIdentifier: String?
    var pageURL: URL?
    var sourceName: String = ""
    /// A tab title supplies metadata but cannot prove play/pause state.
    var hasPlaybackState = true
    var capabilities: MediaCapabilities = .standard
    var isYouTube: Bool {
        guard let host = pageURL?.host?.lowercased() else { return false }
        return host == "youtube.com" || host.hasSuffix(".youtube.com") || host == "youtu.be"
    }
    /// When `elapsed` was last measured, so playback can be interpolated.
    var timestamp: Date = .init()

    var isEmpty: Bool {
        title.isEmpty && artist.isEmpty
    }

    /// True when the backend actually told us how long the track is. Without
    /// it there is no honest scrubber to draw.
    var hasTiming: Bool { duration > 0 }

    /// Elapsed time projected forward to now while playing. With no known
    /// duration this stays put rather than counting up from nowhere — a
    /// browser tab read from its title has no position to report.
    var interpolatedElapsed: TimeInterval {
        guard isPlaying, hasTiming else { return elapsed }
        return min(elapsed + Date().timeIntervalSince(timestamp), duration)
    }

    static func == (lhs: TrackInfo, rhs: TrackInfo) -> Bool {
        lhs.title == rhs.title
            && lhs.artist == rhs.artist
            && lhs.album == rhs.album
            && lhs.isPlaying == rhs.isPlaying
            && lhs.duration == rhs.duration
            && lhs.isShuffled == rhs.isShuffled
            && lhs.repeatMode == rhs.repeatMode
            && lhs.pageURL == rhs.pageURL
            && lhs.sourceName == rhs.sourceName
            && lhs.hasPlaybackState == rhs.hasPlaybackState
            && lhs.capabilities == rhs.capabilities
            && lhs.artwork === rhs.artwork
    }
}

/// Running apps are not necessarily playing. Prefer confirmed playback over
/// a title-only browser guess, then the most recently started/changed source.
enum MediaSourceSelection {
    struct Snapshot {
        let type: MediaControllerType
        let track: TrackInfo
        let activity: TimeInterval
    }
    static func select(_ sources: [Snapshot], current: MediaControllerType?, preferred: MediaControllerType) -> MediaControllerType? {
        sources.filter { !$0.track.isEmpty }.max { a, b in
            func rank(_ s: Snapshot) -> Int { s.track.isPlaying ? (s.track.hasPlaybackState ? 3 : 2) : 1 }
            if rank(a) != rank(b) { return rank(a) < rank(b) }
            if a.activity != b.activity { return a.activity < b.activity }
            if (a.type == current) != (b.type == current) { return b.type == current }
            if (a.type == preferred) != (b.type == preferred) { return b.type == preferred }
            return a.type.rawValue < b.type.rawValue
        }?.type
    }
}

protocol MediaController: AnyObject {
    var type: MediaControllerType { get }
    /// Called whenever the backend has fresh information.
    var onUpdate: ((TrackInfo) -> Void)? { get set }
    /// True when this backend can currently provide anything at all.
    var isAvailable: Bool { get }

    func start()
    func stop()
    /// Forces a refresh outside the normal cadence.
    func refresh()

    func play()
    func pause()
    func togglePlayPause()
    func nextTrack()
    func previousTrack()
    func seek(to time: TimeInterval)
    func toggleShuffle()
    func cycleRepeat()
}

extension MediaController {
    func play() {}
    func pause() {}
    func toggleShuffle() {}
    func cycleRepeat() {}
}
