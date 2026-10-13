import Foundation

/// Where the OMR server is. The address is user-entered (a LAN host or a container somewhere else), like
/// any self-hosted service.
public struct OMRServerConfig: Hashable, Codable, Sendable {
    public var baseURL: URL
    public var token: String?

    public init(baseURL: URL, token: String? = nil) {
        self.baseURL = baseURL
        self.token = token?.isEmpty == true ? nil : token
    }

    /// Accepts "192.168.1.20:8765", "omr.local" or a full URL; adds http:// and the default port.
    public static func parse(_ text: String, token: String? = nil) -> OMRServerConfig? {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        if !s.contains("://") { s = "http://" + s }
        guard var c = URLComponents(string: s), c.host?.isEmpty == false else { return nil }
        if c.port == nil, c.scheme == "http" { c.port = 8765 }
        c.path = c.path.hasSuffix("/") ? String(c.path.dropLast()) : c.path
        return c.url.map { OMRServerConfig(baseURL: $0, token: token) }
    }
}

public struct OMRServerInfo: Decodable, Sendable {
    public let status: String
    public let engine: String
    public let version: String
    public let auth: Bool
    public let queued: Int
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
        case .unreachable(let s): "Couldn't reach the recognition server (\(s)). Check the address in Settings and that the container is running."
        case .unauthorised: "The recognition server needs a token, or the token in Settings is wrong."
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

/// Client for `server/omr_server.py`: upload, poll, download MusicXML, parse.
public final class OMRClient: Sendable {
    private let config: OMRServerConfig
    private let session: URLSession
    private let pollInterval: Swift.Duration

    public init(config: OMRServerConfig, session: URLSession = .shared, pollInterval: Swift.Duration = .seconds(2)) {
        self.config = config
        self.session = session
        self.pollInterval = pollInterval
    }

    public func health() async throws -> OMRServerInfo {
        try JSONDecoder().decode(OMRServerInfo.self, from: try await send(request("health")))
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
            Task.detached { [session] in _ = try? await session.data(for: cleanup) }
            if error is CancellationError { throw OMRError.cancelled }
            throw error
        }
    }

    private func request(_ path: String, method: String = "GET", query: [URLQueryItem] = []) -> URLRequest {
        var c = URLComponents(url: config.baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { c.queryItems = query }
        var r = URLRequest(url: c.url!)
        r.httpMethod = method
        r.timeoutInterval = 30
        if let token = config.token { r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        return r
    }

    private func send(_ request: URLRequest) async throws -> Data {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch is CancellationError {
            throw OMRError.cancelled
        } catch let e as URLError where e.code == .cancelled {
            throw OMRError.cancelled
        } catch {
            throw OMRError.unreachable(error.localizedDescription)
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        switch status {
        case 200..<300: return data
        case 401: throw OMRError.unauthorised
        default:
            let message = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String
            throw OMRError.rejected(message ?? "HTTP \(status)")
        }
    }
}
