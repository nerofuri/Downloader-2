import Foundation
import WebKit
import UIKit
import Combine

/// JavaScript injected into every frame. Watches <video>/<audio> elements and hooks
/// fetch/XHR so media URLs (mp4, m3u8, webm, ...) requested by players are detected.
private let snifferScript = """
(function() {
  if (window.__d2sniff) { return; }
  window.__d2sniff = true;
  var seen = {};
  var mediaExt = /\\.(m3u8|mpd|mp4|m4v|mov|webm|mkv|flv|avi|wmv|3gp|mp3|m4a|aac|ogg|opus|wav)([?#]|$)/i;
  function kindFor(url) {
    if (/\\.m3u8([?#]|$)/i.test(url)) return 'hls';
    if (/\\.mpd([?#]|$)/i.test(url)) return 'dash';
    if (/\\.(mp3|m4a|aac|ogg|opus|wav)([?#]|$)/i.test(url)) return 'audio';
    return 'video';
  }
  function report(url) {
    try {
      if (!url || typeof url !== 'string') { return; }
      if (url.indexOf('blob:') === 0 || url.indexOf('data:') === 0) { return; }
      var abs = new URL(url, location.href).href;
      if (seen[abs]) { return; }
      if (!mediaExt.test(abs)) { return; }
      seen[abs] = true;
      window.webkit.messageHandlers.sniffer.postMessage({
        url: abs,
        kind: kindFor(abs),
        title: document.title || '',
        page: location.href
      });
    } catch (e) {}
  }
  function scan() {
    var els = document.querySelectorAll('video, audio, source');
    for (var i = 0; i < els.length; i++) {
      report(els[i].currentSrc || els[i].src);
    }
  }
  if (window.fetch) {
    var origFetch = window.fetch;
    window.fetch = function(input) {
      try { report(typeof input === 'string' ? input : (input && input.url)); } catch (e) {}
      return origFetch.apply(this, arguments);
    };
  }
  var origOpen = XMLHttpRequest.prototype.open;
  XMLHttpRequest.prototype.open = function(method, url) {
    try { report(url); } catch (e) {}
    return origOpen.apply(this, arguments);
  };
  document.addEventListener('DOMContentLoaded', scan);
  setInterval(scan, 2000);
})();
"""

private let desktopUA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"

final class WeakScriptMessageHandler: NSObject, WKScriptMessageHandler {
    weak var delegate: WKScriptMessageHandler?
    init(delegate: WKScriptMessageHandler) { self.delegate = delegate }
    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        delegate?.userContentController(userContentController, didReceive: message)
    }
}

final class BrowserTab: NSObject, ObservableObject, Identifiable {
    let id = UUID()
    let isIncognito: Bool
    let webView: WKWebView

    @Published var title = "New Tab"
    @Published var urlString = ""
    @Published var progress: Double = 0
    @Published var isLoading = false
    @Published var canGoBack = false
    @Published var canGoForward = false
    @Published var detected: [DetectedMedia] = []
    @Published var showingNewTabPage = true
    @Published var desktopMode = false

    private var observations: [NSKeyValueObservation] = []

    init(incognito: Bool = false) {
        self.isIncognito = incognito
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.allowsPictureInPictureMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        if incognito {
            config.websiteDataStore = .nonPersistent()
        }
        let script = WKUserScript(source: snifferScript,
                                  injectionTime: .atDocumentStart,
                                  forMainFrameOnly: false)
        config.userContentController.addUserScript(script)
        webView = WKWebView(frame: .zero, configuration: config)
        webView.allowsBackForwardNavigationGestures = true
        webView.scrollView.keyboardDismissMode = .onDrag
        super.init()

        config.userContentController.add(WeakScriptMessageHandler(delegate: self), name: "sniffer")
        webView.navigationDelegate = self
        webView.uiDelegate = self
        AdBlocker.shared.apply(to: webView)

        let refresh = UIRefreshControl()
        refresh.addTarget(self, action: #selector(handleRefresh), for: .valueChanged)
        webView.scrollView.refreshControl = refresh

        observations = [
            webView.observe(\.estimatedProgress, options: [.new]) { [weak self] view, _ in
                DispatchQueue.main.async { self?.progress = view.estimatedProgress }
            },
            webView.observe(\.isLoading, options: [.new]) { [weak self] view, _ in
                DispatchQueue.main.async { self?.isLoading = view.isLoading }
            },
            webView.observe(\.title, options: [.new]) { [weak self] view, _ in
                DispatchQueue.main.async {
                    if let title = view.title, !title.isEmpty { self?.title = title }
                }
            },
            webView.observe(\.url, options: [.new]) { [weak self] view, _ in
                DispatchQueue.main.async {
                    if let url = view.url { self?.urlString = url.absoluteString }
                }
            },
            webView.observe(\.canGoBack, options: [.new]) { [weak self] view, _ in
                DispatchQueue.main.async { self?.canGoBack = view.canGoBack }
            },
            webView.observe(\.canGoForward, options: [.new]) { [weak self] view, _ in
                DispatchQueue.main.async { self?.canGoForward = view.canGoForward }
            }
        ]
    }

    deinit {
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "sniffer")
    }

    // MARK: - Navigation

    /// Loads a typed omnibox entry: URL if it looks like one, web search otherwise.
    func submit(_ input: String) {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if let url = Self.urlFromInput(trimmed) {
            load(url)
        } else {
            load(SearchEngine.current.searchURL(for: trimmed))
        }
    }

    func load(_ url: URL) {
        showingNewTabPage = false
        webView.load(URLRequest(url: url))
    }

    func reload() {
        if webView.url != nil { webView.reload() }
    }

    func stop() { webView.stopLoading() }
    func goBack() { webView.goBack() }
    func goForward() { webView.goForward() }

    @objc private func handleRefresh() {
        if webView.url != nil {
            webView.reload()
        } else {
            webView.scrollView.refreshControl?.endRefreshing()
        }
    }

    /// Cookies of this tab's data store (incognito tabs have their own ephemeral store).
    func currentCookies(_ completion: @escaping ([HTTPCookie]) -> Void) {
        webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { cookies in
            DispatchQueue.main.async { completion(cookies) }
        }
    }

    func setDesktopMode(_ enabled: Bool) {
        desktopMode = enabled
        webView.customUserAgent = enabled ? desktopUA : nil
        reload()
    }

    func setAdBlock(_ enabled: Bool) {
        if enabled {
            AdBlocker.shared.apply(to: webView)
        } else {
            AdBlocker.shared.remove(from: webView)
        }
        reload()
    }

    static func urlFromInput(_ input: String) -> URL? {
        if input.contains(" ") { return nil }
        if input.lowercased().hasPrefix("http://") || input.lowercased().hasPrefix("https://") {
            return URL(string: input)
        }
        if input.contains(".") {
            return URL(string: "https://" + input)
        }
        return nil
    }
}

// MARK: - WKNavigationDelegate

extension BrowserTab: WKNavigationDelegate {
    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        DispatchQueue.main.async {
            self.detected.removeAll()
            self.showingNewTabPage = false
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        webView.scrollView.refreshControl?.endRefreshing()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        webView.scrollView.refreshControl?.endRefreshing()
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
                 withError error: Error) {
        webView.scrollView.refreshControl?.endRefreshing()
    }

    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else {
            decisionHandler(.allow)
            return
        }
        let scheme = url.scheme?.lowercased() ?? ""
        if !["http", "https", "about", "blob", "data", "file"].contains(scheme) {
            UIApplication.shared.open(url, options: [:], completionHandler: nil)
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }

    /// IDM-style download catch: any response WebKit cannot display (zip, pdf attachments,
    /// binaries, media files navigated to directly, ...) is turned into a download.
    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationResponse: WKNavigationResponse,
                 decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        if !navigationResponse.canShowMIMEType, let url = navigationResponse.response.url {
            let name = navigationResponse.response.suggestedFilename ?? url.lastPathComponent
            DownloadManager.shared.enqueueFile(url: url, fileName: name, pageTitle: title)
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }

    // Open target=_blank links in the same tab.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction,
                 windowFeatures: WKWindowFeatures) -> WKWebView? {
        if navigationAction.targetFrame == nil {
            webView.load(navigationAction.request)
        }
        return nil
    }
}

extension BrowserTab: WKUIDelegate {}

// MARK: - Sniffer messages

extension BrowserTab: WKScriptMessageHandler {
    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        guard message.name == "sniffer",
              let body = message.body as? [String: Any],
              let urlString = body["url"] as? String,
              let url = URL(string: urlString) else { return }
        let kind = body["kind"] as? String ?? "video"
        let pageTitle = (body["title"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? title
        let pageURL = body["page"] as? String ?? webView.url?.absoluteString
        let media = DetectedMedia(url: url, kind: kind, pageTitle: pageTitle, pageURL: pageURL)
        DispatchQueue.main.async {
            if !self.detected.contains(media) {
                self.detected.append(media)
            }
        }
    }
}

// MARK: - Tab manager

final class TabManager: ObservableObject {
    @Published var tabs: [BrowserTab] = []
    @Published var activeTabID: UUID?

    var activeTab: BrowserTab? { tabs.first { $0.id == activeTabID } }

    init() {
        newTab()
    }

    @discardableResult
    func newTab(incognito: Bool = false, url: URL? = nil) -> BrowserTab {
        let tab = BrowserTab(incognito: incognito)
        tabs.append(tab)
        activeTabID = tab.id
        if let url { tab.load(url) }
        return tab
    }

    func close(_ tab: BrowserTab) {
        tabs.removeAll { $0.id == tab.id }
        if activeTabID == tab.id {
            activeTabID = tabs.last?.id
        }
        if tabs.isEmpty {
            newTab()
        }
    }

    func select(_ tab: BrowserTab) {
        activeTabID = tab.id
    }

    func setAdBlockEverywhere(_ enabled: Bool) {
        tabs.forEach { $0.setAdBlock(enabled) }
    }
}

// MARK: - Search engine

enum SearchEngine: String, CaseIterable, Identifiable {
    case google, duckduckgo, bing

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .google: return "Google"
        case .duckduckgo: return "DuckDuckGo"
        case .bing: return "Bing"
        }
    }

    func searchURL(for query: String) -> URL {
        let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
        switch self {
        case .google: return URL(string: "https://www.google.com/search?q=\(encoded)")!
        case .duckduckgo: return URL(string: "https://duckduckgo.com/?q=\(encoded)")!
        case .bing: return URL(string: "https://www.bing.com/search?q=\(encoded)")!
        }
    }

    static var current: SearchEngine {
        get {
            UserDefaults.standard.string(forKey: "search.engine")
                .flatMap(SearchEngine.init(rawValue:)) ?? .google
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "search.engine") }
    }

    static func setCurrent(_ engine: SearchEngine) {
        UserDefaults.standard.set(engine.rawValue, forKey: "search.engine")
    }
}
