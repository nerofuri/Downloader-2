import Foundation

enum DownloadKind: String, Codable {
    /// Plain file downloaded over HTTP(S).
    case file
    /// HLS stream exported to a single local media file (.ts / .mp4).
    case hlsFile
    /// HLS stream saved natively for offline playback (AVAssetDownloadTask, .movpkg).
    case hlsAsset
}

enum DownloadState: String, Codable {
    case queued, downloading, paused, finished, failed, cancelled
}

struct DownloadItem: Identifiable, Codable, Equatable {
    let id: UUID
    var url: URL
    var fileName: String
    var kind: DownloadKind
    var state: DownloadState
    var progress: Double
    var totalBytes: Int64
    var receivedBytes: Int64
    /// Relative to the app home directory for hlsAsset, relative to Downloads dir otherwise.
    var localRelativePath: String?
    var pageTitle: String?
    var errorMessage: String?
    var createdAt: Date
    /// Page the media was found on; sent as the Referer header (many CDNs require it).
    var referer: String?
    /// Rolling transfer speed, updated while downloading.
    var bytesPerSecond: Int64?

    init(url: URL, fileName: String, kind: DownloadKind, pageTitle: String? = nil, referer: String? = nil) {
        self.id = UUID()
        self.url = url
        self.fileName = fileName
        self.kind = kind
        self.state = .queued
        self.progress = 0
        self.totalBytes = 0
        self.receivedBytes = 0
        self.localRelativePath = nil
        self.pageTitle = pageTitle
        self.errorMessage = nil
        self.createdAt = Date()
        self.referer = referer
        self.bytesPerSecond = nil
    }

    var isActive: Bool { state == .queued || state == .downloading || state == .paused }
}

struct DetectedMedia: Identifiable, Hashable {
    let id = UUID()
    let url: URL
    /// "hls", "dash", "video" or "audio"
    let kind: String
    let pageTitle: String
    /// URL of the page the media was detected on (used as Referer for the download).
    let pageURL: String?

    static func == (lhs: DetectedMedia, rhs: DetectedMedia) -> Bool { lhs.url == rhs.url }
    func hash(into hasher: inout Hasher) { hasher.combine(url) }

    var isHLS: Bool { kind == "hls" }
}

enum AppDirs {
    static var documents: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    static var downloads: URL {
        let dir = documents.appendingPathComponent("Downloads", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func uniqueDestination(fileName: String) -> URL {
        let base = (fileName as NSString).deletingPathExtension
        let ext = (fileName as NSString).pathExtension
        var candidate = downloads.appendingPathComponent(fileName)
        var counter = 1
        while FileManager.default.fileExists(atPath: candidate.path) {
            let name = ext.isEmpty ? "\(base) (\(counter))" : "\(base) (\(counter)).\(ext)"
            candidate = downloads.appendingPathComponent(name)
            counter += 1
        }
        return candidate
    }
}

func sanitizedFileName(_ name: String, fallback: String = "download") -> String {
    var cleaned = name.replacingOccurrences(of: "/", with: "-")
        .replacingOccurrences(of: ":", with: "-")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    if cleaned.count > 120 { cleaned = String(cleaned.prefix(120)) }
    return cleaned.isEmpty ? fallback : cleaned
}

func formatBytes(_ bytes: Int64) -> String {
    guard bytes > 0 else { return "—" }
    return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
}
