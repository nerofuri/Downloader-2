import SwiftUI
import AVKit

struct FilesView: View {
    @EnvironmentObject var downloads: DownloadManager
    @Environment(\.dismiss) private var dismiss
    @State private var files: [FileEntry] = []
    @State private var playerURL: URL?

    struct FileEntry: Identifiable {
        let id: String
        let url: URL
        let name: String
        let size: Int64
    }

    private var offlineStreams: [DownloadItem] {
        downloads.items.filter { $0.kind == .hlsAsset && $0.state == .finished }
    }

    var body: some View {
        NavigationStack {
            List {
                if files.isEmpty && offlineStreams.isEmpty {
                    Text("No files yet. Downloaded files appear here and in the Files app under Downloader 2.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .listRowBackground(Theme.card)
                }
                if !files.isEmpty {
                    Section("Downloads folder") {
                        ForEach(files) { file in
                            fileRow(file)
                        }
                        .listRowBackground(Theme.card)
                    }
                }
                if !offlineStreams.isEmpty {
                    Section("Offline videos (HLS)") {
                        ForEach(offlineStreams) { item in
                            offlineRow(item)
                        }
                        .listRowBackground(Theme.card)
                    }
                }
            }
            .darkListBackground()
            .navigationTitle("Files")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .onAppear(perform: refresh)
            .sheet(item: $playerURL) { url in
                PlayerView(url: url).ignoresSafeArea()
            }
        }
    }

    private func fileRow(_ file: FileEntry) -> some View {
        HStack(spacing: 12) {
            Image(systemName: iconName(for: file.name))
                .foregroundStyle(.blue)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(file.name).font(.subheadline).lineLimit(1)
                Text(formatBytes(file.size)).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if isPlayable(file.name) {
                Button { playerURL = file.url } label: {
                    Image(systemName: "play.circle").font(.title3)
                }
                .buttonStyle(.borderless)
            }
            ShareLink(item: file.url) {
                Image(systemName: "square.and.arrow.up").font(.title3)
            }
            .buttonStyle(.borderless)
        }
        .swipeActions {
            Button(role: .destructive) {
                try? FileManager.default.removeItem(at: file.url)
                refresh()
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    private func offlineRow(_ item: DownloadItem) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "internaldrive")
                .foregroundStyle(.blue)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.fileName).font(.subheadline).lineLimit(1)
                Text("Offline HLS stream").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                if let url = downloads.localURL(for: item) { playerURL = url }
            } label: {
                Image(systemName: "play.circle").font(.title3)
            }
            .buttonStyle(.borderless)
        }
        .swipeActions {
            Button(role: .destructive) {
                downloads.delete(item, removeFile: true)
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    private func refresh() {
        let fm = FileManager.default
        let urls = (try? fm.contentsOfDirectory(at: AppDirs.downloads,
                                                includingPropertiesForKeys: [.fileSizeKey],
                                                options: [.skipsHiddenFiles])) ?? []
        files = urls.map { url in
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
            return FileEntry(id: url.path, url: url, name: url.lastPathComponent, size: size)
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func isPlayable(_ name: String) -> Bool {
        let ext = (name as NSString).pathExtension.lowercased()
        return ["mp4", "m4v", "mov", "ts", "mp3", "m4a", "aac", "wav", "3gp", "mkv", "webm", "avi", "flv"].contains(ext)
    }

    private func iconName(for name: String) -> String {
        let ext = (name as NSString).pathExtension.lowercased()
        switch ext {
        case "mp4", "m4v", "mov", "ts", "mkv", "webm", "avi", "flv", "wmv", "3gp": return "film"
        case "mp3", "m4a", "aac", "wav", "ogg", "opus": return "music.note"
        case "zip", "rar", "7z", "gz": return "doc.zipper"
        case "pdf": return "doc.richtext"
        case "jpg", "jpeg", "png", "gif", "webp", "heic": return "photo"
        default: return "doc"
        }
    }
}
