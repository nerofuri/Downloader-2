import Foundation
import SwiftUI

struct NewsArticle: Identifiable, Equatable {
    let id = UUID()
    let title: String
    let url: URL
    let source: String
    let published: Date?

    static func == (lhs: NewsArticle, rhs: NewsArticle) -> Bool { lhs.url == rhs.url }
}

/// Fetches a public Google News RSS feed and parses it for the home-page feed
/// (Chrome-Discover style). No API key required.
@MainActor
final class NewsService: ObservableObject {
    static let shared = NewsService()

    @Published var articles: [NewsArticle] = []
    @Published var isLoading = false

    private var lastFetch: Date?
    private let feedURL = URL(string: "https://news.google.com/rss?hl=en-US&gl=US&ceid=US:en")!

    func loadIfNeeded(force: Bool = false) {
        if !force, let last = lastFetch, Date().timeIntervalSince(last) < 900, !articles.isEmpty {
            return
        }
        guard !isLoading else { return }
        isLoading = true

        Task {
            var request = URLRequest(url: feedURL)
            request.setValue(browserUserAgent, forHTTPHeaderField: "User-Agent")
            defer { isLoading = false }
            do {
                let (data, _) = try await URLSession.shared.data(for: request)
                let parsed = RSSParser().parse(data)
                if !parsed.isEmpty {
                    self.articles = Array(parsed.prefix(25))
                    self.lastFetch = Date()
                }
            } catch {
                // Leave whatever is already loaded; the row shows a retry affordance.
            }
        }
    }
}

/// Minimal RSS <item> parser: title, link, source, pubDate.
private final class RSSParser: NSObject, XMLParserDelegate {
    private var articles: [NewsArticle] = []
    private var element = ""
    private var title = ""
    private var link = ""
    private var source = ""
    private var pubDate = ""
    private var insideItem = false

    private lazy var dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        return f
    }()

    func parse(_ data: Data) -> [NewsArticle] {
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.parse()
        return articles
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?,
                attributes attributeDict: [String: String] = [:]) {
        element = elementName
        if elementName == "item" {
            insideItem = true
            title = ""; link = ""; source = ""; pubDate = ""
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard insideItem else { return }
        switch element {
        case "title": title += string
        case "link": link += string
        case "source": source += string
        case "pubDate": pubDate += string
        default: break
        }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?) {
        guard elementName == "item" else { return }
        insideItem = false
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        // Google News titles end with " - Source"; split it out when no <source> tag.
        var cleanTitle = trimmedTitle
        var derivedSource = source.trimmingCharacters(in: .whitespacesAndNewlines)
        if derivedSource.isEmpty, let dash = trimmedTitle.range(of: " - ", options: .backwards) {
            cleanTitle = String(trimmedTitle[..<dash.lowerBound])
            derivedSource = String(trimmedTitle[dash.upperBound...])
        }
        guard let url = URL(string: link.trimmingCharacters(in: .whitespacesAndNewlines)),
              !cleanTitle.isEmpty else { return }
        articles.append(NewsArticle(title: cleanTitle, url: url,
                                    source: derivedSource.isEmpty ? "News" : derivedSource,
                                    published: dateFormatter.date(from: pubDate)))
    }
}

struct NewsCard: View {
    @ObservedObject var news = NewsService.shared
    let onOpen: (URL) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "newspaper.fill")
                    .foregroundStyle(Theme.accent)
                Text("Today's News")
                    .font(.headline)
                    .foregroundStyle(.white)
                Spacer()
                if news.isLoading {
                    ProgressView().tint(Theme.textSecondary)
                } else {
                    Button {
                        news.loadIfNeeded(force: true)
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.caption)
                            .foregroundStyle(Theme.textSecondary)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 10)

            if news.articles.isEmpty && !news.isLoading {
                Text("News couldn't load. Pull to refresh or tap ↻.")
                    .font(.footnote)
                    .foregroundStyle(Theme.textSecondary)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 16)
            } else {
                ForEach(Array(news.articles.prefix(12))) { article in
                    Button {
                        onOpen(article.url)
                    } label: {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(article.title)
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(.white)
                                .multilineTextAlignment(.leading)
                                .lineLimit(3)
                            HStack(spacing: 6) {
                                Text(article.source)
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(Theme.accent)
                                if let published = article.published {
                                    Text("· \(relativeTime(published))")
                                        .font(.caption2)
                                        .foregroundStyle(Theme.textSecondary)
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 11)
                    }
                    .buttonStyle(.plain)
                    if article.id != news.articles.prefix(12).last?.id {
                        Divider().overlay(Theme.stroke).padding(.leading, 16)
                    }
                }
            }
        }
        .padding(.bottom, 6)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 20))
        .overlay(RoundedRectangle(cornerRadius: 20).stroke(Theme.stroke, lineWidth: 1))
        .onAppear { news.loadIfNeeded() }
    }

    private func relativeTime(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}
