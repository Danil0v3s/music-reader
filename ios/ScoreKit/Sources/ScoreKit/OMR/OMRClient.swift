import Foundation

/// Where the Music Reader server is (server/: recognition, accounts, libraries), and which install of the
/// app is talking to it.
public struct OMRServerConfig: Hashable, Codable, Sendable {
    public var baseURL: URL
    public var device: DeviceInfo?

    public init(baseURL: URL, device: DeviceInfo? = nil) {
        self.baseURL = baseURL
        self.device = device
    }

    /// Accepts "192.168.1.20:8765", "omr.local" or a full URL; adds http:// and the default port.
    public static func parse(_ text: String, device: DeviceInfo? = nil) -> OMRServerConfig? {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        if !s.contains("://") { s = "http://" + s }
        guard var c = URLComponents(string: s), c.host?.isEmpty == false else { return nil }
        if c.port == nil, c.scheme == "http" { c.port = 8765 }
        c.path = c.path.hasSuffix("/") ? String(c.path.dropLast()) : c.path
        return c.url.map { OMRServerConfig(baseURL: $0, device: device) }
    }
}

public struct OMRServerInfo: Decodable, Sendable {
    public let status: String
    public let engine: String
    public let version: String
    public let queued: Int
    /// Ways to sign in the server offers ("apple", "google", "email", "guest").
    public let providers: [String]?
}

public struct OMRJob: Decodable, Sendable {
    public enum Status: String, Decodable, Sendable { case queued, running, done, failed }
    public let id: String
    public let status: Status
    public let error: String?
    public let movements: Int
    public let elapsed: Double
}

public enum OMRError: Error, LocalizedError, Equatable {
    case unreachable(String)
    case unauthorised
    case rejected(String)
    case failed(String)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .unreachable(let s): "Couldn't reach the server (\(s)). Check your connection, and the server address in Settings."
        case .unauthorised: "Your session has ended. Sign in again."
        case .rejected(let s): "The server refused the file: \(s)"
        case .failed(let s): "Recognition failed: \(s)"
        case .cancelled: "Cancelled."
        }
    }
}

/// Progress of a transcription, for the import screen.
public enum OMRProgress: Sendable, Equatable {
    case uploading
    case queued
    case recognising(seconds: Double)
    case downloading
}

/// Client for recognition (server/api.py, /jobs): upload, poll, download MusicXML, parse.
public final class OMRClient: Sendable {
    private let http: ServerHTTP
    private let pollInterval: Swift.Duration

    public init(config: OMRServerConfig, auth: (any SessionProvider)? = nil, session: URLSession = .shared,
                pollInterval: Swift.Duration = .seconds(2)) {
        http = ServerHTTP(config: config, session: session, auth: auth)
        self.pollInterval = pollInterval
    }

    public func health() async throws -> OMRServerInfo {
        try JSONDecoder().decode(OMRServerInfo.self, from: try await http.sendOnce(request("health")))
    }

    /// Uploads a file, waits for Audiveris, and returns every movement it found as a score. The task can be
    /// cancelled; the server-side job is then deleted.
    public func transcribe(_ file: Data, filename: String,
                           progress: @escaping @Sendable (OMRProgress) -> Void = { _ in }) async throws -> [Score] {
        progress(.uploading)
        var upload = request("jobs", method: "POST")
        upload.setValue(filename, forHTTPHeaderField: "X-Filename")
        upload.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        upload.httpBody = file
        upload.timeoutInterval = 300
        var job = try JSONDecoder().decode(OMRJob.self, from: try await send(upload))
        do {
            while job.status == .queued || job.status == .running {
                progress(job.status == .queued ? .queued : .recognising(seconds: job.elapsed))
                try await Task.sleep(for: pollInterval)
                job = try JSONDecoder().decode(OMRJob.self, from: try await send(request("jobs/\(job.id)")))
            }
            guard job.status == .done else { throw OMRError.failed(job.error ?? "unknown error") }
            progress(.downloading)
            var scores: [Score] = []
            for movement in 0..<max(1, job.movements) {
                let xml = try await send(request("jobs/\(job.id)/musicxml", query: [URLQueryItem(name: "movement", value: "\(movement)")]))
                var score = try MusicXMLReader.read(xml)
                score.source = .omr
                if score.title == "Untitled" {
                    let base = (filename as NSString).deletingPathExtension
                    score.title = job.movements > 1 ? "\(base) (\(movement + 1))" : base
                }
                scores.append(score)
            }
            _ = try? await send(request("jobs/\(job.id)", method: "DELETE"))
            return scores
        } catch {
            let id = job.id
            let cleanup = request("jobs/\(id)", method: "DELETE")
            Task.detached { [http] in _ = try? await http.send(cleanup) }
            if error is CancellationError { throw OMRError.cancelled }
            throw error
        }
    }

    private func request(_ path: String, method: String = "GET", query: [URLQueryItem] = []) -> URLRequest {
        var r = http.request(path, method: method, query: query)
        r.timeoutInterval = 30
        return r
    }

    private func send(_ request: URLRequest) async throws -> Data { try await http.send(request) }
}
