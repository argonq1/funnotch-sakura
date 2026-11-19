import AppKit
import Combine
import WebKit

/// One lazily created browser for the chess window. A normal top-level page,
/// rather than an iframe or a reimplementation of Chess.com's game protocol.
@MainActor
final class ChessWebSession: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate {
    @Published private(set) var webView: WKWebView?
    @Published private(set) var destination: ChessDestination = .computer
    @Published private(set) var isLoading = false
    @Published private(set) var canGoBack = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var zoom: CGFloat = 1
    private var observations: [NSKeyValueObservation] = []
    private var closedByUser = false
    private var hidden = false
    private var releaseWork: DispatchWorkItem?

    func activate() {
        hidden = false
        releaseWork?.cancel()
        releaseWork = nil
        guard webView == nil, !closedByUser else { return }
        open(destination)
    }

    func open(_ destination: ChessDestination) {
        self.destination = destination
        closedByUser = false
        let browser = webView ?? makeBrowser()
        errorMessage = nil
        browser.load(URLRequest(url: destination.url, timeoutInterval: 35))
    }

    private func makeBrowser() -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.defaultWebpagePreferences.preferredContentMode = .desktop
        configuration.mediaTypesRequiringUserActionForPlayback = .all
        let browser = ChessBrowserView(frame: .zero, configuration: configuration)
        browser.navigationDelegate = self
        browser.uiDelegate = self
        browser.allowsBackForwardNavigationGestures = true
        browser.allowsMagnification = true
        browser.pageZoom = zoom
        browser.underPageBackgroundColor = NSColor(white: 0.16, alpha: 1)
        browser.setAccessibilityLabel("Chess.com — шахматная доска")
        observations = [
            browser.observe(\.isLoading, options: [.initial, .new]) { [weak self] browser, _ in
                Task { @MainActor [weak self] in
                    guard self?.webView === browser else { return }
                    self?.isLoading = browser.isLoading
                }
            },
            browser.observe(\.canGoBack, options: [.initial, .new]) { [weak self] browser, _ in
                Task { @MainActor [weak self] in
                    guard self?.webView === browser else { return }
                    self?.canGoBack = browser.canGoBack
                }
            }
        ]
        webView = browser
        DiagnosticLog.write("chess", "web view created")
        return browser
    }

    func back() { webView?.goBack() }
    func reload() {
        errorMessage = nil
        if let browser = webView, browser.url != nil { browser.reload() }
        else { open(destination) }
    }
    func signIn() {
        closedByUser = false
        let browser = webView ?? makeBrowser()
        errorMessage = nil
        browser.load(URLRequest(url: URL(string: "https://www.chess.com/login")!, timeoutInterval: 35))
    }
    func setZoom(_ value: CGFloat) {
        zoom = min(1.25, max(0.65, value))
        webView?.pageZoom = zoom
    }
    func openInBrowser() {
        let current = webView?.url
        NSWorkspace.shared.open(current.flatMap { ChessNavigation.isChess($0) ? $0 : nil } ?? destination.url)
    }
    func hide() {
        // WebKit throttles the hidden window. Keep the board and connection:
        // closing the window must not navigate away from a game.
        webView?.pauseAllMediaPlayback()
        hidden = true
        releaseWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.releaseInactivePage()
        }
        releaseWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 300, execute: work)
    }

    private func releaseInactivePage() {
        guard hidden, let browser = webView, !browser.isLoading,
              browser.url?.path.contains("/game/") != true else { return }
        // A board is treated as a live game even when the site's internal
        // game status is unavailable. Never infer that a hidden board ended.
        browser.evaluateJavaScript("document.querySelector('wc-chess-board,chess-board,.board') === null") { [weak self, weak browser] value, _ in
            MainActor.assumeIsolated {
                guard let self, self.hidden, self.webView === browser, value as? Bool == true else { return }
                self.unload()
                self.closedByUser = false
            }
        }
    }

    func unload() {
        releaseWork?.cancel()
        releaseWork = nil
        closedByUser = true
        observations.removeAll()
        webView?.stopLoading()
        webView?.navigationDelegate = nil
        webView?.uiDelegate = nil
        webView?.removeFromSuperview()
        webView = nil
        isLoading = false; canGoBack = false; errorMessage = nil
        DiagnosticLog.write("chess", "web view released; persistent site data retained")
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = action.request.url else { decisionHandler(.cancel); return }
        if action.targetFrame?.isMainFrame == false {
            // Normal site resources/challenges may live in third-party frames.
            decisionHandler(["https", "about", "data", "blob"].contains(url.scheme?.lowercased() ?? "") ? .allow : .cancel)
        } else if ChessNavigation.canLoadInside(url) {
            decisionHandler(.allow)
        } else {
            decisionHandler(.cancel)
            if action.navigationType == .linkActivated, url.scheme?.lowercased() == "https" {
                NSWorkspace.shared.open(url)
            }
        }
    }
    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        errorMessage = nil
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        errorMessage = nil
        DiagnosticLog.write("chess", "page loaded")
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        failed(error)
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { failed(error) }
    private func failed(_ error: Error) {
        guard (error as NSError).code != NSURLErrorCancelled else { return }
        errorMessage = "Не удалось загрузить Chess.com. Проверь подключение и повтори."
        isLoading = false
        DiagnosticLog.write("chess", "navigation failed: \((error as NSError).code)")
    }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        isLoading = false
        errorMessage = "Страница шахмат была выгружена системой. Нажми «Перезагрузить»."
    }
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        guard action.targetFrame == nil, let url = action.request.url else { return nil }
        if ChessNavigation.canLoadInside(url) { webView.load(action.request) }
        else if action.navigationType == .linkActivated, url.scheme?.lowercased() == "https" { NSWorkspace.shared.open(url) }
        return nil
    }
    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        guard let window = webView.window else { completionHandler(); return }
        let alert = NSAlert(); alert.messageText = "Chess.com"; alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.beginSheetModal(for: window) { _ in completionHandler() }
    }
    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        guard let window = webView.window else { completionHandler(false); return }
        let alert = NSAlert(); alert.messageText = "Chess.com"; alert.informativeText = message
        alert.addButton(withTitle: "Продолжить"); alert.addButton(withTitle: "Отмена")
        alert.beginSheetModal(for: window) { response in completionHandler(response == .alertFirstButtonReturn) }
    }
}

private final class ChessBrowserView: WKWebView {
    override var needsPanelToBecomeKey: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
