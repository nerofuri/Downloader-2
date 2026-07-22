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

    @State private var omniboxText = ""
    @FocusState private var omniboxFocused: Bool
    @State private var showTabSwitcher = false
    @State private var showDownloads = false
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
            omnibox
            progressBar
            ZStack(alignment: .bottomTrailing) {
                content
                if omniboxFocused {
                    // Chrome-style: while editing the address, tapping the page
                    // dismisses the keyboard instead of interacting with the site.
                    Color.black.opacity(0.25)
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
            bottomToolbar
        }
        .background(Color(.systemBackground))
        .sheet(isPresented: $showTabSwitcher) { TabSwitcherView() }
        .sheet(isPresented: $showDownloads) { DownloadsView() }
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
            NewTabPage(tab: tab, omniboxFocused: $omniboxFocused)
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
                .tint(.blue)
                .frame(height: 2)
        } else {
            Color.clear.frame(height: 2)
        }
    }

    // MARK: - Omnibox (Chrome-style top bar)

    private var displayTitle: String {
        if tab.showingNewTabPage || tab.urlString.isEmpty { return "Search or type URL" }
        if let host = URL(string: tab.urlString)?.host {
            return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        }
        return tab.urlString
    }

    private var omnibox: some View {
        HStack(spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: tab.isIncognito ? "eyeglasses"
                      : (tab.urlString.hasPrefix("https") ? "lock.fill" : "magnifyingglass"))
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                ZStack(alignment: .leading) {
                    TextField("Search or type URL", text: $omniboxText)
                        .focused($omniboxFocused)
                        .keyboardType(.webSearch)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.go)
                        .onSubmit {
                            tab.submit(omniboxText)
                            omniboxFocused = false
                        }
                        .opacity(omniboxFocused ? 1 : 0)

                    if !omniboxFocused {
                        // Compact display (domain only), tap to edit the full URL.
                        Text(displayTitle)
                            .lineLimit(1)
                            .foregroundStyle(tab.showingNewTabPage ? .secondary : .primary)
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
                        Button {
                            omniboxText = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                        }
                    }
                } else if tab.isLoading {
                    Button { tab.stop() } label: {
                        Image(systemName: "xmark").font(.footnote).foregroundStyle(.secondary)
                    }
                } else if !tab.showingNewTabPage {
                    Button { tab.reload() } label: {
                        Image(systemName: "arrow.clockwise").font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(Color(.secondarySystemBackground))
            .clipShape(Capsule())

            if omniboxFocused {
                Button("Cancel") {
                    omniboxFocused = false
                    omniboxText = tab.urlString
                }
                .font(.subheadline)
                .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: omniboxFocused)
        .padding(.horizontal, 12)
        .padding(.top, 6)
        .padding(.bottom, 6)
    }

    // MARK: - Bottom toolbar (Chrome-style)

    private var bottomToolbar: some View {
        HStack {
            Button { tab.goBack() } label: {
                Image(systemName: "chevron.backward").font(.title3)
                    .frame(width: 44, height: 36)
            }
            .disabled(!tab.canGoBack)
            Spacer()
            Button { tab.goForward() } label: {
                Image(systemName: "chevron.forward").font(.title3)
                    .frame(width: 44, height: 36)
            }
            .disabled(!tab.canGoForward)
            Spacer()
            Button { tabManager.newTab() } label: {
                Image(systemName: "plus").font(.title3)
                    .frame(width: 44, height: 36)
            }
            Spacer()
            Button { showTabSwitcher = true } label: {
                ZStack {
                    RoundedRectangle(cornerRadius: 5)
                        .stroke(lineWidth: 1.8)
                        .frame(width: 22, height: 22)
                    Text("\(tabManager.tabs.count)")
                        .font(.caption.bold())
                }
                .frame(width: 44, height: 36)
            }
            Spacer()
            menuButton
        }
        .foregroundStyle(tab.isIncognito ? Color.purple : Color.primary)
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .background(.bar)
        .overlay(Divider(), alignment: .top)
    }

    private var menuButton: some View {
        Menu {
            Button { tabManager.newTab() } label: {
                Label("New tab", systemImage: "plus.square")
            }
            Button { tabManager.newTab(incognito: true) } label: {
                Label("New Incognito tab", systemImage: "eyeglasses")
            }
            Divider()
            Button { showDownloads = true } label: {
                Label(activeDownloadCount > 0 ? "Downloads (\(activeDownloadCount) active)" : "Downloads",
                      systemImage: "arrow.down.circle")
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
            Button { tab.reload() } label: {
                Label("Reload", systemImage: "arrow.clockwise")
            }
            Divider()
            Button { showSettings = true } label: {
                Label("Settings", systemImage: "gearshape")
            }
        } label: {
            ZStack(alignment: .topTrailing) {
                Image(systemName: "ellipsis").font(.title3)
                    .frame(width: 44, height: 36)
                if activeDownloadCount > 0 {
                    Circle()
                        .fill(.blue)
                        .frame(width: 9, height: 9)
                        .offset(x: -6, y: 4)
                }
            }
        }
    }

    // MARK: - Media detected badge

    private var mediaBadge: some View {
        Button { showMediaSheet = true } label: {
            HStack(spacing: 6) {
                Image(systemName: "arrow.down.circle.fill")
                Text("\(tab.detected.count)")
                    .font(.subheadline.bold())
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Color.blue, in: Capsule())
            .foregroundStyle(.white)
            .shadow(color: .black.opacity(0.25), radius: 6, y: 3)
        }
        .padding(.trailing, 16)
        .padding(.bottom, 16)
    }

    private func toastView(_ message: String) -> some View {
        VStack {
            Spacer()
            Text(message)
                .font(.footnote.weight(.medium))
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(.regularMaterial, in: Capsule())
                .shadow(color: .black.opacity(0.15), radius: 8, y: 3)
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

    private let shortcuts: [(title: String, url: String, icon: String, color: Color)] = [
        ("Google", "https://www.google.com", "magnifyingglass", .blue),
        ("YouTube", "https://www.youtube.com", "play.rectangle.fill", .red),
        ("Wikipedia", "https://www.wikipedia.org", "book.fill", .gray),
        ("Reddit", "https://www.reddit.com", "bubble.left.and.bubble.right.fill", .orange),
        ("X", "https://x.com", "at", .primary),
        ("Vimeo", "https://vimeo.com", "video.fill", .teal),
        ("Archive", "https://archive.org", "building.columns.fill", .indigo),
        ("GitHub", "https://github.com", "chevron.left.forwardslash.chevron.right", .purple)
    ]

    var body: some View {
        ScrollView {
            VStack(spacing: 28) {
                Spacer().frame(height: 36)
                if tab.isIncognito {
                    VStack(spacing: 8) {
                        Image(systemName: "eyeglasses").font(.largeTitle)
                        Text("Incognito").font(.title2.bold())
                        Text("Browsing in this tab isn't saved on this device.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    VStack(spacing: 10) {
                        ZStack {
                            Circle()
                                .fill(LinearGradient(colors: [.blue, .indigo],
                                                     startPoint: .top, endPoint: .bottom))
                                .frame(width: 64, height: 64)
                            Image(systemName: "arrow.down.to.line")
                                .font(.title.bold())
                                .foregroundStyle(.white)
                        }
                        Text("Downloader 2")
                            .font(.system(size: 28, weight: .bold, design: .rounded))
                    }
                }
                Button {
                    omniboxFocused.wrappedValue = true
                } label: {
                    HStack {
                        Image(systemName: "magnifyingglass")
                        Text("Search or type URL")
                        Spacer()
                        Image(systemName: "mic.fill").opacity(0.5)
                    }
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)
                    .background(Color(.secondarySystemBackground), in: Capsule())
                }
                .padding(.horizontal, 24)
                LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 4), spacing: 22) {
                    ForEach(shortcuts, id: \.url) { shortcut in
                        Button {
                            if let url = URL(string: shortcut.url) { tab.load(url) }
                        } label: {
                            VStack(spacing: 8) {
                                Image(systemName: shortcut.icon)
                                    .font(.title3)
                                    .foregroundStyle(shortcut.color)
                                    .frame(width: 54, height: 54)
                                    .background(Color(.secondarySystemBackground), in: Circle())
                                Text(shortcut.title)
                                    .font(.caption)
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 24)
            }
        }
        .scrollDismissesKeyboard(.immediately)
        .background(Color(.systemBackground))
        .onTapGesture { omniboxFocused.wrappedValue = false }
    }
}

// MARK: - Tab switcher

struct TabSwitcherView: View {
    @EnvironmentObject var tabManager: TabManager
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 14) {
                    ForEach(tabManager.tabs) { tab in
                        tabCard(tab)
                    }
                }
                .padding()
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Tabs (\(tabManager.tabs.count))")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Menu {
                        Button("New tab") { tabManager.newTab(); dismiss() }
                        Button("New Incognito tab") { tabManager.newTab(incognito: true); dismiss() }
                    } label: {
                        Image(systemName: "plus")
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func tabCard(_ tab: BrowserTab) -> some View {
        Button {
            tabManager.select(tab)
            dismiss()
        } label: {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 6) {
                    Image(systemName: tab.isIncognito ? "eyeglasses" : "globe")
                        .font(.caption)
                        .foregroundStyle(tab.isIncognito ? .purple : .blue)
                    Text(tab.title)
                        .font(.caption.bold())
                        .lineLimit(1)
                    Spacer()
                    Button {
                        withAnimation { tabManager.close(tab) }
                    } label: {
                        Image(systemName: "xmark")
                            .font(.caption2.bold())
                            .foregroundStyle(.secondary)
                            .frame(width: 26, height: 26)
                            .background(Color(.secondarySystemBackground), in: Circle())
                    }
                }
                .padding(8)
                Rectangle()
                    .fill(Color(.secondarySystemBackground))
                    .frame(height: 108)
                    .overlay {
                        VStack(spacing: 6) {
                            Image(systemName: tab.showingNewTabPage ? "plus.square.dashed" : "doc.text.image")
                                .font(.title2)
                                .foregroundStyle(.tertiary)
                            Text(tab.urlString.isEmpty ? "New Tab"
                                 : (URL(string: tab.urlString)?.host ?? tab.urlString))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .padding(.horizontal, 8)
                        }
                    }
            }
            .background(Color(.systemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .shadow(color: .black.opacity(0.08), radius: 5, y: 2)
            .overlay {
                RoundedRectangle(cornerRadius: 14)
                    .stroke(tab.id == tabManager.activeTabID ? Color.blue : Color(.separator).opacity(0.4),
                            lineWidth: tab.id == tabManager.activeTabID ? 2 : 1)
            }
        }
        .buttonStyle(.plain)
    }
}
