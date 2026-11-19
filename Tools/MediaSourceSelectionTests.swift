import AppKit
import Foundation

@main enum MediaSourceSelectionTests {
    static func main() {
        var failures = 0
        func check(_ name: String, _ valid: Bool) {
            print("[\(valid ? "PASS" : "FAIL")] \(name)")
            if !valid { failures += 1 }
        }
        func track(_ title: String, playing: Bool, confirmed: Bool = true) -> TrackInfo {
            var info = TrackInfo(); info.title = title; info.isPlaying = playing; info.hasPlaybackState = confirmed
            return info
        }
        typealias Source = MediaSourceSelection.Snapshot
        let web = Source(type: .browser, track: track("Video", playing: true), activity: 10)
        let music = Source(type: .appleMusic, track: track("Song", playing: true), activity: 20)
        let paused = Source(type: .spotify, track: track("Old song", playing: false), activity: 30)
        let guess = Source(type: .browser, track: track("Unconfirmed tab", playing: true, confirmed: false), activity: 99)
        check("an active video beats a preferred idle music app",
              MediaSourceSelection.select([web, paused], current: .spotify, preferred: .spotify) == .browser)
        check("newly playing music replaces an older video",
              MediaSourceSelection.select([web, music], current: .browser, preferred: .browser) == .appleMusic)
        check("a tab-title guess cannot mask confirmed audio playback",
              MediaSourceSelection.select([guess, music], current: .browser, preferred: .browser) == .appleMusic)
        check("a paused app does not capture active playback",
              MediaSourceSelection.select([web, paused], current: .browser, preferred: .spotify) == .browser)
        check("empty sources produce no false current track",
              MediaSourceSelection.select([Source(type: .browser, track: TrackInfo(), activity: 100)], current: .browser, preferred: .browser) == nil)
        let tied = Source(type: .appleMusic, track: music.track, activity: 10)
        check("equal reports keep the current source without flicker",
              MediaSourceSelection.select([web,tied], current: .browser, preferred: .appleMusic) == .browser)
        check("removing a finished source reveals another active one",
              MediaSourceSelection.select([web], current: .appleMusic, preferred: .appleMusic) == .browser)
        check("a paused track stays available for resuming if nothing else plays",
              MediaSourceSelection.select([paused], current: .spotify, preferred: .browser) == .spotify)
        print("\(failures) failures")
        exit(failures == 0 ? 0 : 1)
    }
}
