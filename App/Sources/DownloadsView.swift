import SwiftUI
import AVKit

// MARK: - Detected media sheet

struct MediaSheet: View {
    @ObservedObject var tab: BrowserTab
    @EnvironmentObject var downloads: DownloadManager
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                ForEach(tab.detected) { media in
                    row(media)
                        .listRowBackground(Theme.card)
                }
            }
            .darkListBackground()
            .navigationTitle("Media on this page")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Download All") {
                        let all = tab.detected
                        tab.currentCookies { cookies in
                            for media in all {
                                enqueue(media, cookies: cookies)
                            }
                        }
                        dismiss()
                    }
                    .disabled(tab.detected.isEmpty)
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func row(_ media: DetectedMedia) -> some View {
        HStack(spacing: 12) {
            Image(systemName: media.kind == "audio" ? "music.note"
                  : media.isHLS ? "dot.radiowaves.left.and.right" : "film")
                .font(.title3)
                .foregroundStyle(.blue)
                .frame(width: 32)
            VStack(alignment: .leading, spacing: 3) {
                Text(media.pageTitle.isEmpty ? media.url.lastPathComponent : media.pageTitle)
                    .font(.subheadline.bold())
                    .lineLimit(1)
                Text(media.url.absoluteString)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                HStack(spacing: 6) {
                    Text(media.kind.uppercased())
                        .font(.caption2.bold())
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.blue.opacity(0.15), in: Capsule())
                    if media.kind == "dash" {
                        Text("may not be downloadable")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
                }
            }
            Spacer()
            Button {
                download(media)
            } label: {
                Image(systemName: "arrow.down.circle.fill").font(.title2)
            }
            .buttonStyle(.borderless)
            if media.isHLS {
                Menu {
                    Button {
                        download(media, hlsAsAsset: true)
                    } label: {
                        Label("Save for offline playback", systemImage: "internaldrive")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    /// Default action: HLS → single video file, everything else → plain download.
    private func download(_ media: DetectedMedia, hlsAsAsset: Bool = false) {
        tab.currentCookies { cookies in
            if media.isHLS && hlsAsAsset {
                downloads.enqueueHLSAsset(url: media.url, title: media.pageTitle,
                                          referer: media.pageURL, cookies: cookies)
            } else {
                enqueue(media, cookies: cookies)
            }
        }
        dismiss()
    }

    private func enqueue(_ media: DetectedMedia, cookies: [HTTPCookie]) {
        if media.isHLS {
            downloads.enqueueHLSFile(url: media.url, title: media.pageTitle,
                                     referer: media.pageURL, cookies: cookies)
        } else {
            downloads.enqueueFile(url: media.url,
                                  fileName: media.url.lastPathComponent,
                                  pageTitle: media.pageTitle,
                                  referer: media.pageURL)
        }
    }
}

// MARK: - Downloads list

struct DownloadsView: View {
    @EnvironmentObject var downloads: DownloadManager
    @Environment(\.dismiss) private var dismiss
    @State private var showBatchSheet = false
    @State private var playerURL: URL?

    private var active: [DownloadItem] { downloads.items.filter { $0.isActive } }
    private var done: [DownloadItem] { downloads.items.filter { !$0.isActive } }

    var body: some View {
        NavigationStack {
            List {
                if active.isEmpty && done.isEmpty {
                    EmptyDownloadsView()
                }
                if !active.isEmpty {
                    Section("In progress") {
                        ForEach(active) { item in DownloadRow(item: item, playerURL: $playerURL) }
                            .listRowBackground(Theme.card)
                    }
                }
                if !done.isEmpty {
                    Section("Done") {
                        ForEach(done) { item in DownloadRow(item: item, playerURL: $playerURL) }
                            .listRowBackground(Theme.card)
                    }
                }
            }
            .darkListBackground()
            .navigationTitle("Downloads")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button { showBatchSheet = true } label: { Image(systemName: "plus") }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .sheet(isPresented: $showBatchSheet) { BatchDownloadSheet() }
            .sheet(item: $playerURL) { url in
                PlayerView(url: url).ignoresSafeArea()
            }
        }
    }
}

extension URL: Identifiable {
    public var id: String { absoluteString }
}

struct EmptyDownloadsView: View {
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "arrow.down.circle")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text("No downloads yet")
                .font(.headline)
            Text("Files and videos you download will appear here.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
        .listRowBackground(Color.clear)
    }
}

struct DownloadRow: View {
    let item: DownloadItem
    @Binding var playerURL: URL?
    @EnvironmentObject var downloads: DownloadManager

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: icon)
                    .foregroundStyle(iconColor)
                Text(item.fileName)
                    .font(.subheadline.bold())
                    .lineLimit(1)
                Spacer()
                controls
            }
            if item.isActive {
                ProgressView(value: min(max(item.progress, 0), 1))
                    .progressViewStyle(.linear)
            }
            HStack {
                Text(statusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(detailText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let error = item.errorMessage, item.state == .failed {
                Text(error).font(.caption2).foregroundStyle(.red).lineLimit(2)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if item.state == .finished, isPlayable, let url = downloads.localURL(for: item) {
                playerURL = url
            }
        }
        .swipeActions {
            Button(role: .destructive) {
                downloads.delete(item, removeFile: true)
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    private var isPlayable: Bool {
        if item.kind == .hlsAsset || item.kind == .hlsFile { return true }
        let ext = (item.fileName as NSString).pathExtension.lowercased()
        return ["mp4", "m4v", "mov", "ts", "mp3", "m4a", "aac", "wav", "3gp"].contains(ext)
    }

    private var icon: String {
        switch item.state {
        case .finished: return isPlayable ? "play.circle.fill" : "doc.fill"
        case .failed: return "exclamationmark.circle.fill"
        case .paused: return "pause.circle.fill"
        case .cancelled: return "slash.circle"
        default: return "arrow.down.circle"
        }
    }

    private var iconColor: Color {
        switch item.state {
        case .finished: return .green
        case .failed: return .red
        default: return .blue
        }
    }

    private var statusText: String {
        switch item.state {
        case .queued: return "Queued"
        case .downloading:
            if item.kind == .hlsFile || item.kind == .hlsAsset {
                return "Downloading \(Int(item.progress * 100))%"
            }
            return "Downloading \(Int(item.progress * 100))%"
        case .paused: return "Paused"
        case .finished: return item.kind == .hlsAsset ? "Saved for offline playback" : "Finished"
        case .failed: return "Failed"
        case .cancelled: return "Cancelled"
        }
    }

    /// Right-hand detail: size (known total or downloaded so far) plus live speed.
    private var detailText: String {
        var parts: [String] = []

        // Size component.
        if item.state == .finished {
            if item.receivedBytes > 0 { parts.append(formatBytes(item.receivedBytes)) }
        } else if item.totalBytes > 0 {
            parts.append("\(formatBytes(item.receivedBytes)) / \(formatBytes(item.totalBytes))")
        } else if item.receivedBytes > 0 {
            parts.append(formatBytes(item.receivedBytes))
        }

        // Speed component while active.
        if item.state == .downloading, let speed = item.bytesPerSecond, speed > 0 {
            parts.append("\(formatBytes(speed))/s")
        }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private var controls: some View {
        switch item.state {
        case .downloading, .queued:
            Button { downloads.pause(item) } label: {
                Image(systemName: "pause.fill")
            }
            .buttonStyle(.borderless)
        case .paused:
            Button { downloads.resume(item) } label: {
                Image(systemName: "play.fill")
            }
            .buttonStyle(.borderless)
        case .failed, .cancelled:
            Button { downloads.resume(item) } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
        case .finished:
            if let url = downloads.localURL(for: item), item.kind != .hlsAsset {
                ShareLink(item: url) {
                    Image(systemName: "square.and.arrow.up")
                }
                .buttonStyle(.borderless)
            }
        }
    }
}

// MARK: - Batch download

struct BatchDownloadSheet: View {
    @EnvironmentObject var downloads: DownloadManager
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                Text("Paste one URL per line. Direct file links are downloaded as files; m3u8 links are downloaded as video files.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                TextEditor(text: $text)
                    .font(.system(.footnote, design: .monospaced))
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .background(Theme.card, in: RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.stroke, lineWidth: 1))
                    .frame(minHeight: 220)
                Button {
                    downloads.enqueueBatch(text)
                    dismiss()
                } label: {
                    Text("Start downloads")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Spacer()
            }
            .padding()
            .background(Theme.bg)
            .navigationTitle("Batch download")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}

// MARK: - Player

struct PlayerView: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        let asset = AVURLAsset(url: url)
        controller.player = AVPlayer(playerItem: AVPlayerItem(asset: asset))
        controller.allowsPictureInPicturePlayback = true
        controller.player?.play()
        return controller
    }

    func updateUIViewController(_ uiViewController: AVPlayerViewController, context: Context) {}
}
