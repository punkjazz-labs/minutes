import Foundation

public struct NotesRequest: Sendable {
    public let title: String
    public let ownerNotes: String
    public let transcript: String

    public init(title: String, ownerNotes: String, transcript: String) {
        self.title = title
        self.ownerNotes = ownerNotes
        self.transcript = transcript
    }
}

public struct NotesResult: Sendable {
    public let markdown: String
    public let model: String
    public let endpoint: String

    public init(markdown: String, model: String, endpoint: String) {
        self.markdown = markdown
        self.model = model
        self.endpoint = endpoint
    }
}

public enum NotesError: Error, LocalizedError {
    case unreachable(String)
    case unauthorized(String)
    case server(Int, String)
    case emptyResponse
    case badURL(String)

    public var errorDescription: String? {
        switch self {
        case .unreachable(let endpoint):
            return "The notes endpoint at \(endpoint) did not answer, so the transcript is saved and the notes are waiting."
        case .unauthorized(let endpoint):
            return "The endpoint at \(endpoint) rejected the API key. Set the key in minutes settings."
        case .server(let status, let body):
            let detail = body.isEmpty ? "" : " \(body.prefix(300))"
            return "The notes endpoint answered with status \(status).\(detail)"
        case .emptyResponse:
            return "The notes endpoint answered with no content."
        case .badURL(let value):
            return "The notes endpoint \(value) is not a usable URL."
        }
    }

    /// True when the right move is to keep the transcript and retry later,
    /// rather than to tell the owner something is wrong with their setup.
    public var isRetryable: Bool {
        switch self {
        case .unreachable, .server: return true
        case .unauthorized, .emptyResponse, .badURL: return false
        }
    }
}

/// Anything that can turn a transcript plus bullets into notes.
public protocol NotesGenerating: Sendable {
    func enhance(_ request: NotesRequest) async throws -> NotesResult
    /// Names the models the endpoint offers. Used to prove the endpoint and
    /// the key work before a meeting, not after one.
    func probeModels() async throws -> [String]
}

/// Talks to any OpenAI-compatible endpoint.
///
/// The default endpoint is the LiteLLM gateway on this machine and the default
/// model is the `profile/general` alias, so the app does not depend on which
/// concrete model happens to be behind it. Both are settings, and the app
/// opens no other outbound connection.
public struct OpenAICompatibleNotesClient: NotesGenerating {

    public let baseURL: String
    public let model: String
    public let apiKey: String
    public let appID: String
    public let operation: String
    /// The operation name a question about a meeting is routed under, so the
    /// gateway can tell the two kinds of request apart.
    public let askOperation: String
    private let session: URLSession
    private let timeout: TimeInterval

    public init(
        baseURL: String,
        model: String,
        apiKey: String,
        appID: String = MinutesBuild.appID,
        operation: String = "meeting-notes-enhance",
        askOperation: String = "meeting-ask",
        timeout: TimeInterval = 300,
        session: URLSession = .shared
    ) {
        self.baseURL = baseURL
        self.model = model
        self.apiKey = apiKey
        self.appID = appID
        self.operation = operation
        self.askOperation = askOperation
        self.timeout = timeout
        self.session = session
    }

    private func url(path: String) throws -> URL {
        let trimmed = baseURL.hasSuffix("/") ? String(baseURL.dropLast()) : baseURL
        guard let url = URL(string: trimmed + path) else { throw NotesError.badURL(baseURL) }
        return url
    }

    private func request(path: String, method: String) throws -> URLRequest {
        var request = URLRequest(url: try url(path: path))
        request.httpMethod = method
        request.timeoutInterval = timeout
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        // Routing identity for the gateway. Not a secret.
        request.setValue(appID, forHTTPHeaderField: "x-litellm-customer-id")
        request.setValue("\(MinutesBuild.productName)/\(MinutesBuild.version)", forHTTPHeaderField: "User-Agent")
        return request
    }

    public func probeModels() async throws -> [String] {
        let request = try self.request(path: "/models", method: "GET")
        let (data, response) = try await send(request)
        try check(response: response, data: data)

        struct ModelList: Decodable {
            struct Entry: Decodable { let id: String }
            let data: [Entry]
        }
        guard let list = try? JSONDecoder().decode(ModelList.self, from: data) else {
            throw NotesError.emptyResponse
        }
        return list.data.map(\.id)
    }

    public func enhance(_ notesRequest: NotesRequest) async throws -> NotesResult {
        let content = try await complete(
            system: NotesPrompt.system,
            user: NotesPrompt.user(
                title: notesRequest.title,
                ownerNotes: notesRequest.ownerNotes,
                transcript: notesRequest.transcript),
            operation: operation)
        return NotesResult(markdown: content, model: model, endpoint: baseURL)
    }

    /// One chat completion, shared by the notes and by a question about a
    /// meeting, so both are held to the same errors and the same routing.
    func complete(system: String, user: String, operation: String) async throws -> String {
        var request = try self.request(path: "/chat/completions", method: "POST")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "model": model,
            "temperature": 0.2,
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": user],
            ],
            "metadata": ["operation": operation],
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await send(request)
        try check(response: response, data: data)

        struct Completion: Decodable {
            struct Choice: Decodable {
                struct Message: Decodable { let content: String? }
                let message: Message
            }
            let choices: [Choice]
        }
        guard
            let decoded = try? JSONDecoder().decode(Completion.self, from: data),
            let content = decoded.choices.first?.message.content,
            !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            throw NotesError.emptyResponse
        }

        return content.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
        do {
            return try await session.data(for: request)
        } catch let error as URLError {
            switch error.code {
            case .cannotConnectToHost, .cannotFindHost, .networkConnectionLost,
                .notConnectedToInternet, .timedOut, .dnsLookupFailed:
                throw NotesError.unreachable(baseURL)
            default:
                throw NotesError.unreachable(baseURL)
            }
        }
    }

    private func check(response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else { return }
        switch http.statusCode {
        case 200..<300:
            return
        case 401, 403:
            throw NotesError.unauthorized(baseURL)
        default:
            throw NotesError.server(http.statusCode, String(decoding: data, as: UTF8.self))
        }
    }
}
