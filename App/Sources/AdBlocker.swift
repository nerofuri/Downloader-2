import Foundation
import WebKit

/// Compiles a WKContentRuleList that blocks requests to common ad/tracker networks
/// and hides frequent ad containers. Applied per-tab based on the user setting.
final class AdBlocker {
    static let shared = AdBlocker()
    static let enabledKey = "adblock.enabled"

    private(set) var ruleList: WKContentRuleList?
    private var isCompiling = false
    private var pending: [(WKContentRuleList?) -> Void] = []

    var isEnabled: Bool {
        UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool ?? true
    }

    func prepare(completion: ((WKContentRuleList?) -> Void)? = nil) {
        if let ruleList {
            completion?(ruleList)
            return
        }
        if let completion { pending.append(completion) }
        guard !isCompiling else { return }
        isCompiling = true
        WKContentRuleListStore.default().compileContentRuleList(
            forIdentifier: "downloader2-adblock",
            encodedContentRuleList: Self.rulesJSON
        ) { [weak self] list, _ in
            DispatchQueue.main.async {
                guard let self else { return }
                self.ruleList = list
                self.isCompiling = false
                let callbacks = self.pending
                self.pending = []
                callbacks.forEach { $0(list) }
            }
        }
    }

    func apply(to webView: WKWebView) {
        guard isEnabled else { return }
        prepare { list in
            guard let list else { return }
            webView.configuration.userContentController.add(list)
        }
    }

    func remove(from webView: WKWebView) {
        webView.configuration.userContentController.removeAllContentRuleLists()
    }

    private static let blockedDomains: [String] = [
        "doubleclick.net", "googlesyndication.com", "googleadservices.com",
        "adservice.google.com", "google-analytics.com", "googletagservices.com",
        "adnxs.com", "adsafeprotected.com", "adsrvr.org", "amazon-adsystem.com",
        "criteo.com", "criteo.net", "outbrain.com", "taboola.com", "pubmatic.com",
        "rubiconproject.com", "openx.net", "moatads.com", "scorecardresearch.com",
        "quantserve.com", "zedo.com", "popads.net", "propellerads.com",
        "exoclick.com", "juicyads.com", "trafficjunky.net", "adform.net",
        "smartadserver.com", "yieldmo.com", "bidswitch.net", "casalemedia.com",
        "33across.com", "sharethrough.com", "teads.tv", "undertone.com",
        "mgid.com", "revcontent.com", "adcolony.com", "applovin.com",
        "vungle.com", "popcash.net", "adsterra.com", "hilltopads.net",
        "onclickads.net", "adskeeper.com", "bebi.com", "exdynsrv.com",
        "clksite.com", "adtng.com", "tsyndicate.com", "ad-delivery.net"
    ]

    private static var rulesJSON: String {
        var rules: [[String: Any]] = blockedDomains.map { domain in
            [
                "trigger": ["url-filter": NSRegularExpression.escapedPattern(for: domain)],
                "action": ["type": "block"]
            ]
        }
        rules.append([
            "trigger": ["url-filter": ".*"],
            "action": [
                "type": "css-display-none",
                "selector": "ins.adsbygoogle, .adsbygoogle, [id^='google_ads_'], [id^='div-gpt-ad'], iframe[src*='doubleclick.net'], iframe[src*='googlesyndication'], .ad-banner, .ad-container, .advertisement, [class*='sponsored-ad']"
            ]
        ])
        let data = (try? JSONSerialization.data(withJSONObject: rules)) ?? Data("[]".utf8)
        return String(data: data, encoding: .utf8) ?? "[]"
    }
}
