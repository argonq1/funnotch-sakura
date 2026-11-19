//
//  BrowserMediaController.swift
//  FunNotch
//
//  Reads what is playing in a browser tab — YouTube, YouTube Music, Spotify's
//  web player, SoundCloud and friends.
//
//  macOS 15.4 took system-wide Now Playing away from unentitled apps, so the
//  only way left is to ask the browser directly. Where the browser will run
//  JavaScript for us we read `navigator.mediaSession`, which is exactly the
//  metadata these sites already publish; where it will not, we fall back to
//  parsing the tab title, which still gets the track name right.
//
//  Running JavaScript needs the user to switch it on once:
//    Chrome  → View → Developer → Allow JavaScript from Apple Events
//    Safari  → Develop → Allow JavaScript from Apple Events
//

import AppKit
import Foundation

private let fieldSeparator = "|~|"

private struct BrowserTarget {
    let bundleIdentifier: String
    let applicationName: String
    /// Chrome-family browsers use `execute javascript`, Safari uses `do JavaScript`.
    let isChromeFamily: Bool
}

/// A media site we know how to read, and how to drive it.
private struct MediaSite {
    let host: String
    let name: String
    /// Suffix the site appends to its tab titles, stripped for the fallback.
    let titleSuffix: String
    /// What the tab is called while nothing is playing. An open tab sitting on
    /// its own landing page is not a track, and reporting it as one is how the
    /// notch ended up announcing "YouTube Music" by YouTube Music.
    let idleTitles: [String]
    let nextSelectors: [String]
    let previousSelectors: [String]

    func isIdle(title: String) -> Bool {
        let trimmed = title.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return true }
        if trimmed.caseInsensitiveCompare(name) == .orderedSame { return true }
        return idleTitles.contains { $0.caseInsensitiveCompare(trimmed) == .orderedSame }
    }
}

final class BrowserMediaController: MediaController {
    let type: MediaControllerType = .browser
    var onUpdate: ((TrackInfo) -> Void)?
    var onCommandFailure: ((String?) -> Void)?
    var onSkipPending: ((Bool) -> Void)?
    var onTabsChanged: (([BrowserTabChoice]) -> Void)?
    private var discoveredTabs: [(browser: BrowserTarget, hit: TabHit)] = []
    private var skipToken: UUID?
    private var videoHistory: [String: BrowserVideoHistory] = [:]

    private var timer: Timer?
    private var current = TrackInfo()
    private var lastArtworkKey = ""
    private var artworkTask: URLSessionDataTask?
    private var artworkGeneration = 0
    private var lastArtworkAttempt = Date.distantPast
    private let artworkCache = NSCache<NSString, NSImage>()
    private lazy var artworkSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        return URLSession(configuration: configuration)
    }()
    /// Last logged "which browser, which path", so the log records changes only.
    private var lastReadMode = ""
    /// Where the media tab lives, so commands go to the right place.
    private var activeTab: (browser: BrowserTarget, window: Int, tab: Int, id: String)?

    func selectTab(_ id: String?) {
        Settings.shared.lockedBrowserTab = id ?? ""
        Settings.shared.lockedBrowserPageURL = discoveredTabs.first {
            Self.tabKey(browser: $0.browser, hit: $0.hit) == id
        }?.hit.url ?? ""
        playbackRevision += 1
        skipToken = nil
        onSkipPending?(false)
        activeTab = nil
        lastFullScan = .distantPast
        refresh()
    }

    func discoverTabs() {
        lastFullScan = .distantPast
        refresh()
    }

    private static func tabKey(browser: BrowserTarget, hit: TabHit) -> String {
        browser.bundleIdentifier + "/" + (hit.id.isEmpty ? "\(hit.window)/\(hit.tab)" : hit.id)
    }
    /// False once a scan finds no media tab, so the app can fall back.
    private var foundMediaTab = true
    private var isScanning = false
    private var playbackRevision = 0
    /// When every window was last walked, so a cached tab cannot go stale.
    private var lastFullScan = Date.distantPast
    private var lastScanSummary = ""

    private static let browsers: [BrowserTarget] = [
        BrowserTarget(bundleIdentifier: "com.google.Chrome", applicationName: "Google Chrome", isChromeFamily: true),
        BrowserTarget(bundleIdentifier: "com.brave.Browser", applicationName: "Brave Browser", isChromeFamily: true),
        BrowserTarget(bundleIdentifier: "com.microsoft.edgemac", applicationName: "Microsoft Edge", isChromeFamily: true),
        BrowserTarget(bundleIdentifier: "company.thebrowser.Browser", applicationName: "Arc", isChromeFamily: true),
        BrowserTarget(bundleIdentifier: "com.apple.Safari", applicationName: "Safari", isChromeFamily: false),
    ]

    private static let sites: [MediaSite] = [
        MediaSite(
            host: "music.youtube.com",
            name: "YouTube Music",
            titleSuffix: " - YouTube Music",
            idleTitles: ["YouTube Music"],
            nextSelectors: [".next-button", "tp-yt-paper-icon-button.next-button"],
            previousSelectors: [".previous-button", "tp-yt-paper-icon-button.previous-button"]
        ),
        MediaSite(
            host: "youtube.com",
            name: "YouTube",
            titleSuffix: " - YouTube",
            idleTitles: ["YouTube"],
            nextSelectors: [".ytp-next-button"],
            previousSelectors: [".ytp-prev-button"]
        ),
        MediaSite(
            host: "open.spotify.com",
            name: "Spotify",
            titleSuffix: " | Spotify",
            idleTitles: [
                "Spotify",
                "Web Player: Music for everyone",
                "Spotify - Web Player: Music for everyone",
                "Spotify – Web Player: Music for everyone",
            ],
            nextSelectors: ["[data-testid=control-button-skip-forward]"],
            previousSelectors: ["[data-testid=control-button-skip-back]"]
        ),
        MediaSite(
            host: "soundcloud.com",
            name: "SoundCloud",
            titleSuffix: " | Free Listening on SoundCloud",
            idleTitles: [
                "SoundCloud",
                "Stream and listen to music online for free with SoundCloud",
            ],
            nextSelectors: [".skipControl__next"],
            previousSelectors: [".skipControl__previous"]
        ),
        MediaSite(
            host: "music.apple.com",
            name: "Apple Music",
            titleSuffix: " - Apple Music",
            idleTitles: ["Apple Music", "Apple Music - Web Player"],
            nextSelectors: ["button.next"],
            previousSelectors: ["button.previous"]
        ),
        MediaSite(
            host: "bandcamp.com",
            name: "Bandcamp",
            titleSuffix: "",
            idleTitles: ["Bandcamp"],
            nextSelectors: [".nextbutton"],
            previousSelectors: [".prevbutton"]
        ),
        MediaSite(
            host: "twitch.tv",
            name: "Twitch",
            titleSuffix: " - Twitch",
            idleTitles: ["Twitch"],
            nextSelectors: [],
            previousSelectors: []
        ),
        MediaSite(
            host: "vimeo.com",
            name: "Vimeo",
            titleSuffix: " on Vimeo",
            idleTitles: ["Vimeo"],
            nextSelectors: [],
            previousSelectors: []
        ),
    ]

    init() {
        artworkCache.countLimit = 2
        artworkCache.totalCostLimit = 6 * 1024 * 1024
    }

    var isAvailable: Bool {
        guard Self.hasRunningBrowser else {
            return false
        }
        return foundMediaTab
    }
    static var hasRunningBrowser: Bool { browsers.contains { AppleScriptRunner.isRunning($0.bundleIdentifier) } }

    func start() {
        stop()
        refresh()
        scheduleNextPoll()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        cancelArtwork()
        skipToken = nil; onSkipPending?(false)
    }

    /// How long to wait before looking again.
    ///
    /// Every poll is Apple Events into another process, so an idle Mac should
    /// not pay what a playing one does. Nothing here changes how quickly a
    /// playing track updates.
    private var pollInterval: TimeInterval {
        if SystemActivityMonitor.isScreenIdle { return 30 }
        if current.isPlaying { return 2 }
        if activeTab != nil { return 5 }
        return 12
    }

    private func scheduleNextPoll() {
        timer?.invalidate()
        let timer = Timer(timeInterval: pollInterval, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refresh()
                self?.scheduleNextPoll()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func refresh() {
        guard !SystemActivityMonitor.isScreenIdle else { return }
        guard !isScanning, skipToken == nil else { return }
        let running = Self.browsers.filter { AppleScriptRunner.isRunning($0.bundleIdentifier) }
        guard !running.isEmpty else {
            activeTab = nil
            clearIfNeeded()
            return
        }
        isScanning = true
        let revision = playbackRevision

        // A tab we already know about is re-read directly. Walking every window
        // of every browser to rediscover the same tab is the expensive part, so
        // it only happens when that tab stops being one we can read — or every
        // half minute, in case a better one has appeared since.
        if let active = activeTab,
           running.contains(where: { $0.bundleIdentifier == active.browser.bundleIdentifier }),
           Date().timeIntervalSince(lastFullScan) < 30 {
            let script = Self.singleTabScript(
                for: active.browser,
                window: active.window,
                tab: active.tab
            )
            AppleScriptRunner.shared.runForString(script) { [weak self] result in
                guard let self else { return }
                guard revision == self.playbackRevision else { self.isScanning = false; self.refresh(); return }
                if let result, let hit = Self.parseTab(result) {
                    if !active.id.isEmpty && hit.id != active.id {
                        self.scan(browsers: running, index: 0)
                        return
                    }
                    self.activeTab = (active.browser, hit.window, hit.tab, hit.id)
                    self.readTab(
                        browser: active.browser,
                        window: hit.window,
                        tab: hit.tab,
                        site: hit.site,
                        title: hit.title,
                        pageURL: hit.url
                    )
                    return
                }
                self.activeTab = nil
                self.scan(browsers: running, index: 0)
            }
            return
        }

        lastFullScan = Date()
        scan(browsers: running, index: 0)
    }

    /// Inventory is refreshed on demand and periodically, with stable Chrome tab IDs.
    private func scan(browsers: [BrowserTarget], index: Int) {
        if index == 0 { discoveredTabs = [] }
        guard index < browsers.count else {
            let choices = discoveredTabs.map { item in
                BrowserTabChoice(id: Self.tabKey(browser: item.browser, hit: item.hit),
                                 title: Self.cleanedTitle(item.hit.title, for: item.hit.site), browser: item.browser.applicationName)
            }
            onTabsChanged?(choices)
            let locked = Settings.shared.lockedBrowserTab
            let savedURL = Settings.shared.lockedBrowserPageURL
            let restored = discoveredTabs.first { item in
                guard !locked.isEmpty, !savedURL.isEmpty, locked.hasPrefix(item.browser.bundleIdentifier + "/") else { return false }
                if item.hit.url == savedURL { return true }
                if let savedVideo = BrowserVideoHistory.videoID(savedURL) {
                    return BrowserVideoHistory.videoID(item.hit.url) == savedVideo
                }
                return false
            }
            let selected = discoveredTabs.first { Self.tabKey(browser: $0.browser, hit: $0.hit) == locked } ?? restored
                ?? (locked.isEmpty ? discoveredTabs.first : nil)
            guard let selected else {
                isScanning = false
                foundMediaTab = false
                clearIfNeeded()
                if !locked.isEmpty { onCommandFailure?("Закреплённая вкладка недоступна. Выбери источник.") }
                return
            }
            let hit = selected.hit
            if !locked.isEmpty {
                let key = Self.tabKey(browser: selected.browser, hit: hit)
                if Settings.shared.lockedBrowserTab != key { Settings.shared.lockedBrowserTab = key }
            }
            activeTab = (selected.browser, hit.window, hit.tab, hit.id)
            foundMediaTab = true
            readTab(browser: selected.browser, window: hit.window, tab: hit.tab,
                    site: hit.site, title: hit.title, pageURL: hit.url)
            return
        }
        let browser = browsers[index]
        AppleScriptRunner.shared.runForString(Self.tabListScript(for: browser)) { [weak self] result in
            guard let self else { return }
            for line in (result ?? "").components(separatedBy: "\n") {
                if let hit = Self.parseTab(line) { self.discoveredTabs.append((browser, hit)) }
            }
            self.scan(browsers: browsers, index: index + 1)
        }
    }

    /// Asks the page itself what it is playing.
    private func readTab(
        browser: BrowserTarget,
        window: Int,
        tab: Int,
        site: MediaSite,
        title: String,
        pageURL: String
    ) {
        let script = Self.javaScriptScript(for: browser, window: window, tab: tab, stableID: activeTab?.id, body: Self.metadataJavaScript)
        let revision = playbackRevision

        AppleScriptRunner.shared.runForString(script) { [weak self] result in
            guard let self else { return }
            self.isScanning = false
            guard self.skipToken == nil else { return }
            guard self.playbackRevision == revision else { self.refresh(); return }

            if let result, result.contains(fieldSeparator) {
                self.noteReadMode(scripted: true, browser: browser)
                self.apply(rawState: result, site: site, browser: browser, pageURL: pageURL)
            } else {
                // JavaScript is switched off; the tab title still names the track.
                self.noteReadMode(scripted: false, browser: browser)
                self.applyTitleOnly(title, site: site, browser: browser, pageURL: pageURL)
            }
        }
    }

    /// Says once, in the log, which of the two paths a browser is actually on.
    /// Falling back to the tab title is meant to be the rare case; when it was
    /// silently the only case for Chrome, nothing in the app said so.
    private func noteReadMode(scripted: Bool, browser: BrowserTarget) {
        BrowserReadModes.record(browser: browser.applicationName, scripted: scripted)
        let mode = scripted ? "page" : "title-only"
        guard lastReadMode != "\(browser.applicationName)/\(mode)" else { return }
        lastReadMode = "\(browser.applicationName)/\(mode)"
        DiagnosticLog.write("media", "reading \(browser.applicationName) via \(mode)")
    }

    private func apply(rawState: String, site: MediaSite, browser: BrowserTarget, pageURL: String) {
        let parts = rawState.components(separatedBy: fieldSeparator)
        guard parts.count >= 7 else { return }
        guard !site.isIdle(title: parts[0]) || !parts[1].isEmpty else {
            clearIfNeeded()
            return
        }

        var info = TrackInfo()
        info.title = parts[0].isEmpty ? site.name : parts[0]
        info.artist = parts[1].isEmpty ? site.name : parts[1]
        info.album = parts[2]
        info.duration = Double(parts[3]) ?? 0
        info.elapsed = Double(parts[4]) ?? 0
        info.isPlaying = parts[5] == "playing"
        info.bundleIdentifier = browser.bundleIdentifier
        info.pageURL = URL(string: pageURL)
        info.sourceName = site.name
        info.timestamp = Date()
        info.artwork = current.artwork
        if parts.count > 7 {
            info.capabilities = []
            if parts[7].contains("play") { info.capabilities.insert(.playPause) }
            if parts[7].contains("seek") { info.capabilities.insert(.seek) }
            if parts[7].contains("next") { info.capabilities.insert(.next) }
            if parts[7].contains("previous") { info.capabilities.insert(.previous) }
            let historyKey = "\(browser.bundleIdentifier)/\(activeTab?.window ?? 0)/\(activeTab?.tab ?? 0)"
            if (videoHistory[historyKey]?.index ?? 0) > 0 { info.capabilities.insert(.previous) }
        }

        publish(info, artworkURL: parts[6], pageURL: pageURL)
    }

    /// Fallback when the browser will not run JavaScript for us.
    private func applyTitleOnly(
        _ rawTitle: String,
        site: MediaSite,
        browser: BrowserTarget,
        pageURL: String
    ) {
        let title = Self.cleanedTitle(rawTitle, for: site)

        // An idle tab is not a track. Reporting one produced the nonsense the
        // notch used to show: "YouTube Music" by "YouTube Music", with no time.
        guard !site.isIdle(title: title) else {
            clearIfNeeded()
            return
        }

        var info = TrackInfo()
        // "Track - Artist" is the common shape; keep the whole thing if not.
        let separators = [" - ", " • ", " · "]
        if let separator = separators.first(where: { title.contains($0) }) {
            let pieces = title.components(separatedBy: separator)
            info.title = pieces[0].trimmingCharacters(in: .whitespaces)
            info.artist = pieces.dropFirst().joined(separator: separator).trimmingCharacters(in: .whitespaces)
        } else {
            info.title = title
            info.artist = site.name
        }
        // Without JavaScript there is no way to know; assume it is playing,
        // since an idle tab rarely sits on a media page for long.
        info.isPlaying = true
        info.hasPlaybackState = false
        info.capabilities = []
        info.bundleIdentifier = browser.bundleIdentifier
        info.pageURL = URL(string: pageURL)
        info.sourceName = site.name
        info.timestamp = Date()
        info.artwork = current.artwork

        publish(info, artworkURL: "", pageURL: pageURL)
    }

    private func publish(_ info: TrackInfo, artworkURL: String, pageURL: String) {
        var info = info
        if !Settings.shared.lockedBrowserTab.isEmpty, Settings.shared.lockedBrowserPageURL != pageURL {
            Settings.shared.lockedBrowserPageURL = pageURL
        }
        if let tab = activeTab {
            let key = "\(tab.browser.bundleIdentifier)/\(tab.window)/\(tab.tab)"
            if videoHistory.count > 20 { videoHistory.removeAll() }
            videoHistory[key, default: BrowserVideoHistory()].record(pageURL)
        }
        if info.pageURL != current.pageURL || info.title != current.title || (!current.hasPlaybackState && info.hasPlaybackState) { onCommandFailure?(nil) }
        // YouTube publishes a thumbnail for every video at a predictable
        // address, so artwork works there even when the page itself is off
        // limits to us.
        // Try larger stills first, even if the page only publishes a small
        // Media Session image or browser automation is unavailable.
        let thumbnails = Self.thumbnailURLs(forPageURL: pageURL)
        let sources = thumbnails.isEmpty ? artworkURL.split(separator: "\n").map(String.init) : thumbnails
        let source = sources.first ?? ""
        let key = thumbnails.isEmpty ? "\(source)|\(info.title)|\(info.artist)" : source
        let minimumWidth = thumbnails.isEmpty ? 0 : 300

        if key != lastArtworkKey {
            cancelArtwork()
            lastArtworkKey = key
            info.artwork = nil
            current = info
            if !source.isEmpty {
                downloadArtwork(from: sources, key: key, minimumWidth: minimumWidth)
            }
        } else {
            current = info
            if current.artwork == nil, artworkTask == nil, !source.isEmpty,
               Date().timeIntervalSince(lastArtworkAttempt) > 30 {
                downloadArtwork(from: sources, key: key, minimumWidth: minimumWidth)
            }
        }

        onUpdate?(current)
    }

    /// Strips the site's own branding off a tab title, leaving what the page is
    /// actually about.
    private static func cleanedTitle(_ rawTitle: String, for site: MediaSite) -> String {
        var title = rawTitle
        if let count = title.range(of: "^\\(\\d+\\)\\s+", options: .regularExpression) { title.removeSubrange(count) }
        if !site.titleSuffix.isEmpty, title.hasSuffix(site.titleSuffix) {
            title.removeLast(site.titleSuffix.count)
        }
        // Sites often mark an unread count or playing state in the title.
        if title.hasPrefix("▶ ") { title.removeFirst(2) }
        return title.trimmingCharacters(in: .whitespaces)
    }

    /// Whether a tab is sitting on a media site without playing anything.
    nonisolated static func isIdleTab(url: String, title: String) -> Bool {
        guard let host = FocusManager.host(of: url),
              let site = sites.first(where: { host == $0.host || host.hasSuffix("." + $0.host) })
        else { return true }
        return site.isIdle(title: cleanedTitle(title, for: site))
    }

    /// `https://www.youtube.com/watch?v=ID` → the video's thumbnail.
    static func thumbnailURL(forPageURL urlString: String) -> String? {
        guard let components = URLComponents(string: urlString),
              let host = components.host?.lowercased(),
              host == "youtube.com" || host.hasSuffix(".youtube.com") || host == "youtu.be"
        else { return nil }
        let path = components.path.split(separator: "/").map(String.init)
        let identifier: String?
        if host == "youtu.be" { identifier = path.first }
        else if let first = path.first, ["shorts", "embed", "live"].contains(first), path.count > 1 { identifier = path[1] }
        else { identifier = components.queryItems?.first(where: { $0.name == "v" })?.value }
        guard let identifier, !identifier.isEmpty, identifier.count <= 64,
              identifier.utf8.allSatisfy({ (65 ... 90).contains($0) || (97 ... 122).contains($0) || (48 ... 57).contains($0) || $0 == 45 || $0 == 95 })
        else { return nil }
        return "https://img.youtube.com/vi/\(identifier)/maxresdefault.jpg"
    }

    static func thumbnailURLs(forPageURL urlString: String) -> [String] {
        guard let highResolution = thumbnailURL(forPageURL: urlString) else { return [] }
        let base = String(highResolution.dropLast("maxresdefault.jpg".count))
        return ["maxresdefault", "sddefault", "hqdefault", "mqdefault"].map { "\(base)\($0).jpg" }
    }

    private func clearIfNeeded() {
        isScanning = false
        activeTab = nil
        guard !current.isEmpty || current.isPlaying else { return }
        current = TrackInfo()
        cancelArtwork()
        lastArtworkKey = ""
        onUpdate?(current)
    }

    private func downloadArtwork(from sources: [String], key: String, minimumWidth: Int, cacheKey: String? = nil) {
        guard let urlString = sources.first, let url = URL(string: urlString),
              ["https", "http"].contains(url.scheme?.lowercased() ?? "") else { return }
        let cacheKey = cacheKey ?? urlString
        if let cached = artworkCache.object(forKey: cacheKey as NSString) {
            current.artwork = cached
            return
        }
        lastArtworkAttempt = Date()
        artworkGeneration += 1
        let generation = artworkGeneration
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        artworkTask = artworkSession.dataTask(with: request) { [weak self] data, response, _ in
            let valid = (response as? HTTPURLResponse).map { (200 ... 299).contains($0.statusCode) } ?? false
            let decodedImage = valid ? data.flatMap { MediaArtwork.decode($0) } : nil
            DispatchQueue.main.async {
                guard let self, key == self.lastArtworkKey, generation == self.artworkGeneration else { return }
                self.artworkTask = nil
                // Missing YouTube art may be a tiny placeholder, even when the
                // server responds with a successful status.
                guard let image = decodedImage, (image.representations.first?.pixelsWide ?? 0) >= minimumWidth else {
                    if sources.count > 1 {
                        self.downloadArtwork(from: Array(sources.dropFirst()), key: key,
                                             minimumWidth: minimumWidth, cacheKey: cacheKey)
                    }
                    return
                }
                self.artworkCache.setObject(image, forKey: cacheKey as NSString, cost: MediaArtwork.pixelCost(image))
                self.current.artwork = image
                self.onUpdate?(self.current)
            }
        }
        artworkTask?.resume()
    }

    private func cancelArtwork() {
        artworkTask?.cancel(); artworkTask = nil; artworkGeneration += 1
    }

    // MARK: - Transport

    @discardableResult
    func revealActiveTab() -> Bool {
        guard let tab = activeTab else { return false }
        AppleScriptRunner.shared.execute(Self.revealTabScript(for: tab.browser, window: tab.window, tab: tab.tab))
        return true
    }

    private static func revealTabScript(for browser: BrowserTarget, window: Int, tab: Int) -> String {
        let select = browser.isChromeFamily
            ? "set active tab index of window \(window) to \(tab)"
            : "set current tab of window \(window) to tab \(tab) of window \(window)"
        return """
        tell application id "\(browser.bundleIdentifier)"
            try
                \(select)
                set index of window \(window) to 1
                activate
            end try
        end tell
        """
    }

    private func runJavaScript(_ body: String, command: String) {
        guard let tab = activeTab else { return }
        DiagnosticLog.write("media-command", "sending \(command) to \(tab.browser.applicationName)")
        let script = Self.javaScriptScript(for: tab.browser, window: tab.window, tab: tab.tab, stableID: tab.id, body: body)
        AppleScriptRunner.shared.runForString(script) { [weak self] result in
            guard let self else { return }
            if result == "ok" {
                self.onCommandFailure?(nil)
                DiagnosticLog.write("media-command", "browser accepted \(command)")
            } else {
                let message = result?.hasPrefix("error:") == true || result?.isEmpty != false
                    ? "\(tab.browser.applicationName) блокирует управление · нужен доступ к странице"
                    : "Эта команда недоступна для текущего ролика"
                self.onCommandFailure?(message)
                DiagnosticLog.write("media-command", "\(command) failed: \(result ?? "no response")")
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in self?.refresh() }
        }
    }

    static let playPauseJavaScript =
        "(function(){\(BrowserPlaybackScript.mediaFunction)var v=media();if(!v)return '';v.paused?v.play():v.pause();return 'ok';})()"

    func togglePlayPause() {
        runJavaScript(Self.playPauseJavaScript, command: "play/pause")
    }

    func play() {
        runJavaScript("(function(){\(BrowserPlaybackScript.mediaFunction)var v=media();if(!v)return 'unavailable';v.play();return 'ok';})()", command: "play")
    }

    func pause() {
        runJavaScript("(function(){\(BrowserPlaybackScript.mediaFunction)var v=media();if(!v)return 'unavailable';v.pause();return 'ok';})()", command: "pause")
    }

    func nextTrack() {
        skip(next: true)
    }

    func previousTrack() {
        skip(next: false)
    }

    private func skip(next: Bool) {
        guard skipToken == nil, let tab = activeTab, let url = current.pageURL,
              let host = FocusManager.host(of: url.absoluteString),
              let site = Self.sites.first(where: { host == $0.host || host.hasSuffix("." + $0.host) }) else { return }
        let token = UUID(); skipToken = token; playbackRevision += 1
        onCommandFailure?(nil); onSkipPending?(true)
        let historyKey = "\(tab.browser.bundleIdentifier)/\(tab.window)/\(tab.tab)"
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
            guard self?.skipToken == token else { return }
            self?.finishSkip(token: token, historyKey: historyKey, error: "Браузер не ответил на переключение. Попробуй ещё раз.")
        }
        let fallback = videoHistory[historyKey]?.candidate(next: next)
        let body = BrowserSkipScript.command(next: next, expectedURL: url.absoluteString, historyURL: fallback,
            selectors: next ? site.nextSelectors : site.previousSelectors)
        let script = Self.javaScriptScript(for: tab.browser, window: tab.window, tab: tab.tab, stableID: tab.id, body: body)
        let command = next ? "next" : "previous"
        DiagnosticLog.write("media-command", "requesting verified \(command)")
        AppleScriptRunner.shared.runForString(script) { [weak self] raw in
            guard let self, self.skipToken == token else { return }
            guard let data = raw?.data(using: .utf8),
                  let result = try? JSONSerialization.jsonObject(with: data) as? [String: String],
                  result["status"] == "sent", let before = result["before"] else {
                let unavailable = raw?.contains("unavailable") == true
                let stale = raw?.contains("stale") == true
                if let data = raw?.data(using: .utf8),
                   let diagnostic = try? JSONSerialization.jsonObject(with: data) as? [String: String],
                   let detail = diagnostic["detail"], !detail.isEmpty {
                    DiagnosticLog.write("media-command", "skip page controls: \(detail)")
                }
                let message = stale ? "Вкладка изменилась. Обновляю плеер — нажми ещё раз."
                    : unavailable ? (next ? "На этой странице нет следующего трека." : "Предыдущего ролика пока нет. Переключи вперёд — сможешь вернуться.")
                    : "\(tab.browser.applicationName) не дал переключить трек. Проверь доступ к странице."
                self.finishSkip(token: token, historyKey: historyKey, error: message)
                if stale { self.lastFullScan = .distantPast; self.refresh() }
                return
            }
            func verify(_ attempt: Int) {
                let delays = [0.10, 0.18, 0.25, 0.4, 0.6, 0.85, 1.0, 1.0]
                let delay = delays[attempt]
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                    guard let self, self.skipToken == token else { return }
                    // Identity, URL and playback metadata are one atomic page read.
                    // Commit that new URL before accepting another skip.
                    let read = Self.javaScriptScript(for: tab.browser, window: tab.window, tab: tab.tab, stableID: tab.id,
                        body: Self.playbackSnapshotJavaScript)
                    AppleScriptRunner.shared.runForString(read) { [weak self] rawSnapshot in
                        guard let self, self.skipToken == token else { return }
                        let fields = rawSnapshot?.components(separatedBy: "\u{001e}") ?? []
                        if fields.count == 3, BrowserSkipScript.hasChanged(before: before, after: fields[0]),
                           let page = URL(string: fields[1]), page.host == url.host {
                            DiagnosticLog.write("media-command", "verified \(command): media changed")
                            self.playbackRevision += 1
                            self.lastFullScan = Date()
                            self.apply(rawState: fields[2], site: site, browser: tab.browser, pageURL: fields[1])
                            self.skipToken = nil; self.onSkipPending?(false); self.onCommandFailure?(nil)
                        } else if attempt < delays.count - 1 { verify(attempt + 1) }
                        else {
                            self.finishSkip(token: token, historyKey: historyKey,
                                error: "Трек не сменился. Открой источник и проверь очередь воспроизведения.")
                        }
                    }
                }
            }
            verify(0)
        }
    }

    private func finishSkip(token: UUID, historyKey: String, error: String) {
        guard skipToken == token else { return }
        skipToken = nil; videoHistory[historyKey]?.cancel()
        onSkipPending?(false); onCommandFailure?(error)
        DiagnosticLog.write("media-command", "skip not confirmed: \(error)")
    }

    func seek(to time: TimeInterval) {
        guard time.isFinite, skipToken == nil, let url = current.pageURL else { return }
        playbackRevision += 1
        runJavaScript(BrowserPlaybackScript.seek(to: time, expectedURL: url.absoluteString), command: "seek")
    }

    // MARK: - Scripts

    /// Returns `window|~|tab|~|url|~|title` per line.
    ///
    /// The URLs and titles are pulled a whole window at a time. Asking for them
    /// tab by tab looks equivalent and is not: every `URL of tab t of window w`
    /// is its own Apple Event round trip to the browser, so a couple of windows
    /// of ordinary tabs cost sixty-odd events every poll. Profiling put 29% of
    /// this app's script thread inside `UASRemoteSend` because of it. Two
    /// events per window instead, and the joining loop below runs on local
    /// lists without talking to the browser at all.
    private static func tabListScript(for browser: BrowserTarget) -> String {
        let titleProperty = browser.isChromeFamily ? "title" : "name"
        return """
        tell application id "\(browser.bundleIdentifier)"
            set out to ""
            repeat with w from 1 to count of windows
                set us to URL of tabs of window w
                set ns to \(titleProperty) of tabs of window w
                \(browser.isChromeFamily ? "set ids to id of tabs of window w" : "")
                repeat with i from 1 to count of us
                    set out to out & w & "\(fieldSeparator)" & i & "\(fieldSeparator)" & (item i of us) & "\(fieldSeparator)" & (item i of ns) & "\(fieldSeparator)" & \(browser.isChromeFamily ? "(item i of ids)" : "i") & linefeed
                end repeat
            end repeat
            return out
        end tell
        """
    }

    /// Reads one known tab, for when a media tab has already been found. Saves
    /// walking every window on every poll.
    private static func singleTabScript(for browser: BrowserTarget, window: Int, tab: Int) -> String {
        let titleProperty = browser.isChromeFamily ? "title" : "name"
        return """
        tell application id "\(browser.bundleIdentifier)"
            try
                set u to (URL of tab \(tab) of window \(window)) as string
                set n to (\(titleProperty) of tab \(tab) of window \(window)) as string
                return \(window) & "\(fieldSeparator)" & \(tab) & "\(fieldSeparator)" & u & "\(fieldSeparator)" & n & "\(fieldSeparator)" & \(browser.isChromeFamily ? "(id of tab \(tab) of window \(window))" : "\(tab)")
            on error message number code
                return "error:" & code & ":" & message
            end try
        end tell
        """
    }

    private static func javaScriptScript(
        for browser: BrowserTarget,
        window: Int,
        tab: Int,
        stableID: String? = nil,
        body: String
    ) -> String {
        let escapedBody = body.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        //
        // The two families disagree about word order, and getting it wrong is
        // silent: Chrome's `execute` takes the tab as its direct object and
        // `javascript` as a label, so `execute javascript "…" in tab 1` does
        // not compile at all and every Chrome read fell back to the tab title.
        let target = browser.isChromeFamily && Int(stableID ?? "") != nil ? "mediaTab" : "tab \(tab) of window \(window)"
        let locate = browser.isChromeFamily && Int(stableID ?? "") != nil ? """
        set mediaTab to missing value
        repeat with mediaWindow in windows
            repeat with candidate in tabs of mediaWindow
                if (id of candidate as string) is "\(stableID!)" then set mediaTab to candidate
            end repeat
        end repeat
        if mediaTab is missing value then return "stale"
        """ : ""
        let command = browser.isChromeFamily
            ? "execute \(target) javascript \"\(escapedBody)\""
            : "do JavaScript \"\(escapedBody)\" in tab \(tab) of window \(window)"
        return """
        tell application id "\(browser.bundleIdentifier)"
            try
                with timeout of 5 seconds
                    \(locate)
                    return \(command)
                end timeout
            on error message number code
                return "error:" & code & ":" & message
            end try
        end tell
        """
    }

    /// Reads what the page publishes through the Media Session API, which is
    /// the same metadata macOS itself would have shown.
    private static let playbackSnapshotJavaScript =
        "(function(){return [\(BrowserSkipScript.identity),location.href,\(metadataJavaScript)].join('\\u001e');})()"

    private static let metadataJavaScript = """
    (function(){var m=(navigator.mediaSession&&navigator.mediaSession.metadata)||null;\
    \(BrowserPlaybackScript.mediaFunction)var v=media();\
    var t=m&&m.title?m.title:document.title;var a=m&&m.artist?m.artist:'';\
    var b=m&&m.album?m.album:'';var art=[];\
    function area(item){return (item.sizes||'').split(' ').reduce(function(best,size){\
    var parts=size.split('x');return Math.max(best,Number(parts[0])*Number(parts[1])||0);},0);}\
    if(m&&m.artwork){Array.from(m.artwork).sort(function(a,b){return area(b)-area(a);}).forEach(function(item){\
    try{var url=new URL(item.src,document.baseURI);\
    if((url.protocol==='https:'||url.protocol==='http:')&&art.indexOf(url.href)<0&&art.length<3){art.push(url.href);}}catch(_){}});}\
    var d=v&&isFinite(v.duration)?v.duration:0;var p=v?v.currentTime:0;\
    var s=v?(v.paused?'paused':'playing'):'paused';\
    var caps=[];if(v){caps.push('play');if(d>0)caps.push('seek');}
    var player=document.getElementById('movie_player');
    var next=document.querySelector('.ytp-next-button,.next-button,[data-testid=control-button-skip-forward],.skipControl__next,.nextbutton,button.next');
    var prev=document.querySelector('.ytp-prev-button,.previous-button,[data-testid=control-button-skip-back],.skipControl__previous,.prevbutton,button.previous');
    function enabled(e){return e&&!e.disabled&&e.getAttribute('aria-disabled')!=='true'&&getComputedStyle(e).display!=='none';}
    if(enabled(next)||(player&&typeof player.nextVideo==='function'))caps.push('next');if(enabled(prev))caps.push('previous');
    return [t,a,b,d,p,s,art.join('\\n'),caps.join(',')].join('|~|');})()
    """

    private typealias TabHit = (window: Int, tab: Int, site: MediaSite, title: String, url: String, id: String)

    /// Parses one `window|~|tab|~|url|~|title` line, if it names a site we can
    /// read. Shared by the full scan and the single-tab re-read.
    private static func parseTab(_ line: String) -> TabHit? {
        let parts = line.components(separatedBy: fieldSeparator)
        guard parts.count >= 4,
              let window = Int(parts[0].trimmingCharacters(in: .whitespaces)),
              let tab = Int(parts[1].trimmingCharacters(in: .whitespaces)),
              let host = FocusManager.host(of: parts[2])
        else { return nil }

        guard let site = sites.first(where: { host == $0.host || host.hasSuffix("." + $0.host) })
        else { return nil }

        // A bare youtube.com front page is not "playing something".
        if site.host == "youtube.com", !parts[2].contains("/watch") { return nil }

        return (window, tab, site, parts[3], parts[2], parts.count > 4 ? parts[4] : "")
    }

    private static func firstMediaTab(in rawTabs: String) -> TabHit? {
        for line in rawTabs.components(separatedBy: "\n") where !line.isEmpty {
            if let hit = parseTab(line) { return hit }
        }
        return nil
    }

    /// Whether a URL is one this controller knows how to read.
    nonisolated static func isMediaURL(_ urlString: String) -> Bool {
        guard let host = FocusManager.host(of: urlString) else { return false }
        guard let site = sites.first(where: { host == $0.host || host.hasSuffix("." + $0.host) })
        else { return false }
        if site.host == "youtube.com", !urlString.contains("/watch") { return false }
        return true
    }

    static var installedBrowsers: [String] {
        browsers
            .filter { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0.bundleIdentifier) != nil }
            .map(\.applicationName)
    }

    /// Browsers whose page-access switch `BrowserScriptAccess` knows how to
    /// find, in the order it should try them.
    static var scriptableBrowsers: [(name: String, bundleIdentifier: String, isChromeFamily: Bool)] {
        browsers.map { ($0.applicationName, $0.bundleIdentifier, $0.isChromeFamily) }
    }

    /// The real scripts, exposed so the self test can compile them. Word order
    /// differs between the two browser families and a mistake is silent at
    /// runtime — the read just quietly falls back to the tab title, which is
    /// exactly how Chrome went unnoticed.
    static func diagnosticScripts(forBrowserNamed name: String) -> [(label: String, source: String)]? {
        guard let browser = browsers.first(where: { $0.applicationName == name }) else { return nil }
        return [
            ("tab list", tabListScript(for: browser)),
            ("metadata read", javaScriptScript(for: browser, window: 1, tab: 1, body: metadataJavaScript)),
            ("play/pause", javaScriptScript(for: browser, window: 1, tab: 1, body: playPauseJavaScript)),
            ("stable tab command", javaScriptScript(for: browser, window: 1, tab: 1, stableID: "123", body: playPauseJavaScript)),
            ("verified skip", javaScriptScript(for: browser, window: 1, tab: 1,
                body: BrowserSkipScript.command(next: true, expectedURL: "https://www.youtube.com/watch?v=test", historyURL: nil, selectors: [".ytp-next-button"]))),
            ("skip playback snapshot", javaScriptScript(for: browser, window: 1, tab: 1, body: playbackSnapshotJavaScript)),
            ("seek", javaScriptScript(for: browser, window: 1, tab: 1,
                body: BrowserPlaybackScript.seek(to: 30.25, expectedURL: "https://www.youtube.com/watch?v=test"))),
            ("reveal media tab", revealTabScript(for: browser, window: 1, tab: 1)),
        ]
    }
}
