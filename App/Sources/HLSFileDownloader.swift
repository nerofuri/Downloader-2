import Foundation
import CommonCrypto
import UIKit

enum HLSError: Error, LocalizedError, Equatable {
    case cancelled
    case badPlaylist
    case noSegments
    case decryptFailed
    case httpStatus(Int)
    case unsupportedKey(String)

    var errorDescription: String? {
        switch self {
        case .cancelled: return "Cancelled"
        case .badPlaylist: return "Could not parse the m3u8 playlist"
        case .noSegments: return "The playlist contains no media segments"
        case .decryptFailed: return "Failed to decrypt a media segment"
        case .httpStatus(let code):
            return code == 403
                ? "Server refused the request (403). Try starting the download while the video is playing."
                : "Server error (HTTP \(code))"
        case .unsupportedKey(let method): return "This stream uses DRM (\(method)) and cannot be downloaded"
        }
    }
}

/// Downloads an HLS stream and exports it as a single local media file.
/// Sends browser-like headers (User-Agent, Referer, Origin) plus the page's cookies,
/// downloads segments in parallel with retries, supports byte-range playlists and
/// AES-128 encryption. FairPlay/SAMPLE-AES (DRM) streams are rejected.
final class HLSFileDownloader {
    private let sourceURL: URL
    private let outputFileName: String
    private let referer: String?
    private let cookies: [HTTPCookie]
    private var cancelled = false
    private var bgTaskID: UIBackgroundTaskIdentifier = .invalid

    var onProgress: ((Double, Int64) -> Void)?
    var onCompletion: ((Result<URL, Error>) -> Void)?

    private struct Segment {
        let url: URL
        let key: KeyInfo?
        let sequence: Int
        let byteRange: (offset: Int64, length: Int64)?
    }

    private struct KeyInfo {
        let uri: URL
        let iv: Data? // nil means derive from media sequence number
    }

    init(sourceURL: URL, outputFileName: String, referer: String? = nil,
         cookies: [HTTPCookie] = []) {
        self.sourceURL = sourceURL
        self.outputFileName = outputFileName
        self.referer = referer
        self.cookies = cookies
    }

    func start() {
        bgTaskID = UIApplication.shared.beginBackgroundTask(withName: "hls-export") { [weak self] in
            self?.cancel()
        }
        Task.detached(priority: .userInitiated) { [weak self] in
            await self?.run()
        }
    }

    func cancel() {
        cancelled = true
    }

    private func finish(_ result: Result<URL, Error>) {
        if bgTaskID != .invalid {
            let id = bgTaskID
            bgTaskID = .invalid
            DispatchQueue.main.async { UIApplication.shared.endBackgroundTask(id) }
        }
        onCompletion?(result)
    }

    private func run() async {
        do {
            let session = makeSession()

            // 1. Fetch the playlist; if it is a master playlist, follow the best variant.
            var playlistURL = sourceURL
            var text = try await fetchText(playlistURL, session: session)
            if text.contains("#EXT-X-STREAM-INF") {
                guard let variant = Self.bestVariant(in: text, baseURL: playlistURL) else {
                    throw HLSError.badPlaylist
                }
                playlistURL = variant
                text = try await fetchText(playlistURL, session: session)
            }

            // 2. Parse segments.
            let (segments, mapURL, usesFMP4) = try Self.parseMediaPlaylist(text, baseURL: playlistURL)
            guard !segments.isEmpty else { throw HLSError.noSegments }

            // 3. Prepare output file.
            let ext = usesFMP4 ? "mp4" : "ts"
            let baseName = (outputFileName as NSString).deletingPathExtension
            let destination = AppDirs.uniqueDestination(fileName: baseName + "." + ext)
            FileManager.default.createFile(atPath: destination.path, contents: nil)
            guard let handle = FileHandle(forWritingAtPath: destination.path) else {
                throw CocoaError(.fileWriteUnknown)
            }
            defer { try? handle.close() }

            var written: Int64 = 0
            var keyCache: [URL: Data] = [:]

            if let mapURL {
                let data = try await fetchData(mapURL, session: session)
                try handle.write(contentsOf: data)
                written += Int64(data.count)
            }

            // 4. Download in parallel batches, then decrypt and append in order.
            let batchSize = 4
            var index = 0
            while index < segments.count {
                if cancelled { throw HLSError.cancelled }
                let batch = Array(segments[index..<min(index + batchSize, segments.count)])
                let fetched = try await withThrowingTaskGroup(of: (Int, Data).self,
                                                              returning: [Int: Data].self) { group in
                    for (offset, segment) in batch.enumerated() {
                        group.addTask {
                            let data = try await self.fetchData(segment.url, session: session,
                                                                byteRange: segment.byteRange)
                            return (offset, data)
                        }
                    }
                    var results: [Int: Data] = [:]
                    for try await (offset, data) in group { results[offset] = data }
                    return results
                }
                for (offset, segment) in batch.enumerated() {
                    guard var data = fetched[offset] else { throw HLSError.badPlaylist }
                    if let key = segment.key {
                        let keyData: Data
                        if let cached = keyCache[key.uri] {
                            keyData = cached
                        } else {
                            keyData = try await fetchData(key.uri, session: session)
                            keyCache[key.uri] = keyData
                        }
                        let iv = key.iv ?? Self.sequenceIV(segment.sequence)
                        data = try Self.aes128CBCDecrypt(data: data, key: keyData, iv: iv)
                    }
                    try handle.write(contentsOf: data)
                    written += Int64(data.count)
                }
                index += batch.count
                onProgress?(Double(index) / Double(segments.count), written)
            }

            finish(.success(destination))
        } catch {
            if cancelled {
                finish(.failure(HLSError.cancelled))
            } else {
                finish(.failure(error))
            }
        }
    }

    // MARK: - Networking

    private func makeSession() -> URLSession {
        let cfg = URLSessionConfiguration.ephemeral
        var headers: [String: String] = ["User-Agent": browserUserAgent]
        if let referer {
            headers["Referer"] = referer
            if let refererURL = URL(string: referer), let scheme = refererURL.scheme,
               let host = refererURL.host {
                headers["Origin"] = "\(scheme)://\(host)"
            }
        }
        cfg.httpAdditionalHeaders = headers
        cfg.httpCookieAcceptPolicy = .always
        cfg.httpShouldSetCookies = true
        cookies.forEach { cfg.httpCookieStorage?.setCookie($0) }
        cfg.timeoutIntervalForRequest = 30
        cfg.httpMaximumConnectionsPerHost = 6
        return URLSession(configuration: cfg)
    }

    /// Fetches a URL with up to 3 attempts and HTTP status validation.
    private func fetchData(_ url: URL, session: URLSession,
                           byteRange: (offset: Int64, length: Int64)? = nil) async throws -> Data {
        var lastError: Error = HLSError.badPlaylist
        for attempt in 0..<3 {
            if cancelled { throw HLSError.cancelled }
            do {
                var request = URLRequest(url: url)
                if let byteRange {
                    let end = byteRange.offset + byteRange.length - 1
                    request.setValue("bytes=\(byteRange.offset)-\(end)", forHTTPHeaderField: "Range")
                }
                let (data, response) = try await session.data(for: request)
                if let http = response as? HTTPURLResponse {
                    guard http.statusCode == 200 || http.statusCode == 206 else {
                        throw HLSError.httpStatus(http.statusCode)
                    }
                }
                return data
            } catch {
                lastError = error
                // 4xx responses won't get better with retries.
                if case HLSError.httpStatus(let code) = error, code >= 400, code < 500 { throw error }
                if attempt < 2 {
                    try? await Task.sleep(nanoseconds: 800_000_000)
                }
            }
        }
        throw lastError
    }

    private func fetchText(_ url: URL, session: URLSession) async throws -> String {
        let data = try await fetchData(url, session: session)
        guard let text = String(data: data, encoding: .utf8) else { throw HLSError.badPlaylist }
        guard text.contains("#EXTM3U") else { throw HLSError.badPlaylist }
        return text
    }

    // MARK: - Playlist parsing

    private static func bestVariant(in master: String, baseURL: URL) -> URL? {
        var best: (bandwidth: Int, url: URL)?
        let lines = master.components(separatedBy: .newlines)
        var pendingBandwidth: Int?
        for raw in lines {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#EXT-X-STREAM-INF") {
                pendingBandwidth = attribute("BANDWIDTH", in: line).flatMap { Int($0) } ?? 0
            } else if let bandwidth = pendingBandwidth, !line.isEmpty, !line.hasPrefix("#") {
                if let url = URL(string: line, relativeTo: baseURL)?.absoluteURL {
                    if best == nil || bandwidth > best!.bandwidth {
                        best = (bandwidth, url)
                    }
                }
                pendingBandwidth = nil
            }
        }
        return best?.url
    }

    private static func parseMediaPlaylist(_ text: String, baseURL: URL) throws
        -> (segments: [Segment], mapURL: URL?, usesFMP4: Bool) {
        var segments: [Segment] = []
        var currentKey: KeyInfo?
        var mapURL: URL?
        var mediaSequence = 0
        var sequence = 0
        var expectSegment = false
        var pendingRange: (length: Int64, offset: Int64?)?
        var rangeCursor: [String: Int64] = [:]

        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if line.hasPrefix("#EXT-X-MEDIA-SEQUENCE") {
                let value = line.components(separatedBy: ":").dropFirst().joined(separator: ":")
                mediaSequence = Int(value.trimmingCharacters(in: .whitespaces)) ?? 0
                sequence = mediaSequence
            } else if line.hasPrefix("#EXT-X-KEY") {
                let method = attribute("METHOD", in: line) ?? "NONE"
                switch method {
                case "NONE":
                    currentKey = nil
                case "AES-128":
                    guard let uriString = attribute("URI", in: line),
                          let uri = URL(string: uriString, relativeTo: baseURL)?.absoluteURL else {
                        throw HLSError.badPlaylist
                    }
                    let iv = attribute("IV", in: line).flatMap { hexData($0) }
                    currentKey = KeyInfo(uri: uri, iv: iv)
                default:
                    throw HLSError.unsupportedKey(method)
                }
            } else if line.hasPrefix("#EXT-X-MAP") {
                if let uriString = attribute("URI", in: line) {
                    mapURL = URL(string: uriString, relativeTo: baseURL)?.absoluteURL
                }
            } else if line.hasPrefix("#EXT-X-BYTERANGE") {
                let value = line.components(separatedBy: ":").dropFirst().joined(separator: ":")
                let parts = value.split(separator: "@")
                if let length = parts.first.flatMap({ Int64($0) }) {
                    let offset = parts.count > 1 ? Int64(parts[1]) : nil
                    pendingRange = (length, offset)
                }
            } else if line.hasPrefix("#EXTINF") {
                expectSegment = true
            } else if expectSegment, !line.hasPrefix("#") {
                if let url = URL(string: line, relativeTo: baseURL)?.absoluteURL {
                    var byteRange: (offset: Int64, length: Int64)?
                    if let range = pendingRange {
                        let offset = range.offset ?? rangeCursor[url.absoluteString] ?? 0
                        byteRange = (offset, range.length)
                        rangeCursor[url.absoluteString] = offset + range.length
                    }
                    segments.append(Segment(url: url, key: currentKey,
                                            sequence: sequence, byteRange: byteRange))
                    sequence += 1
                }
                pendingRange = nil
                expectSegment = false
            }
        }
        return (segments, mapURL, mapURL != nil)
    }

    /// Extracts the value of ATTR=value or ATTR="value" from an m3u8 tag line.
    private static func attribute(_ name: String, in line: String) -> String? {
        // Anchor on ",NAME=" or ":NAME=" so e.g. BANDWIDTH doesn't match AVERAGE-BANDWIDTH.
        var searchRange = line.startIndex..<line.endIndex
        while let range = line.range(of: name + "=", range: searchRange) {
            let preceding: Character = range.lowerBound > line.startIndex
                ? line[line.index(before: range.lowerBound)] : ","
            if preceding == "," || preceding == ":" {
                let rest = line[range.upperBound...]
                if rest.hasPrefix("\"") {
                    let afterQuote = rest.dropFirst()
                    guard let end = afterQuote.firstIndex(of: "\"") else { return nil }
                    return String(afterQuote[..<end])
                }
                let end = rest.firstIndex(of: ",") ?? rest.endIndex
                return String(rest[..<end])
            }
            searchRange = range.upperBound..<line.endIndex
        }
        return nil
    }

    private static func hexData(_ string: String) -> Data? {
        var hex = string.lowercased()
        if hex.hasPrefix("0x") { hex = String(hex.dropFirst(2)) }
        guard hex.count % 2 == 0 else { return nil }
        var data = Data(capacity: hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            data.append(byte)
            index = next
        }
        return data
    }

    private static func sequenceIV(_ sequence: Int) -> Data {
        var iv = Data(count: 16)
        var value = UInt64(sequence).bigEndian
        withUnsafeBytes(of: &value) { bytes in
            iv.replaceSubrange(8..<16, with: bytes)
        }
        return iv
    }

    // MARK: - Crypto

    private static func aes128CBCDecrypt(data: Data, key: Data, iv: Data) throws -> Data {
        let outputCapacity = data.count + kCCBlockSizeAES128
        var output = Data(count: outputCapacity)
        var outputLength = 0
        let status = output.withUnsafeMutableBytes { outputBytes in
            data.withUnsafeBytes { dataBytes in
                key.withUnsafeBytes { keyBytes in
                    iv.withUnsafeBytes { ivBytes in
                        CCCrypt(CCOperation(kCCDecrypt),
                                CCAlgorithm(kCCAlgorithmAES),
                                CCOptions(kCCOptionPKCS7Padding),
                                keyBytes.baseAddress, key.count,
                                ivBytes.baseAddress,
                                dataBytes.baseAddress, data.count,
                                outputBytes.baseAddress, outputCapacity,
                                &outputLength)
                    }
                }
            }
        }
        guard status == kCCSuccess else { throw HLSError.decryptFailed }
        return output.prefix(outputLength)
    }
}
