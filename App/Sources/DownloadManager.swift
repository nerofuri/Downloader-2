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
    private var hlsJobs: [UUID: HLSJob] = [:]
    private var assemblingJobs: Set<UUID> = []
    private var progressMeta: [UUID: (lastPublish: Date, lastBytes: Int64)] = [:]
    private var lastProgressSave = Date.distantPast

    private var storeURL: URL { AppDirs.documents.appendingPathComponent("downloads.json") }
    private var jobsURL: URL { AppDirs.documents.appendingPathComponent("hlsjobs.json") }

    // MARK: - Sessions

    lazy var session: URLSession = {
        let cfg = URLSessionConfiguration.background(withIdentifier: Self.backgroundSessionID)
        cfg.isDiscretionary = false
        cfg.sessionSendsLaunchEvents = true
        cfg.allowsCellularAccess = true
        cfg.waitsForConnectivity = true
        cfg.httpMaximumConnectionsPerHost = 6
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
        loadJobs()
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

    /// Downloads an HLS stream into a single local video file, using background download
    /// tasks so it continues when the app is closed and resumes after a restart.
    func enqueueHLSFile(url: URL, title: String? = nil, referer: String? = nil,
                        cookies: [HTTPCookie] = []) {
        let base = sanitizedFileName(title ?? url.deletingPathExtension().lastPathComponent,
                                     fallback: "stream-\(Int(Date().timeIntervalSince1970))")
        var item = DownloadItem(url: url, fileName: base + ".ts", kind: .hlsFile,
                                pageTitle: title, referer: referer)
        item.state = .downloading
        appendAndSave(item)
        let cookieHeader = cookieHeaderString(cookies)
        beginHLSFileJob(itemID: item.id, sourceURL: url, baseName: base,
                        referer: referer, cookieHeader: cookieHeader)
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
        appendAndSave(item)
        startAssetTask(for: item, cookies: cookies)
        notify("Offline save started: \(base)")
    }

    func enqueueBatch(_ text: String) {
        let lines = text.split(whereSeparator: \.isNewline)
        var count = 0
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, let url = URL(string: trimmed),
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
            cancelHLSTasks(for: item.id)
            update(item.id) { $0.state = .paused; $0.bytesPerSecond = nil }
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
            if let job = hlsJobs[item.id] {
                enqueueRemainingSegments(job)
            } else {
                // Metadata lost — restart the job from the playlist.
                beginHLSFileJob(itemID: item.id, sourceURL: item.url,
                                baseName: (item.fileName as NSString).deletingPathExtension,
                                referer: item.referer, cookieHeader: nil)
            }
        case .hlsAsset:
            update(item.id) { $0.state = .downloading; $0.errorMessage = nil }
            if let task = assetTasks[item.id] {
                task.resume()
            } else {
                startAssetTask(for: item, cookies: [])
            }
        }
    }

    func cancel(_ item: DownloadItem) {
        tasks[item.id]?.cancel()
        tasks[item.id] = nil
        cancelHLSTasks(for: item.id)
        removeHLSJob(item.id)
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

    // MARK: - Plain file tasks

    private func startFileTask(for item: DownloadItem, resumeData: Data?) {
        let task: URLSessionDownloadTask
        if let resumeData {
            task = session.downloadTask(withResumeData: resumeData)
        } else {
            var request = URLRequest(url: item.url)
            request.setValue(browserUserAgent, forHTTPHeaderField: "User-Agent")
            if let referer = item.referer { request.setValue(referer, forHTTPHeaderField: "Referer") }
            task = session.downloadTask(with: request)
        }
        task.taskDescription = item.id.uuidString
        tasks[item.id] = task
        task.resume()
    }

    // MARK: - HLS background jobs

    private func beginHLSFileJob(itemID: UUID, sourceURL: URL, baseName: String,
                                 referer: String?, cookieHeader: String?) {
        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            do {
                let parsed = try await HLSParser.parse(url: sourceURL, referer: referer,
                                                        cookieHeader: cookieHeader)
                let ext = parsed.usesFMP4 ? "mp4" : "ts"
                let job = HLSJob(itemID: itemID, outputFileName: baseName + "." + ext,
                                 usesFMP4: parsed.usesFMP4, mapURL: parsed.mapURL,
                                 referer: referer, cookieHeader: cookieHeader,
                                 segments: parsed.segments, completed: [],
                                 mapDone: parsed.mapURL == nil, receivedBytes: 0)
                await MainActor.run {
                    self.hlsJobs[itemID] = job
                    self.saveJobs()
                    self.enqueueRemainingSegments(job)
                }
            } catch {
                await MainActor.run {
                    self.update(itemID) {
                        $0.state = .failed
                        $0.errorMessage = error.localizedDescription
                    }
                }
            }
        }
    }

    private func enqueueRemainingSegments(_ job: HLSJob) {
        let dir = AppDirs.hlsJobDir(job.itemID)
        if let mapURL = job.mapURL, !job.mapDone {
            var request = hlsRequest(mapURL, job: job)
            request.setValue(nil, forHTTPHeaderField: "Range")
            let task = session.downloadTask(with: request)
            task.taskDescription = "hlsmap|\(job.itemID.uuidString)"
            task.resume()
        }
        let completed = Set(job.completed)
        for segment in job.segments where !completed.contains(segment.index) {
            // Skip if already on disk from a previous run.
            if FileManager.default.fileExists(atPath: dir.appendingPathComponent("seg-\(segment.index)").path) {
                markSegmentComplete(job.itemID, index: segment.index, addedBytes: 0)
                continue
            }
            var request = hlsRequest(segment.url, job: job)
            if let offset = segment.byteOffset, let length = segment.byteLength {
                request.setValue("bytes=\(offset)-\(offset + length - 1)", forHTTPHeaderField: "Range")
            }
            let task = session.downloadTask(with: request)
            task.taskDescription = "hlsseg|\(job.itemID.uuidString)|\(segment.index)"
            task.resume()
        }
    }

    private func hlsRequest(_ url: URL, job: HLSJob) -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue(browserUserAgent, forHTTPHeaderField: "User-Agent")
        if let referer = job.referer {
            request.setValue(referer, forHTTPHeaderField: "Referer")
            if let refererURL = URL(string: referer), let scheme = refererURL.scheme,
               let host = refererURL.host {
                request.setValue("\(scheme)://\(host)", forHTTPHeaderField: "Origin")
            }
        }
        if let cookieHeader = job.cookieHeader {
            request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        }
        return request
    }

    private func handleHLSDownload(taskDescription desc: String, location: URL,
                                   fileSize: Int64) {
        let parts = desc.components(separatedBy: "|")
        guard parts.count >= 2, let itemID = UUID(uuidString: parts[1]) else { return }
        let dir = AppDirs.hlsJobDir(itemID)
        let name = parts[0] == "hlsmap" ? "map" : "seg-\(parts.count > 2 ? parts[2] : "0")"
        let dest = dir.appendingPathComponent(name)
        try? FileManager.default.removeItem(at: dest)
        do {
            try FileManager.default.moveItem(at: location, to: dest)
        } catch {
            return
        }
        DispatchQueue.main.async {
            if parts[0] == "hlsmap" {
                self.hlsJobs[itemID]?.mapDone = true
                self.hlsJobs[itemID]?.receivedBytes += fileSize
                self.saveJobs()
                self.refreshHLSProgress(itemID)
            } else if let index = Int(parts[2]) {
                self.markSegmentComplete(itemID, index: index, addedBytes: fileSize)
            }
        }
    }

    private func markSegmentComplete(_ itemID: UUID, index: Int, addedBytes: Int64) {
        guard var job = hlsJobs[itemID] else { return }
        if !job.completed.contains(index) {
            job.completed.append(index)
            job.receivedBytes += addedBytes
            hlsJobs[itemID] = job
            saveJobs()
        }
        refreshHLSProgress(itemID)
        if job.isComplete { assembleHLS(itemID) }
    }

    private func refreshHLSProgress(_ itemID: UUID) {
        guard let job = hlsJobs[itemID], !job.segments.isEmpty else { return }
        let progress = Double(job.completed.count) / Double(job.segments.count)
        throttledProgressUpdate(itemID, progress: progress, received: job.receivedBytes, total: 0)
    }

    private func assembleHLS(_ itemID: UUID) {
        guard !assemblingJobs.contains(itemID), let job = hlsJobs[itemID] else { return }
        assemblingJobs.insert(itemID)

        let bgTask = UIApplication.shared.beginBackgroundTask(withName: "hls-assemble")
        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            let result = await self.performAssembly(job)
            await MainActor.run {
                self.assemblingJobs.remove(itemID)
                switch result {
                case .success(let fileURL):
                    self.removeHLSJob(itemID, removeTemp: true)
                    let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path)
                    let size = (attrs?[.size] as? Int64) ?? 0
                    self.update(itemID) {
                        $0.state = .finished
                        $0.progress = 1
                        $0.bytesPerSecond = nil
                        $0.fileName = fileURL.lastPathComponent
                        $0.localRelativePath = fileURL.lastPathComponent
                        $0.receivedBytes = size
                        $0.totalBytes = size
                    }
                    self.notify("Finished: \(fileURL.lastPathComponent)")
                case .failure(let error):
                    self.update(itemID) {
                        $0.state = .failed
                        $0.errorMessage = error.localizedDescription
                    }
                }
                if bgTask != .invalid { UIApplication.shared.endBackgroundTask(bgTask) }
            }
        }
    }

    private func performAssembly(_ job: HLSJob) async -> Result<URL, Error> {
        let dir = AppDirs.hlsJobDir(job.itemID)
        let destination = AppDirs.uniqueDestination(fileName: job.outputFileName)
        FileManager.default.createFile(atPath: destination.path, contents: nil)
        guard let handle = FileHandle(forWritingAtPath: destination.path) else {
            return .failure(CocoaError(.fileWriteUnknown))
        }
        defer { try? handle.close() }

        let keySession = HLSParser.makeSession(referer: job.referer, cookieHeader: job.cookieHeader)
        var keyCache: [URL: Data] = [:]

        do {
            if job.mapURL != nil {
                let mapData = try Data(contentsOf: dir.appendingPathComponent("map"))
                try handle.write(contentsOf: mapData)
            }
            for segment in job.segments.sorted(by: { $0.index < $1.index }) {
                let segURL = dir.appendingPathComponent("seg-\(segment.index)")
                var data = try Data(contentsOf: segURL)
                if let keyURL = segment.keyURL {
                    let keyData: Data
                    if let cached = keyCache[keyURL] {
                        keyData = cached
                    } else {
                        keyData = try await HLSParser.fetchData(keyURL, session: keySession)
                        keyCache[keyURL] = keyData
                    }
                    let iv = segment.iv ?? HLSParser.sequenceIV(segment.sequence)
                    data = try HLSParser.aes128CBCDecrypt(data: data, key: keyData, iv: iv)
                }
                try handle.write(contentsOf: data)
            }
            return .success(destination)
        } catch {
            try? FileManager.default.removeItem(at: destination)
            return .failure(error)
        }
    }

    private func cancelHLSTasks(for itemID: UUID) {
        session.getAllTasks { existing in
            let prefix = itemID.uuidString
            for task in existing {
                if let desc = task.taskDescription, desc.contains(prefix),
                   desc.hasPrefix("hls") {
                    task.cancel()
                }
            }
        }
    }

    private func removeHLSJob(_ itemID: UUID, removeTemp: Bool = true) {
        hlsJobs[itemID] = nil
        saveJobs()
        if removeTemp {
            try? FileManager.default.removeItem(at: AppDirs.hlsJobDir(itemID))
        }
    }

    private func cookieHeaderString(_ cookies: [HTTPCookie]) -> String? {
        guard !cookies.isEmpty else { return nil }
        return HTTPCookie.requestHeaderFields(with: cookies)["Cookie"]
    }

    // MARK: - Offline HLS (AVAssetDownloadTask)

    private func startAssetTask(for item: DownloadItem, cookies: [HTTPCookie]) {
        var options: [String: Any] = [:]
        var headers: [String: String] = ["User-Agent": browserUserAgent]
        if let referer = item.referer { headers["Referer"] = referer }
        options["AVURLAssetHTTPHeaderFieldsKey"] = headers
        if !cookies.isEmpty { options[AVURLAssetHTTPCookiesKey] = cookies }
        let asset = AVURLAsset(url: item.url, options: options)
        guard let task = assetSession.makeAssetDownloadTask(asset: asset,
                                                            assetTitle: item.fileName,
                                                            assetArtworkData: nil, options: nil) else {
            update(item.id) { $0.state = .failed; $0.errorMessage = "Could not create HLS download task" }
            return
        }
        task.taskDescription = item.id.uuidString
        assetTasks[item.id] = task
        task.resume()
    }

    private func fallbackToFileExport(_ id: UUID) {
        guard let item = items.first(where: { $0.id == id }), item.kind == .hlsAsset else { return }
        update(id) {
            $0.kind = .hlsFile
            $0.state = .downloading
            $0.progress = 0
            $0.receivedBytes = 0
            $0.errorMessage = nil
        }
        beginHLSFileJob(itemID: id, sourceURL: item.url,
                        baseName: (item.fileName as NSString).deletingPathExtension,
                        referer: item.referer, cookieHeader: nil)
        notify("Retrying as video file download…")
    }

    // MARK: - Reattach on launch

    private func reattachTasks() {
        assetSession.getAllTasks { [weak self] existing in
            DispatchQueue.main.async {
                guard let self else { return }
                for task in existing {
                    if let assetTask = task as? AVAssetDownloadTask,
                       let desc = assetTask.taskDescription, let id = UUID(uuidString: desc) {
                        self.assetTasks[id] = assetTask
                    }
                }
            }
        }
        session.getAllTasks { [weak self] existing in
            DispatchQueue.main.async {
                guard let self else { return }
                var liveHLSItems: Set<UUID> = []
                for task in existing {
                    guard let desc = task.taskDescription else { continue }
                    if desc.hasPrefix("hls") {
                        let parts = desc.components(separatedBy: "|")
                        if parts.count >= 2, let id = UUID(uuidString: parts[1]) {
                            liveHLSItems.insert(id)
                        }
                    } else if let id = UUID(uuidString: desc),
                              let download = task as? URLSessionDownloadTask {
                        self.tasks[id] = download
                    }
                }
                // Plain files with no live task → paused.
                for item in self.items where item.kind == .file
                    && (item.state == .downloading || item.state == .queued)
                    && self.tasks[item.id] == nil {
                    self.update(item.id) { $0.state = .paused }
                }
                // HLS jobs: if complete on disk, assemble; if tasks still live, leave running;
                // otherwise re-enqueue the remaining segments.
                for (id, job) in self.hlsJobs {
                    guard let item = self.items.first(where: { $0.id == id }) else {
                        self.removeHLSJob(id); continue
                    }
                    if item.state == .paused || item.state == .cancelled { continue }
                    if job.isComplete {
                        self.assembleHLS(id)
                    } else if !liveHLSItems.contains(id) {
                        self.enqueueRemainingSegments(job)
                    } else {
                        self.refreshHLSProgress(id)
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
               now.timeIntervalSince(meta.lastPublish) < 0.35, progress < 1 { return }
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

    private func loadJobs() {
        guard let data = try? Data(contentsOf: jobsURL),
              let decoded = try? JSONDecoder().decode([HLSJob].self, from: data) else { return }
        hlsJobs = Dictionary(uniqueKeysWithValues: decoded.map { ($0.itemID, $0) })
    }

    private func saveJobs() {
        guard let data = try? JSONEncoder().encode(Array(hlsJobs.values)) else { return }
        try? data.write(to: jobsURL, options: .atomic)
    }
}

// MARK: - URLSessionDownloadDelegate

extension DownloadManager: URLSessionDownloadDelegate {
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        guard let desc = downloadTask.taskDescription else { return }
        let attrs = try? FileManager.default.attributesOfItem(atPath: location.path)
        let fileSize = (attrs?[.size] as? Int64) ?? 0

        if desc.hasPrefix("hls") {
            handleHLSDownload(taskDescription: desc, location: location, fileSize: fileSize)
            return
        }

        guard let id = UUID(uuidString: desc) else { return }
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
        DispatchQueue.main.async { self.tasks[id] = nil; self.progressMeta[id] = nil }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        guard let desc = downloadTask.taskDescription, !desc.hasPrefix("hls"),
              let id = UUID(uuidString: desc) else { return }
        let progress = totalBytesExpectedToWrite > 0
            ? Double(totalBytesWritten) / Double(totalBytesExpectedToWrite) : 0
        throttledProgressUpdate(id, progress: progress,
                                received: totalBytesWritten, total: totalBytesExpectedToWrite)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error, let desc = task.taskDescription else { return }
        let nsError = error as NSError
        if nsError.code == NSURLErrorCancelled { return }

        if desc.hasPrefix("hls") {
            let parts = desc.components(separatedBy: "|")
            guard parts.count >= 2, let id = UUID(uuidString: parts[1]) else { return }
            update(id) {
                $0.state = .failed
                $0.errorMessage = "Some video parts couldn't be downloaded. Tap retry — starting while the video plays helps."
            }
            return
        }

        if task is AVAssetDownloadTask {
            DispatchQueue.main.async {
                if let id = UUID(uuidString: desc) {
                    self.assetTasks[id] = nil
                    self.fallbackToFileExport(id)
                }
            }
            return
        }

        guard let id = UUID(uuidString: desc) else { return }
        if let data = nsError.userInfo[NSURLSessionDownloadTaskResumeData] as? Data {
            DispatchQueue.main.async { self.resumeData[id] = data }
        }
        update(id) { $0.state = .failed; $0.bytesPerSecond = nil; $0.errorMessage = error.localizedDescription }
        DispatchQueue.main.async { self.tasks[id] = nil; self.progressMeta[id] = nil }
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
        DispatchQueue.main.async { self.assetTasks[id] = nil; self.progressMeta[id] = nil }
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
