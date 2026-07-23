import SwiftUI
import WebKit

struct WebView: UIViewRepresentable {
    let webView: WKWebView
    func makeUIView(context: Context) -> WKWebView { webView }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}

struct BrowserScreen: View {
    @ObservedObject var tab: BrowserTab
    @EnvironmentObject var tabManager: TabManager
    @EnvironmentObject var downloads: DownloadManager
    @ObservedObject private var bookmarkStore = BookmarkStore.shared

    @State private var omniboxText = ""
    @FocusState private var omniboxFocused: Bool
    @State private var showTabSwitcher = false
    @State private var showDownloads = false
    @State private var showBookmarks = false
    @State private var showFiles = false
    @State private var showSettings = false
    @State private var showMediaSheet = false
    @State private var showBatchSheet = false
    @State private var toast: String?

    private var activeDownloadCount: Int {
        downloads.items.filter { $0.state == .downloading || $0.state == .queued }.count
    }

    var body: some View {
        VStack(spacing: 0) {
            if !tab.showingNewTabPage || omniboxFocused {
                topBar
                progressBar
            }
            ZStack(alignment: .bottomTrailing) {
                content
                if omniboxFocused {
                    // While editing the address, tapping the page dismisses the
                    // keyboard instead of interacting with the site.
                    Color.black.opacity(0.35)
                        .ignoresSafeArea(edges: .bottom)
                        .onTapGesture { omniboxFocused = false }
                        .transition(.opacity)
                }
                if !tab.detected.isEmpty && !omniboxFocused {
                    mediaBadge
                        .transition(.scale.combined(with: .opacity))
                }
                if let toast {
                    toastView(toast)
                }
            }
            .animation(.spring(duration: 0.3), value: tab.detected.count)
            .animation(.easeInOut(duration: 0.2), value: omniboxFocused)
            bottomBar
        }
        .background(Theme.bg.ignoresSafeArea())
        .fullScreenCover(isPresented: $showTabSwitcher) { TabSwitcherView() }
        .sheet(isPresented: $showDownloads) { DownloadsView() }
        .sheet(isPresented: $showBookmarks) { BookmarksView() }
        .sheet(isPresented: $showFiles) { FilesView() }
        .sheet(isPresented: $showSettings) { SettingsView() }
        .sheet(isPresented: $showMediaSheet) { MediaSheet(tab: tab) }
        .sheet(isPresented: $showBatchSheet) { BatchDownloadSheet() }
        .onReceive(downloads.$lastMessage) { message in
            guard let message else { return }
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            withAnimation { toast = message }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                withAnimation { if toast == message { toast = nil } }
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if tab.showingNewTabPage {
            NewTabPage(tab: tab,
                       omniboxFocused: $omniboxFocused,
                       showSettings: $showSettings,
                       menuItems: { AnyView(menuItems) })
        } else {
            WebView(webView: tab.webView)
                .ignoresSafeArea(.keyboard)
        }
    }

    @ViewBuilder
    private var progressBar: some View {
        if tab.isLoading {
            ProgressView(value: max(tab.progress, 0.05))
                .progressViewStyle(.linear)
                .tint(Theme.accent)
                .frame(height: 2)
        } else {
            Color.clear.frame(height: 2)
        }
    }

    // MARK: - Top bar

    private var displayTitle: String {
        if tab.showingNewTabPage || tab.urlString.isEmpty { return "Search or type URL" }
        if let host = URL(string: tab.urlString)?.host {
            return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        }
        return tab.urlString
    }

    private var topBar: some View {
        HStack(spacing: 6) {
            if !tab.showingNewTabPage && !omniboxFocused {
                Button { tab.goBack() } label: {
                    Image(systemName: "chevron.backward")
                        .font(.body.weight(.semibold))
                        .frame(width: 34, height: 34)
                }
                .disabled(!tab.canGoBack)
                .opacity(tab.canGoBack ? 1 : 0.35)
                Button { tab.goForward() } label: {
                    Image(systemName: "chevron.forward")
                        .font(.body.weight(.semibold))
                        .frame(width: 34, height: 34)
                }
                .disabled(!tab.canGoForward)
                .opacity(tab.canGoForward ? 1 : 0.35)
            }

            omniboxCapsule

            if omniboxFocused {
                Button("Cancel") {
                    omniboxFocused = false
                    omniboxText = tab.urlString
                }
                .font(.subheadline)
                .foregroundStyle(Theme.accent)
                .transition(.move(edge: .trailing).combined(with: .opacity))
            } else if !tab.showingNewTabPage {
                Menu {
                    menuItems
                } label: {
                    ZStack(alignment: .topTrailing) {
                        Image(systemName: "ellipsis")
                            .font(.body.weight(.semibold))
                            .frame(width: 34, height: 34)
                        if activeDownloadCount > 0 {
                            Circle().fill(Theme.accent).frame(width: 8, height: 8)
                                .offset(x: -4, y: 4)
                        }
                    }
                }
            }
        }
        .foregroundStyle(.white)
        .animation(.easeInOut(duration: 0.2), value: omniboxFocused)
        .padding(.horizontal, 12)
        .padding(.top, 6)
        .padding(.bottom, 6)
    }

    private var omniboxCapsule: some View {
        HStack(spacing: 8) {
            Image(systemName: tab.isIncognito ? "eyeglasses"
                  : (tab.urlString.hasPrefix("https") ? "lock.fill" : "magnifyingglass"))
                .font(.footnote)
                .foregroundStyle(Theme.textSecondary)

            ZStack(alignment: .leading) {
                TextField("", text: $omniboxText,
                          prompt: Text("Search or type URL").foregroundColor(Theme.textSecondary))
                    .focused($omniboxFocused)
                    .keyboardType(.webSearch)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.go)
                    .foregroundStyle(.white)
                    .onSubmit {
                        tab.submit(omniboxText)
                        omniboxFocused = false
                    }
                    .opacity(omniboxFocused ? 1 : 0)

                if !omniboxFocused {
                    Text(displayTitle)
                        .lineLimit(1)
                        .foregroundStyle(tab.showingNewTabPage ? Theme.textSecondary : .white)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            omniboxText = tab.showingNewTabPage ? "" : tab.urlString
                            omniboxFocused = true
                        }
                }
            }

            if omniboxFocused {
                if !omniboxText.isEmpty {
                    Button { omniboxText = "" } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.textSecondary)
                    }
                }
            } else if tab.isLoading {
                Button { tab.stop() } label: {
                    Image(systemName: "xmark").font(.footnote).foregroundStyle(Theme.textSecondary)
                }
            } else if !tab.showingNewTabPage {
                Button { tab.reload() } label: {
                    Image(systemName: "arrow.clockwise").font(.footnote).foregroundStyle(Theme.textSecondary)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Theme.card)
        .clipShape(Capsule())
        .overlay {
            Capsule().stroke(omniboxFocused ? AnyShapeStyle(Theme.accentGradient)
                                            : AnyShapeStyle(Theme.stroke), lineWidth: 1.2)
        }
    }

    @ViewBuilder
    private var menuItems: some View {
        Button { tabManager.newTab() } label: {
            Label("New tab", systemImage: "plus.square")
        }
        Button { tabManager.newTab(incognito: true) } label: {
            Label("New Incognito tab", systemImage: "eyeglasses")
        }
        Divider()
        if let url = tab.webView.url, !tab.showingNewTabPage {
            Button {
                bookmarkStore.toggle(title: tab.title, url: url)
            } label: {
                Label(bookmarkStore.isBookmarked(url) ? "Remove bookmark" : "Add bookmark",
                      systemImage: bookmarkStore.isBookmarked(url) ? "bookmark.slash" : "bookmark")
            }
        }
        Button { showBatchSheet = true } label: {
            Label("Batch download…", systemImage: "square.stack.3d.down.right")
        }
        Button { showFiles = true } label: {
            Label("Files", systemImage: "folder")
        }
        Divider()
        Button { tab.setDesktopMode(!tab.desktopMode) } label: {
            Label(tab.desktopMode ? "Mobile site" : "Desktop site",
                  systemImage: tab.desktopMode ? "iphone" : "desktopcomputer")
        }
        if let url = tab.webView.url {
            ShareLink(item: url) {
                Label("Share", systemImage: "square.and.arrow.up")
            }
        }
        if !tab.showingNewTabPage {
            Button { tab.reload() } label: {
                Label("Reload", systemImage: "arrow.clockwise")
            }
        }
        Divider()
        Button { showSettings = true } label: {
            Label("Settings", systemImage: "gearshape")
        }
    }

    // MARK: - Bottom bar (Home · Bookmarks · Tab · Download)

    private var bottomBar: some View {
        HStack(spacing: 4) {
            barButton(icon: "house.fill", label: "Home",
                      selected: tab.showingNewTabPage) {
                tab.goHome()
            }
            barButton(icon: "book", label: "Bookmarks", selected: false) {
                showBookmarks = true
            }
            tabsButton
            barButton(icon: "arrow.down.to.line", label: "Download",
                      selected: false, badge: activeDownloadCount > 0) {
                showDownloads = true
            }
        }
        .padding(.horizontal, 10)
        .padding(.top, 8)
        .padding(.bottom, 2)
        .background(Theme.card.ignoresSafeArea(edges: .bottom))
        .overlay(Rectangle().fill(Theme.stroke).frame(height: 0.5), alignment: .top)
    }

    private func barButton(icon: String, label: String, selected: Bool,
                           badge: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                ZStack(alignment: .topTrailing) {
                    Image(systemName: icon)
                        .font(.system(size: 19, weight: .medium))
                    if badge {
                        Circle().fill(Theme.accent).frame(width: 8, height: 8)
                            .offset(x: 6, y: -2)
                    }
                }
                Text(label)
                    .font(.caption2)
            }
            .foregroundStyle(selected ? Theme.accent : Theme.textSecondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 7)
            .background {
                if selected {
                    RoundedRectangle(cornerRadius: 12).fill(Theme.cardInner)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var tabsButton: some View {
        Button { showTabSwitcher = true } label: {
            VStack(spacing: 4) {
                ZStack {
                    RoundedRectangle(cornerRadius: 5)
                        .stroke(lineWidth: 1.7)
                        .frame(width: 21, height: 21)
                    Text("\(tabManager.tabs.count)")
                        .font(.system(size: 11, weight: .bold))
                }
                Text("Tab")
                    .font(.caption2)
            }
            .foregroundStyle(Theme.textSecondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 7)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Media badge & toast

    private var mediaBadge: some View {
        Button { showMediaSheet = true } label: {
            HStack(spacing: 6) {
                Image(systemName: "arrow.down.circle.fill")
                Text("\(tab.detected.count)")
                    .font(.subheadline.bold())
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Theme.accentGradient, in: Capsule())
            .foregroundStyle(.white)
            .shadow(color: Theme.accent.opacity(0.5), radius: 8, y: 3)
        }
        .padding(.trailing, 16)
        .padding(.bottom, 16)
    }

    private func toastView(_ message: String) -> some View {
        VStack {
            Spacer()
            Text(message)
                .font(.footnote.weight(.medium))
                .foregroundStyle(.white)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(Theme.cardInner, in: Capsule())
                .overlay(Capsule().stroke(Theme.stroke, lineWidth: 1))
                .shadow(color: .black.opacity(0.4), radius: 8, y: 3)
                .padding(.bottom, 60)
        }
        .frame(maxWidth: .infinity)
        .transition(.move(edge: .bottom).combined(with: .opacity))
        .allowsHitTesting(false)
    }
}

// MARK: - New tab page

struct NewTabPage: View {
    @ObservedObject var tab: BrowserTab
    var omniboxFocused: FocusState<Bool>.Binding
    @Binding var showSettings: Bool
    let menuItems: () -> AnyView

    @State private var homeQuery = ""
    @FocusState private var homeSearchFocused: Bool

    private let shortcuts: [(title: String, url: String, icon: String, color: Color)] = [
        ("Google", "https://www.google.com", "magnifyingglass", .blue),
        ("YouTube", "https://www.youtube.com", "play.rectangle.fill", .red),
        ("Wikipedia", "https://www.wikipedia.org", "book.fill", .gray),
        ("Reddit", "https://www.reddit.com", "bubble.left.and.bubble.right.fill", .orange),
        ("X", "https://x.com", "at", .white),
        ("Vimeo", "https://vimeo.com", "video.fill", .teal),
        ("Archive", "https://archive.org", "building.columns.fill", .indigo),
        ("GitHub", "https://github.com", "chevron.left.forwardslash.chevron.right", .purple)
    ]

    private let trending = [
        "Cricket World Cup", "Bitcoin price", "Weather forecast",
        "AI image generator", "Latest smartphones", "Movie releases", "YouTube trending"
    ]

    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                header
                if tab.isIncognito {
                    incognitoBody
                } else {
                    branding
                    searchBar
                    shortcutsCard
                    trendingCard
                    NewsCard { url in tab.load(url) }
                }
                Spacer().frame(height: 20)
            }
            .padding(.horizontal, 16)
        }
        .scrollDismissesKeyboard(.immediately)
        .background(Theme.bg)
        .onTapGesture { homeSearchFocused = false }
    }

    private var header: some View {
        HStack {
            Menu {
                menuItems()
            } label: {
                Image(systemName: "line.3.horizontal")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(width: 40, height: 40)
            }
            Spacer()
            Button { showSettings = true } label: {
                Image(systemName: "person.crop.circle.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(Theme.textSecondary)
            }
        }
        .padding(.top, 8)
    }

    private var branding: some View {
        VStack(spacing: 10) {
            AppLogo(size: 68)
            Text("Downloader 2")
                .font(.system(size: 30, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
            HStack(spacing: 8) {
                taglineWord("Fast")
                Circle().fill(Theme.textSecondary).frame(width: 3, height: 3)
                taglineWord("Private")
                Circle().fill(Theme.textSecondary).frame(width: 3, height: 3)
                taglineWord("Smart")
            }
        }
        .padding(.top, 4)
    }

    private func taglineWord(_ word: String) -> some View {
        Text(word)
            .font(.footnote)
            .foregroundStyle(Theme.textSecondary)
    }

    private var searchBar: some View {
        HStack(spacing: 10) {
            Button {
                submitHomeSearch()
            } label: {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(homeSearchFocused ? Theme.accent : Theme.textSecondary)
            }
            .buttonStyle(.plain)

            TextField("", text: $homeQuery,
                      prompt: Text("Search").foregroundColor(Theme.textSecondary))
                .focused($homeSearchFocused)
                .keyboardType(.webSearch)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.go)
                .foregroundStyle(.white)
                .onSubmit { submitHomeSearch() }

            if !homeQuery.isEmpty {
                Button { homeQuery = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.textSecondary)
                }
                .buttonStyle(.plain)
            } else {
                Image(systemName: "mic.fill").foregroundStyle(Theme.textSecondary)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 15)
        .background(Theme.card, in: Capsule())
        .overlay(Capsule().stroke(homeSearchFocused
                                  ? AnyShapeStyle(Theme.accentGradient)
                                  : AnyShapeStyle(Theme.stroke), lineWidth: 1.3))
    }

    private func submitHomeSearch() {
        let query = homeQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            homeSearchFocused = true
            return
        }
        tab.submit(query)
        homeQuery = ""
        homeSearchFocused = false
    }

    private var shortcutsCard: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 18) {
                ForEach(shortcuts, id: \.url) { shortcut in
                    Button {
                        if let url = URL(string: shortcut.url) { tab.load(url) }
                    } label: {
                        VStack(spacing: 7) {
                            ZStack {
                                Circle().fill(Theme.cardInner)
                                Image(systemName: shortcut.icon)
                                    .font(.title3)
                                    .foregroundStyle(shortcut.color)
                            }
                            .frame(width: 54, height: 54)
                            Text(shortcut.title)
                                .font(.caption2)
                                .foregroundStyle(.white)
                                .lineLimit(1)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
        }
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 20))
        .overlay(RoundedRectangle(cornerRadius: 20).stroke(Theme.stroke, lineWidth: 1))
    }

    private var trendingCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "flame.fill")
                    .foregroundStyle(.orange)
                Text("Trending Searches")
                    .font(.headline)
                    .foregroundStyle(.white)
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 6)

            ForEach(trending, id: \.self) { query in
                Button {
                    tab.submit(query)
                } label: {
                    HStack(spacing: 12) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 8).fill(Theme.cardInner)
                            Image(systemName: "chart.line.uptrend.xyaxis")
                                .font(.caption)
                                .foregroundStyle(Theme.accent)
                        }
                        .frame(width: 30, height: 30)
                        Text(query)
                            .font(.subheadline)
                            .foregroundStyle(.white)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Theme.textSecondary)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 11)
                }
                .buttonStyle(.plain)
                if query != trending.last {
                    Divider().overlay(Theme.stroke).padding(.leading, 58)
                }
            }
        }
        .padding(.bottom, 6)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 20))
        .overlay(RoundedRectangle(cornerRadius: 20).stroke(Theme.stroke, lineWidth: 1))
    }

    // MARK: - Incognito start page

    private var incognitoBody: some View {
        VStack(spacing: 22) {
            ZStack {
                Circle()
                    .fill(Theme.accent.opacity(0.12))
                    .frame(width: 150, height: 150)
                Circle()
                    .stroke(Theme.accentGradient, lineWidth: 2)
                    .frame(width: 122, height: 122)
                Image(systemName: "eyeglasses")
                    .font(.system(size: 46, weight: .semibold))
                    .foregroundStyle(Theme.accent)
            }
            .shadow(color: Theme.accent.opacity(0.35), radius: 26)
            .padding(.top, 20)

            VStack(spacing: 8) {
                Text("Incognito Mode")
                    .font(.title2.bold())
                    .foregroundStyle(.white)
                Text("Your browsing activity is private and won't be saved in the browser. Downloads and bookmarks will be saved.")
                    .font(.footnote)
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 20)
            }

            searchBar

            VStack(spacing: 0) {
                incognitoRow(icon: "eye.slash", title: "Your activity won't be saved",
                             subtitle: "No history, cookies or form data saved")
                Divider().overlay(Theme.stroke).padding(.leading, 60)
                incognitoRow(icon: "arrow.down.circle", title: "Downloads are saved",
                             subtitle: "Files you download are kept")
                Divider().overlay(Theme.stroke).padding(.leading, 60)
                incognitoRow(icon: "bookmark", title: "Bookmarks are saved",
                             subtitle: "Bookmarks you add are kept")
            }
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 20))
            .overlay(RoundedRectangle(cornerRadius: 20).stroke(Theme.stroke, lineWidth: 1))

            Button {
                submitHomeSearch()
            } label: {
                HStack {
                    Image(systemName: "magnifyingglass")
                    Text("Start browsing")
                }
                .font(.subheadline.bold())
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 15)
                .background(Theme.accentGradient, in: Capsule())
            }
            .buttonStyle(.plain)
        }
    }

    private func incognitoRow(icon: String, title: String, subtitle: String) -> some View {
        HStack(spacing: 14) {
            ZStack {
                Circle().fill(Theme.cardInner)
                Image(systemName: icon)
                    .font(.subheadline)
                    .foregroundStyle(Theme.accent)
            }
            .frame(width: 38, height: 38)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
            }
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }
}

// MARK: - Tab switcher

struct TabSwitcherView: View {
    @EnvironmentObject var tabManager: TabManager
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Tabs")
                    .font(.title2.bold())
                    .foregroundStyle(.white)
                Spacer()
                Menu {
                    Button("New Incognito tab") { tabManager.newTab(incognito: true); dismiss() }
                    Button("Close all tabs", role: .destructive) { closeAll() }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.white)
                        .frame(width: 38, height: 38)
                }
                Button { dismiss() } label: {
                    Text("Done")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.accent)
                }
            }
            .padding(.horizontal, 18)
            .padding(.top, 14)
            .padding(.bottom, 8)

            ScrollView {
                LazyVStack(spacing: 12) {
                    ForEach(tabManager.tabs) { tab in
                        tabCard(tab)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 130)
            }
        }
        .background(Theme.bg.ignoresSafeArea())
        .overlay(alignment: .bottom) {
            VStack(spacing: 12) {
                Button {
                    tabManager.newTab()
                    dismiss()
                } label: {
                    HStack {
                        Image(systemName: "plus")
                        Text("New Tab")
                    }
                    .font(.subheadline.bold())
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 15)
                    .background(Theme.accentGradient, in: Capsule())
                    .shadow(color: Theme.accent.opacity(0.4), radius: 10, y: 4)
                }
                .buttonStyle(.plain)
                Button("Close All") { closeAll() }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.85))
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 14)
            .background(
                LinearGradient(colors: [Theme.bg.opacity(0), Theme.bg, Theme.bg],
                               startPoint: .top, endPoint: .bottom)
                    .ignoresSafeArea(edges: .bottom)
            )
        }
    }

    private func closeAll() {
        for tab in tabManager.tabs {
            tabManager.close(tab)
        }
        dismiss()
    }

    private func hostLetter(_ tab: BrowserTab) -> String {
        guard let host = URL(string: tab.urlString)?.host?.replacingOccurrences(of: "www.", with: ""),
              let first = host.first else { return "•" }
        return String(first).uppercased()
    }

    private func tabCard(_ tab: BrowserTab) -> some View {
        Button {
            tabManager.select(tab)
            dismiss()
        } label: {
            VStack(spacing: 10) {
                HStack(spacing: 12) {
                    ZStack {
                        Circle().fill(Theme.cardInner)
                        if tab.isIncognito {
                            Image(systemName: "eyeglasses")
                                .font(.subheadline)
                                .foregroundStyle(Theme.accent)
                        } else {
                            Text(hostLetter(tab))
                                .font(.subheadline.bold())
                                .foregroundStyle(Theme.accent)
                        }
                    }
                    .frame(width: 40, height: 40)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(tab.title)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                        Text(tab.showingNewTabPage || tab.urlString.isEmpty
                             ? "New Tab"
                             : (URL(string: tab.urlString)?.host ?? tab.urlString))
                            .font(.caption)
                            .foregroundStyle(Theme.textSecondary)
                            .lineLimit(1)
                    }
                    Spacer()
                    Button {
                        withAnimation { tabManager.close(tab) }
                    } label: {
                        Image(systemName: "xmark")
                            .font(.caption.bold())
                            .foregroundStyle(Theme.textSecondary)
                            .frame(width: 30, height: 30)
                            .background(Theme.cardInner, in: Circle())
                    }
                    .buttonStyle(.plain)
                }

                RoundedRectangle(cornerRadius: 12)
                    .fill(Theme.cardInner)
                    .frame(height: 74)
                    .overlay {
                        VStack(spacing: 5) {
                            Image(systemName: tab.showingNewTabPage ? "plus.square.dashed" : "doc.text.image")
                                .font(.title3)
                                .foregroundStyle(Theme.textSecondary)
                            Text(tab.showingNewTabPage || tab.urlString.isEmpty ? "Start page" : tab.urlString)
                                .font(.caption2)
                                .foregroundStyle(Theme.textSecondary)
                                .lineLimit(1)
                                .padding(.horizontal, 12)
                        }
                    }
            }
            .padding(12)
            .background(Theme.card)
            .clipShape(RoundedRectangle(cornerRadius: 18))
            .overlay {
                RoundedRectangle(cornerRadius: 18)
                    .stroke(tab.id == tabManager.activeTabID
                            ? AnyShapeStyle(Theme.accentGradient)
                            : AnyShapeStyle(Theme.stroke),
                            lineWidth: tab.id == tabManager.activeTabID ? 1.6 : 1)
            }
        }
        .buttonStyle(.plain)
    }
}
