import Foundation
import CommonCrypto

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

/// One media segment of an HLS stream, persisted so downloads survive app restarts.
struct HLSSegmentRef: Codable, Equatable {
    let index: Int
    let url: URL
    let keyURL: URL?
    let iv: Data?
    let sequence: Int
    let byteOffset: Int64?
    let byteLength: Int64?
}

/// A resumable HLS→file download job, persisted to disk.
struct HLSJob: Codable, Equatable {
    let itemID: UUID
    let outputFileName: String
    let usesFMP4: Bool
    let mapURL: URL?
    let referer: String?
    let cookieHeader: String?
    let segments: [HLSSegmentRef]
    var completed: [Int]
    var mapDone: Bool
    var receivedBytes: Int64

    var isComplete: Bool {
        completed.count >= segments.count && (mapURL == nil || mapDone)
    }
}

/// Parses HLS playlists and provides the AES-128 / helper routines shared by the
/// background segment downloader.
enum HLSParser {
    struct Result {
        let segments: [HLSSegmentRef]
        let mapURL: URL?
        let usesFMP4: Bool
    }

    static func parse(url: URL, referer: String?, cookieHeader: String?) async throws -> Result {
        let session = makeSession(referer: referer, cookieHeader: cookieHeader)

        var playlistURL = url
        var text = try await fetchText(playlistURL, session: session)
        if text.contains("#EXT-X-STREAM-INF") {
            guard let variant = bestVariant(in: text, baseURL: playlistURL) else {
                throw HLSError.badPlaylist
            }
            playlistURL = variant
            text = try await fetchText(playlistURL, session: session)
        }

        let (segments, mapURL, usesFMP4) = try parseMediaPlaylist(text, baseURL: playlistURL)
        guard !segments.isEmpty else { throw HLSError.noSegments }
        return Result(segments: segments, mapURL: mapURL, usesFMP4: usesFMP4)
    }

    // MARK: - Networking

    static func makeSession(referer: String?, cookieHeader: String?) -> URLSession {
        let cfg = URLSessionConfiguration.ephemeral
        var headers: [String: String] = ["User-Agent": browserUserAgent]
        if let referer {
            headers["Referer"] = referer
            if let refererURL = URL(string: referer), let scheme = refererURL.scheme,
               let host = refererURL.host {
                headers["Origin"] = "\(scheme)://\(host)"
            }
        }
        if let cookieHeader { headers["Cookie"] = cookieHeader }
        cfg.httpAdditionalHeaders = headers
        cfg.timeoutIntervalForRequest = 30
        cfg.httpMaximumConnectionsPerHost = 6
        return URLSession(configuration: cfg)
    }

    static func fetchData(_ url: URL, session: URLSession) async throws -> Data {
        var lastError: Error = HLSError.badPlaylist
        for attempt in 0..<3 {
            do {
                let (data, response) = try await session.data(from: url)
                if let http = response as? HTTPURLResponse,
                   !(http.statusCode == 200 || http.statusCode == 206) {
                    throw HLSError.httpStatus(http.statusCode)
                }
                return data
            } catch {
                lastError = error
                if case HLSError.httpStatus(let code) = error, code >= 400, code < 500 { throw error }
                if attempt < 2 { try? await Task.sleep(nanoseconds: 700_000_000) }
            }
        }
        throw lastError
    }

    private static func fetchText(_ url: URL, session: URLSession) async throws -> String {
        let data = try await fetchData(url, session: session)
        guard let text = String(data: data, encoding: .utf8), text.contains("#EXTM3U") else {
            throw HLSError.badPlaylist
        }
        return text
    }

    // MARK: - Playlist parsing

    private static func bestVariant(in master: String, baseURL: URL) -> URL? {
        var best: (bandwidth: Int, url: URL)?
        var pendingBandwidth: Int?
        for raw in master.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#EXT-X-STREAM-INF") {
                pendingBandwidth = attribute("BANDWIDTH", in: line).flatMap { Int($0) } ?? 0
            } else if let bandwidth = pendingBandwidth, !line.isEmpty, !line.hasPrefix("#") {
                if let url = URL(string: line, relativeTo: baseURL)?.absoluteURL {
                    if best == nil || bandwidth > best!.bandwidth { best = (bandwidth, url) }
                }
                pendingBandwidth = nil
            }
        }
        return best?.url
    }

    private static func parseMediaPlaylist(_ text: String, baseURL: URL) throws
        -> (segments: [HLSSegmentRef], mapURL: URL?, usesFMP4: Bool) {
        var segments: [HLSSegmentRef] = []
        var currentKeyURL: URL?
        var currentIV: Data?
        var mapURL: URL?
        var sequence = 0
        var expectSegment = false
        var pendingRange: (length: Int64, offset: Int64?)?
        var rangeCursor: [String: Int64] = [:]
        var index = 0

        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if line.hasPrefix("#EXT-X-MEDIA-SEQUENCE") {
                let value = line.components(separatedBy: ":").dropFirst().joined(separator: ":")
                sequence = Int(value.trimmingCharacters(in: .whitespaces)) ?? 0
            } else if line.hasPrefix("#EXT-X-KEY") {
                let method = attribute("METHOD", in: line) ?? "NONE"
                switch method {
                case "NONE":
                    currentKeyURL = nil; currentIV = nil
                case "AES-128":
                    guard let uriString = attribute("URI", in: line),
                          let uri = URL(string: uriString, relativeTo: baseURL)?.absoluteURL else {
                        throw HLSError.badPlaylist
                    }
                    currentKeyURL = uri
                    currentIV = attribute("IV", in: line).flatMap { hexData($0) }
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
                    pendingRange = (length, parts.count > 1 ? Int64(parts[1]) : nil)
                }
            } else if line.hasPrefix("#EXTINF") {
                expectSegment = true
            } else if expectSegment, !line.hasPrefix("#") {
                if let url = URL(string: line, relativeTo: baseURL)?.absoluteURL {
                    var offset: Int64?
                    var length: Int64?
                    if let range = pendingRange {
                        let start = range.offset ?? rangeCursor[url.absoluteString] ?? 0
                        offset = start
                        length = range.length
                        rangeCursor[url.absoluteString] = start + range.length
                    }
                    segments.append(HLSSegmentRef(index: index, url: url, keyURL: currentKeyURL,
                                                  iv: currentIV, sequence: sequence,
                                                  byteOffset: offset, byteLength: length))
                    index += 1
                    sequence += 1
                }
                pendingRange = nil
                expectSegment = false
            }
        }
        return (segments, mapURL, mapURL != nil)
    }

    static func attribute(_ name: String, in line: String) -> String? {
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

    static func sequenceIV(_ sequence: Int) -> Data {
        var iv = Data(count: 16)
        var value = UInt64(sequence).bigEndian
        withUnsafeBytes(of: &value) { bytes in
            iv.replaceSubrange(8..<16, with: bytes)
        }
        return iv
    }

    // MARK: - Crypto

    static func aes128CBCDecrypt(data: Data, key: Data, iv: Data) throws -> Data {
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
