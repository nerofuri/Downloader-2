import Foundation
import CommonCrypto
import UIKit

enum HLSError: Error, LocalizedError, Equatable {
    case cancelled
    case badPlaylist
    case noSegments
    case decryptFailed
    case unsupportedKey(String)

    var errorDescription: String? {
        switch self {
        case .cancelled: return "Cancelled"
        case .badPlaylist: return "Could not parse the m3u8 playlist"
        case .noSegments: return "The playlist contains no media segments"
        case .decryptFailed: return "Failed to decrypt a media segment"
        case .unsupportedKey(let method): return "Unsupported encryption: \(method) (DRM streams cannot be downloaded)"
        }
    }
}

/// Downloads an HLS stream and exports it as a single local media file.
/// Supports master + media playlists, byte-range-free TS/fMP4 segments and AES-128 encryption.
/// FairPlay/SAMPLE-AES (DRM) streams are rejected.
final class HLSFileDownloader {
    private let sourceURL: URL
    private let outputFileName: String
    private var cancelled = false
    private var bgTaskID: UIBackgroundTaskIdentifier = .invalid

    var onProgress: ((Double, Int64) -> Void)?
    var onCompletion: ((Result<URL, Error>) -> Void)?

    private struct Segment {
        let url: URL
        let key: KeyInfo?
        let sequence: Int
    }

    private struct KeyInfo {
        let uri: URL
        let iv: Data? // nil means derive from media sequence number
    }

    init(sourceURL: URL, outputFileName: String) {
        self.sourceURL = sourceURL
        self.outputFileName = outputFileName
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
            let httpSession = Self.makeSession()

            // 1. Fetch the playlist; if it is a master playlist, follow the best variant.
            var playlistURL = sourceURL
            var text = try await Self.fetchText(playlistURL, session: httpSession)
            if text.contains("#EXT-X-STREAM-INF") {
                guard let variant = Self.bestVariant(in: text, baseURL: playlistURL) else {
                    throw HLSError.badPlaylist
                }
                playlistURL = variant
                text = try await Self.fetchText(playlistURL, session: httpSession)
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
                let (data, _) = try await httpSession.data(from: mapURL)
                try handle.write(contentsOf: data)
                written += Int64(data.count)
            }

            // 4. Download, decrypt and append every segment.
            for (index, segment) in segments.enumerated() {
                if cancelled { throw HLSError.cancelled }
                var (data, _) = try await httpSession.data(from: segment.url)
                if let key = segment.key {
                    let keyData: Data
                    if let cached = keyCache[key.uri] {
                        keyData = cached
                    } else {
                        let (fetched, _) = try await httpSession.data(from: key.uri)
                        keyCache[key.uri] = fetched
                        keyData = fetched
                    }
                    let iv = key.iv ?? Self.sequenceIV(segment.sequence)
                    data = try Self.aes128CBCDecrypt(data: data, key: keyData, iv: iv)
                }
                try handle.write(contentsOf: data)
                written += Int64(data.count)
                onProgress?(Double(index + 1) / Double(segments.count), written)
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

    private static func makeSession() -> URLSession {
        let cfg = URLSessionConfiguration.default
        cfg.httpAdditionalHeaders = [
            "User-Agent": "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"
        ]
        cfg.timeoutIntervalForRequest = 30
        return URLSession(configuration: cfg)
    }

    private static func fetchText(_ url: URL, session: URLSession) async throws -> String {
        let (data, _) = try await session.data(from: url)
        guard let text = String(data: data, encoding: .utf8) else { throw HLSError.badPlaylist }
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
            } else if line.hasPrefix("#EXTINF") {
                expectSegment = true
            } else if expectSegment, !line.hasPrefix("#") {
                if let url = URL(string: line, relativeTo: baseURL)?.absoluteURL {
                    segments.append(Segment(url: url, key: currentKey, sequence: sequence))
                    sequence += 1
                }
                expectSegment = false
            }
        }
        return (segments, mapURL, mapURL != nil)
    }

    /// Extracts the value of ATTR=value or ATTR="value" from an m3u8 tag line.
    private static func attribute(_ name: String, in line: String) -> String? {
        guard let range = line.range(of: name + "=") else { return nil }
        let rest = line[range.upperBound...]
        if rest.hasPrefix("\"") {
            let afterQuote = rest.dropFirst()
            guard let end = afterQuote.firstIndex(of: "\"") else { return nil }
            return String(afterQuote[..<end])
        }
        let end = rest.firstIndex(of: ",") ?? rest.endIndex
        return String(rest[..<end])
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
        var output = Data(count: data.count + kCCBlockSizeAES128)
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
                                outputBytes.baseAddress, output.count,
                                &outputLength)
                    }
                }
            }
        }
        guard status == kCCSuccess else { throw HLSError.decryptFailed }
        return output.prefix(outputLength)
    }
}
