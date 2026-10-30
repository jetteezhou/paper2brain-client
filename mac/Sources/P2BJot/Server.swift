import Foundation

/// The paper2brain server, with this Mac's agent token (~/.paper2brain-client/config.json, written by setup.sh). The token
/// reaches only the 随手记 routes of its owner's personal library (and the upload), besides what the runner uses.
final class Server: @unchecked Sendable {
    static let shared = Server()

    let base: URL?
    private let token: String?
    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30
        return URLSession(configuration: config)
    }()

    init() {
        let env = ProcessInfo.processInfo.environment
        let home = env["P2B_CLIENT_HOME"] ?? (NSHomeDirectory() + "/.paper2brain-client")
        let config = (try? Data(contentsOf: URL(fileURLWithPath: home + "/config.json")))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        let server = env["P2B_SERVER"] ?? config["server"] as? String
        base = server.flatMap { URL(string: $0.hasSuffix("/") ? String($0.dropLast()) : $0) }
        token = env["P2B_TOKEN"] ?? config["server_token"] as? String
    }

    var configured: Bool { base != nil && token != nil }
    var page: URL? { base.flatMap { URL(string: $0.absoluteString + "/#/idea2do") } }

    func data(_ method: String, _ path: String, json: [String: Any]? = nil, body: Data? = nil) async throws -> Data {
        guard let base, let token, let url = URL(string: base.absoluteString + path) else { throw Failure.notConfigured }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let json {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: json)
        } else if let body {
            req.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
            req.httpBody = body
        }
        let (data, response) = try await session.data(for: req)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else {
            let said = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String
            throw Failure.http(code, said ?? "服务器返回 \(code)")
        }
        return data
    }

    func get<T: Decodable>(_ path: String, as: T.Type = T.self) async throws -> T {
        try JSONDecoder().decode(T.self, from: try await data("GET", path))
    }

    @discardableResult
    func post(_ path: String, _ json: [String: Any] = [:]) async throws -> Data {
        try await data("POST", path, json: json)
    }

    /// An attachment as it is, like the web page's (PUT /api/bot/inputs); tied to a capture when the capture is sent.
    func upload(name: String, data body: Data) async throws -> String {
        let name = name.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed.subtracting(CharacterSet(charactersIn: "&=+"))) ?? "file"
        let got = try JSONSerialization.jsonObject(with: try await data("PUT", "/api/bot/inputs?name=\(name)", body: body)) as? [String: Any]
        guard let id = got?["id"] as? String else { throw Failure.http(0, "上传没有返回文件") }
        return id
    }

    enum Failure: LocalizedError {
        case notConfigured, http(Int, String)
        var errorDescription: String? {
            switch self {
            case .notConfigured: return "还没连上服务器：先在 paper2brain-client 里运行 ./setup.sh"
            case let .http(code, text): return code == 403 ? "服务器拒绝了：\(text)（服务器要更新到支持随手记小程序的版本）" : text
            }
        }
    }
}

// MARK: What the server sends

struct Status: Decodable, Equatable {
    var pending: Int
    var organizing: Int
    var failed: Int
    var next: [NextItem]
    var suggestions: [Suggestion]
}

struct NextItem: Decodable, Equatable, Identifiable {
    var id: String
    var title: String
    var reason: String?
    var group: String
}

struct Suggestion: Decodable, Equatable, Identifiable {
    var id: String
    var text: String
}

struct DateSpec: Decodable, Equatable {
    var raw: String?
    var date: String?
    var certainty: String?
}

struct SyncTask: Decodable {
    var id: String
    var title: String
    var status: String
    var due: DateSpec?
    var remind: DateSpec?
    var priority: String?
    var quote: String?
    var revision: Int
}

struct SyncDoc: Decodable {
    var tz: String
    var tasks: [SyncTask]
}
