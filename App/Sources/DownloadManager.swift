import Foundation
import AVFoundation
import UIKit

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

    func enqueueFile(url: URL, fileName: String? = nil, pageTitle: String? = nil) {
        let name = sanitizedFileName(fileName ?? url.lastPathComponent,
                                     fallback: "file-\(Int(Date().timeIntervalSince1970))")
        var item = DownloadItem(url: url, fileName: name, kind: .file, pageTitle: pageTitle)
        item.state = .downloading
        appendAndSave(item)
        startFileTask(for: item, resumeData: nil)
        notify("Download started: \(name)")
    }

    func enqueueHLSFile(url: URL, title: String? = nil) {
        let base = sanitizedFileName(title ?? url.deletingPathExtension().lastPathComponent,
                                     fallback: "stream-\(Int(Date().timeIntervalSince1970))")
        var item = DownloadItem(url: url, fileName: base + ".ts", kind: .hlsFile, pageTitle: title)
        item.state = .downloading
        appendAndSave(item)
        startHLSFileWorker(for: item)
        notify("Stream download started: \(base)")
    }

    func enqueueHLSAsset(url: URL, title: String? = nil) {
        let base = sanitizedFileName(title ?? url.deletingPathExtension().lastPathComponent,
                                     fallback: "stream-\(Int(Date().timeIntervalSince1970))")
        var item = DownloadItem(url: url, fileName: base, kind: .hlsAsset, pageTitle: title)
        item.state = .downloading
        appendAndSave(item)
        startAssetTask(for: item)
        notify("Offline save started: \(base)")
    }

    /// Batch download: one URL per line. m3u8 URLs are saved for offline playback,
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
                enqueueHLSAsset(url: url)
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
                        self?.update(item.id) { $0.state = .paused }
                    }
                }
                tasks[item.id] = nil
            } else {
                update(item.id) { $0.state = .paused }
            }
        case .hlsFile:
            hlsWorkers[item.id]?.cancel()
            hlsWorkers[item.id] = nil
            update(item.id) { $0.state = .paused; $0.progress = 0; $0.receivedBytes = 0 }
        case .hlsAsset:
            assetTasks[item.id]?.suspend()
            update(item.id) { $0.state = .paused }
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
        update(item.id) { $0.state = .cancelled }
    }

    func delete(_ item: DownloadItem, removeFile: Bool) {
        cancel(item)
        if removeFile, let url = localURL(for: item) {
            try? FileManager.default.removeItem(at: url)
        }
        DispatchQueue.main.async {
            self.items.removeAll { $0.id == item.id }
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
            request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1", forHTTPHeaderField: "User-Agent")
            task = session.downloadTask(with: request)
        }
        task.taskDescription = item.id.uuidString
        tasks[item.id] = task
        task.resume()
    }

    private func startHLSFileWorker(for item: DownloadItem) {
        let worker = HLSFileDownloader(sourceURL: item.url, outputFileName: item.fileName)
        worker.onProgress = { [weak self] fraction, bytes in
            self?.throttledProgressUpdate(item.id, progress: fraction, received: bytes, total: 0)
        }
        worker.onCompletion = { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                self.hlsWorkers[item.id] = nil
                switch result {
                case .success(let fileURL):
                    self.update(item.id) {
                        $0.state = .finished
                        $0.progress = 1
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
                    self.update(item.id) { $0.state = .failed; $0.errorMessage = error.localizedDescription }
                }
            }
        }
        hlsWorkers[item.id] = worker
        worker.start()
    }

    private func startAssetTask(for item: DownloadItem) {
        let asset = AVURLAsset(url: item.url)
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
            guard let idx = self.items.firstIndex(where: { $0.id == id }) else { return }
            var item = self.items[idx]
            item.state = .downloading
            item.progress = progress
            item.receivedBytes = received
            if total > 0 { item.totalBytes = total }
            self.items[idx] = item
            if Date().timeIntervalSince(self.lastProgressSave) > 3 {
                self.lastProgressSave = Date()
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
                $0.fileName = destination.lastPathComponent
                $0.localRelativePath = destination.lastPathComponent
            }
            notify("Finished: \(destination.lastPathComponent)")
        } catch {
            update(id) { $0.state = .failed; $0.errorMessage = error.localizedDescription }
        }
        DispatchQueue.main.async { self.tasks[id] = nil }
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
        if let data = nsError.userInfo[NSURLSessionDownloadTaskResumeData] as? Data {
            DispatchQueue.main.async { self.resumeData[id] = data }
        }
        update(id) { $0.state = .failed; $0.errorMessage = error.localizedDescription }
        DispatchQueue.main.async {
            self.tasks[id] = nil
            self.assetTasks[id] = nil
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
        }
        DispatchQueue.main.async { self.assetTasks[id] = nil }
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
