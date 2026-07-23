import Foundation
import AVFoundation
import UIKit
import WebKit

let browserUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"

final class DownloadManager: NSObject, ObservableObject {
    static let shared = DownloadManager()

    static let backgroundSessionID = "com.nerofuri.downloader2.bg"
    static let hlsSessionID = "com.nerofuri.downloader2.bg.hls"

    @Published private(set) var items: [DownloadItem] = []
    @Published var lastMessage: String?

    var backgroundCompletionHandlers: [String: () -> Void] = [:]

    private var tasks: [UUID: URLSessionDownloadTask] = [:]
    private var assetTasks: [UUID: AVAssetDownloadTask] = [:]
    private var resumeData: [UUID: Data] = [:]
    private var hlsWorkers: [UUID: HLSFileDownloader] = [:]
    private var cookiesByItem: [UUID: [HTTPCookie]] = [:]
    /// Per-item throttle so progress callbacks don't re-render the UI dozens of times per second.
    private var progressMeta: [UUID: (lastPublish: Date, lastBytes: Int64)] = [:]
    private var lastProgressSave = Date.distantPast

    private var storeURL: URL {
        AppDirs.documents.appendingPathComponent("downloads.json")
    }

    // MARK: - Sessions

    lazy var session: URLSession = {
        let cfg = URLSessionConfiguration.background(withIdentifier: Self.backgroundSessionID)
        cfg.isDiscretionary = false
        cfg.sessionSendsLaunchEvents = true
        cfg.allowsCellularAccess = true
        cfg.waitsForConnectivity = true
        return URLSession(configuration: cfg, delegate: self, delegateQueue: nil)
    }()

    lazy var assetSession: AVAssetDownloadURLSession = {
        let cfg = URLSessionConfiguration.background(withIdentifier: Self.hlsSessionID)
        cfg.isDiscretionary = false
        cfg.sessionSendsLaunchEvents = true
        return AVAssetDownloadURLSession(configuration: cfg,
                                         assetDownloadDelegate: self,
                                         delegateQueue: OperationQueue.main)
    }()

    private override init() {
        super.init()
        loadItems()
        reattachTasks()
    }

    // MARK: - Public API

    func enqueueFile(url: URL, fileName: String? = nil, pageTitle: String? = nil,
                     referer: String? = nil) {
        let name = sanitizedFileName(fileName ?? url.lastPathComponent,
                                     fallback: "file-\(Int(Date().timeIntervalSince1970))")
        var item = DownloadItem(url: url, fileName: name, kind: .file,
                                pageTitle: pageTitle, referer: referer)
        item.state = .downloading
        appendAndSave(item)
        startFileTask(for: item, resumeData: nil)
        notify("Download started: \(name)")
    }

    /// Downloads an HLS stream into a single local video file (default for m3u8).
    func enqueueHLSFile(url: URL, title: String? = nil, referer: String? = nil,
                        cookies: [HTTPCookie] = []) {
        let base = sanitizedFileName(title ?? url.deletingPathExtension().lastPathComponent,
                                     fallback: "stream-\(Int(Date().timeIntervalSince1970))")
        var item = DownloadItem(url: url, fileName: base + ".ts", kind: .hlsFile,
                                pageTitle: title, referer: referer)
        item.state = .downloading
        cookiesByItem[item.id] = cookies
        appendAndSave(item)
        startHLSFileWorker(for: item)
        notify("Video download started: \(base)")
    }

    /// Saves an HLS stream with the system downloader for offline in-app playback.
    func enqueueHLSAsset(url: URL, title: String? = nil, referer: String? = nil,
                         cookies: [HTTPCookie] = []) {
        let base = sanitizedFileName(title ?? url.deletingPathExtension().lastPathComponent,
                                     fallback: "stream-\(Int(Date().timeIntervalSince1970))")
        var item = DownloadItem(url: url, fileName: base, kind: .hlsAsset,
                                pageTitle: title, referer: referer)
        item.state = .downloading
        cookiesByItem[item.id] = cookies
        appendAndSave(item)
        startAssetTask(for: item)
        notify("Offline save started: \(base)")
    }

    /// Batch download: one URL per line. m3u8 URLs become video-file downloads,
    /// everything else is downloaded as a plain file.
    func enqueueBatch(_ text: String) {
        let lines = text.split(whereSeparator: \.isNewline)
        var count = 0
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty,
                  let url = URL(string: trimmed),
                  let scheme = url.scheme?.lowercased(),
                  scheme == "http" || scheme == "https" else { continue }
            if url.path.lowercased().hasSuffix(".m3u8") {
                enqueueHLSFile(url: url)
            } else {
                enqueueFile(url: url)
            }
            count += 1
        }
        if count > 0 { notify("Added \(count) download\(count == 1 ? "" : "s")") }
    }

    func pause(_ item: DownloadItem) {
        switch item.kind {
        case .file:
            if let task = tasks[item.id] {
                task.cancel { [weak self] data in
                    DispatchQueue.main.async {
                        if let data { self?.resumeData[item.id] = data }
                        self?.update(item.id) { $0.state = .paused; $0.bytesPerSecond = nil }
                    }
                }
                tasks[item.id] = nil
            } else {
                update(item.id) { $0.state = .paused; $0.bytesPerSecond = nil }
            }
        case .hlsFile:
            hlsWorkers[item.id]?.cancel()
            hlsWorkers[item.id] = nil
            update(item.id) {
                $0.state = .paused; $0.progress = 0; $0.receivedBytes = 0; $0.bytesPerSecond = nil
            }
        case .hlsAsset:
            assetTasks[item.id]?.suspend()
            update(item.id) { $0.state = .paused; $0.bytesPerSecond = nil }
        }
    }

    func resume(_ item: DownloadItem) {
        switch item.kind {
        case .file:
            update(item.id) { $0.state = .downloading; $0.errorMessage = nil }
            startFileTask(for: item, resumeData: resumeData[item.id])
            resumeData[item.id] = nil
        case .hlsFile:
            update(item.id) { $0.state = .downloading; $0.errorMessage = nil }
            startHLSFileWorker(for: item)
        case .hlsAsset:
            update(item.id) { $0.state = .downloading; $0.errorMessage = nil }
            if let task = assetTasks[item.id] {
                task.resume()
            } else {
                startAssetTask(for: item)
            }
        }
    }

    func cancel(_ item: DownloadItem) {
        tasks[item.id]?.cancel()
        tasks[item.id] = nil
        hlsWorkers[item.id]?.cancel()
        hlsWorkers[item.id] = nil
        assetTasks[item.id]?.cancel()
        assetTasks[item.id] = nil
        resumeData[item.id] = nil
        update(item.id) { $0.state = .cancelled; $0.bytesPerSecond = nil }
    }

    func delete(_ item: DownloadItem, removeFile: Bool) {
        cancel(item)
        if removeFile, let url = localURL(for: item) {
            try? FileManager.default.removeItem(at: url)
        }
        DispatchQueue.main.async {
            self.items.removeAll { $0.id == item.id }
            self.cookiesByItem[item.id] = nil
            self.progressMeta[item.id] = nil
            self.saveItems()
        }
    }

    func localURL(for item: DownloadItem) -> URL? {
        guard let rel = item.localRelativePath else { return nil }
        switch item.kind {
        case .hlsAsset:
            return URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(rel)
        default:
            return AppDirs.downloads.appendingPathComponent(rel)
        }
    }

    // MARK: - Task management

    private func startFileTask(for item: DownloadItem, resumeData: Data?) {
        let task: URLSessionDownloadTask
        if let resumeData {
            task = session.downloadTask(withResumeData: resumeData)
        } else {
            var request = URLRequest(url: item.url)
            request.setValue(browserUserAgent, forHTTPHeaderField: "User-Agent")
            if let referer = item.referer {
                request.setValue(referer, forHTTPHeaderField: "Referer")
            }
            task = session.downloadTask(with: request)
        }
        task.taskDescription = item.id.uuidString
        tasks[item.id] = task
        task.resume()
    }

    private func startHLSFileWorker(for item: DownloadItem) {
        let worker = HLSFileDownloader(sourceURL: item.url,
                                       outputFileName: item.fileName,
                                       referer: item.referer,
                                       cookies: cookiesByItem[item.id] ?? [])
        worker.onProgress = { [weak self] fraction, bytes in
            self?.throttledProgressUpdate(item.id, progress: fraction, received: bytes, total: 0)
        }
        worker.onCompletion = { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                self.hlsWorkers[item.id] = nil
                self.progressMeta[item.id] = nil
                switch result {
                case .success(let fileURL):
                    self.update(item.id) {
                        $0.state = .finished
                        $0.progress = 1
                        $0.bytesPerSecond = nil
                        $0.fileName = fileURL.lastPathComponent
                        $0.localRelativePath = fileURL.lastPathComponent
                        if let size = try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? Int64 {
                            $0.receivedBytes = size
                            $0.totalBytes = size
                        }
                    }
                    self.notify("Finished: \(fileURL.lastPathComponent)")
                case .failure(let error):
                    if (error as? HLSError) == .cancelled { return }
                    self.update(item.id) {
                        $0.state = .failed
                        $0.bytesPerSecond = nil
                        $0.errorMessage = error.localizedDescription
                    }
                }
            }
        }
        hlsWorkers[item.id] = worker
        worker.start()
    }

    private func startAssetTask(for item: DownloadItem) {
        var options: [String: Any] = [:]
        var headers: [String: String] = ["User-Agent": browserUserAgent]
        if let referer = item.referer {
            headers["Referer"] = referer
        }
        options["AVURLAssetHTTPHeaderFieldsKey"] = headers
        if let cookies = cookiesByItem[item.id], !cookies.isEmpty {
            options[AVURLAssetHTTPCookiesKey] = cookies
        }
        let asset = AVURLAsset(url: item.url, options: options)
        guard let task = assetSession.makeAssetDownloadTask(asset: asset,
                                                            assetTitle: item.fileName,
                                                            assetArtworkData: nil,
                                                            options: nil) else {
            update(item.id) { $0.state = .failed; $0.errorMessage = "Could not create HLS download task" }
            return
        }
        task.taskDescription = item.id.uuidString
        assetTasks[item.id] = task
        task.resume()
    }

    /// When the system HLS downloader fails (some servers reject it even with headers),
    /// retry the same stream once through the segment-based file exporter.
    private func fallbackToFileExport(_ id: UUID) {
        guard var item = items.first(where: { $0.id == id }), item.kind == .hlsAsset else { return }
        item.kind = .hlsFile
        update(id) {
            $0.kind = .hlsFile
            $0.state = .downloading
            $0.progress = 0
            $0.receivedBytes = 0
            $0.errorMessage = nil
        }
        startHLSFileWorker(for: item)
        notify("Retrying as video file download…")
    }

    private func reattachTasks() {
        assetSession.getAllTasks { [weak self] existing in
            DispatchQueue.main.async {
                guard let self else { return }
                for task in existing {
                    guard let assetTask = task as? AVAssetDownloadTask,
                          let desc = assetTask.taskDescription,
                          let id = UUID(uuidString: desc) else { continue }
                    self.assetTasks[id] = assetTask
                }
            }
        }
        session.getAllTasks { [weak self] existing in
            DispatchQueue.main.async {
                guard let self else { return }
                for task in existing {
                    guard let desc = task.taskDescription, let id = UUID(uuidString: desc),
                          let download = task as? URLSessionDownloadTask else { continue }
                    self.tasks[id] = download
                }
                // Anything marked downloading with no live task gets paused.
                for item in self.items where item.state == .downloading || item.state == .queued {
                    if item.kind == .file && self.tasks[item.id] == nil {
                        self.update(item.id) { $0.state = .paused }
                    }
                    if item.kind == .hlsFile && self.hlsWorkers[item.id] == nil {
                        self.update(item.id) { $0.state = .paused; $0.progress = 0 }
                    }
                }
            }
        }
    }

    // MARK: - State helpers

    private func appendAndSave(_ item: DownloadItem) {
        DispatchQueue.main.async {
            self.items.insert(item, at: 0)
            self.saveItems()
        }
    }

    private func update(_ id: UUID, _ mutate: @escaping (inout DownloadItem) -> Void) {
        DispatchQueue.main.async {
            guard let idx = self.items.firstIndex(where: { $0.id == id }) else { return }
            var item = self.items[idx]
            mutate(&item)
            self.items[idx] = item
            self.saveItems()
        }
    }

    private func throttledProgressUpdate(_ id: UUID, progress: Double, received: Int64, total: Int64) {
        DispatchQueue.main.async {
            let now = Date()
            if let meta = self.progressMeta[id],
               now.timeIntervalSince(meta.lastPublish) < 0.35, progress < 1 {
                return
            }
            guard let idx = self.items.firstIndex(where: { $0.id == id }) else { return }
            var item = self.items[idx]
            if let meta = self.progressMeta[id] {
                let dt = now.timeIntervalSince(meta.lastPublish)
                if dt > 0, received > meta.lastBytes {
                    item.bytesPerSecond = Int64(Double(received - meta.lastBytes) / dt)
                }
            }
            self.progressMeta[id] = (now, received)
            item.state = .downloading
            item.progress = progress
            item.receivedBytes = received
            if total > 0 { item.totalBytes = total }
            self.items[idx] = item
            if now.timeIntervalSince(self.lastProgressSave) > 3 {
                self.lastProgressSave = now
                self.saveItems()
            }
        }
    }

    private func notify(_ message: String) {
        DispatchQueue.main.async { self.lastMessage = message }
    }

    // MARK: - Persistence

    private func loadItems() {
        guard let data = try? Data(contentsOf: storeURL),
              let decoded = try? JSONDecoder().decode([DownloadItem].self, from: data) else { return }
        items = decoded
    }

    private func saveItems() {
        guard let data = try? JSONEncoder().encode(items) else { return }
        try? data.write(to: storeURL, options: .atomic)
    }
}

// MARK: - URLSessionDownloadDelegate

extension DownloadManager: URLSessionDownloadDelegate {
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        guard let desc = downloadTask.taskDescription, let id = UUID(uuidString: desc) else { return }
        let suggested = downloadTask.response?.suggestedFilename
        let fallback = items.first(where: { $0.id == id })?.fileName ?? "download"
        let destination = AppDirs.uniqueDestination(fileName: sanitizedFileName(suggested ?? fallback, fallback: fallback))
        do {
            try FileManager.default.moveItem(at: location, to: destination)
            update(id) {
                $0.state = .finished
                $0.progress = 1
                $0.bytesPerSecond = nil
                $0.fileName = destination.lastPathComponent
                $0.localRelativePath = destination.lastPathComponent
            }
            notify("Finished: \(destination.lastPathComponent)")
        } catch {
            update(id) { $0.state = .failed; $0.errorMessage = error.localizedDescription }
        }
        DispatchQueue.main.async {
            self.tasks[id] = nil
            self.progressMeta[id] = nil
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        guard let desc = downloadTask.taskDescription, let id = UUID(uuidString: desc) else { return }
        let progress = totalBytesExpectedToWrite > 0
            ? Double(totalBytesWritten) / Double(totalBytesExpectedToWrite) : 0
        throttledProgressUpdate(id, progress: progress,
                                received: totalBytesWritten, total: totalBytesExpectedToWrite)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    didCompleteWithError error: Error?) {
        guard let error, let desc = task.taskDescription, let id = UUID(uuidString: desc) else { return }
        let nsError = error as NSError
        if nsError.code == NSURLErrorCancelled { return } // pause/cancel path already handled

        if task is AVAssetDownloadTask {
            // System HLS downloader failed — automatically retry as a file export.
            DispatchQueue.main.async {
                self.assetTasks[id] = nil
                self.fallbackToFileExport(id)
            }
            return
        }

        if let data = nsError.userInfo[NSURLSessionDownloadTaskResumeData] as? Data {
            DispatchQueue.main.async { self.resumeData[id] = data }
        }
        update(id) {
            $0.state = .failed
            $0.bytesPerSecond = nil
            $0.errorMessage = error.localizedDescription
        }
        DispatchQueue.main.async {
            self.tasks[id] = nil
            self.progressMeta[id] = nil
        }
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        DispatchQueue.main.async {
            if let identifier = session.configuration.identifier,
               let handler = self.backgroundCompletionHandlers.removeValue(forKey: identifier) {
                handler()
            }
        }
    }
}

// MARK: - AVAssetDownloadDelegate (offline HLS)

extension DownloadManager: AVAssetDownloadDelegate {
    func urlSession(_ session: URLSession, assetDownloadTask: AVAssetDownloadTask,
                    didFinishDownloadingTo location: URL) {
        guard let desc = assetDownloadTask.taskDescription, let id = UUID(uuidString: desc) else { return }
        update(id) {
            $0.localRelativePath = location.relativePath
            $0.state = .finished
            $0.progress = 1
            $0.bytesPerSecond = nil
        }
        DispatchQueue.main.async {
            self.assetTasks[id] = nil
            self.progressMeta[id] = nil
        }
        notify("Saved for offline playback")
    }

    func urlSession(_ session: URLSession, assetDownloadTask: AVAssetDownloadTask,
                    didLoad timeRange: CMTimeRange, totalTimeRangesLoaded loadedTimeRanges: [NSValue],
                    timeRangeExpectedToLoad: CMTimeRange) {
        guard let desc = assetDownloadTask.taskDescription, let id = UUID(uuidString: desc) else { return }
        let expected = CMTimeGetSeconds(timeRangeExpectedToLoad.duration)
        guard expected > 0 else { return }
        let loaded = loadedTimeRanges.reduce(0.0) { $0 + CMTimeGetSeconds($1.timeRangeValue.duration) }
        throttledProgressUpdate(id, progress: min(loaded / expected, 1),
                                received: assetDownloadTask.countOfBytesReceived, total: 0)
    }
}
