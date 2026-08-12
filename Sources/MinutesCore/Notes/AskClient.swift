import Foundation

public struct AskRequest: Sendable, Equatable {
    public let title: String
    public let question: String
    public let transcript: String

    public init(title: String, question: String, transcript: String) {
        self.title = title
        self.question = question
        self.transcript = transcript
    }
}

public struct AskAnswer: Sendable, Equatable {
    public let text: String
    public let model: String
    public let endpoint: String

    public init(text: String, model: String, endpoint: String) {
        self.text = text
        self.model = model
        self.endpoint = endpoint
    }
}

/// Anything that can answer a question about one meeting. The same seam as
/// `NotesGenerating`, so the checks never open a connection.
public protocol Asking: Sendable {
    func ask(_ request: AskRequest) async throws -> AskAnswer
}

/// The question goes to the endpoint with the transcript and nothing else. The
/// answer is held to the same rule as the notes: only what was said, with the
/// timestamp of the line it rests on.
public enum AskPrompt {

    public static let system = """
        You answer questions about one meeting, using only the transcript you are given. \
        The transcript was recorded on the user's own computer.

        Rules:
        1. Answer only from the transcript. If the transcript does not answer the question, \
        say that it does not.
        2. Do not invent decisions, owners, dates, numbers or follow-up actions.
        3. Give the timestamp of the line every claim rests on, in the form [00:12:34].
        4. A few sentences at most. Plain text. No emoji, no preamble and no sign-off.
        """

    public static func user(title: String, question: String, transcript: String) -> String {
        """
        Meeting title: \(title)

        ## Question

        \(question)

        ## Transcript

        \(transcript)
        """
    }
}

extension OpenAICompatibleNotesClient: Asking {

    public func ask(_ request: AskRequest) async throws -> AskAnswer {
        let answer = try await complete(
            system: AskPrompt.system,
            user: AskPrompt.user(
                title: request.title, question: request.question, transcript: request.transcript),
            operation: askOperation)
        return AskAnswer(text: answer, model: model, endpoint: baseURL)
    }
}

/// One meeting's questions and answers, held for as long as the window is
/// open and written nowhere. A meeting folder is the record of the meeting;
/// what was asked about it afterwards is not.
public final class AskConversation {

    public struct Turn: Sendable, Equatable, Identifiable {
        public let id: Int
        public let question: String
        public let answer: String
    }

    public let title: String
    public private(set) var turns: [Turn] = []
    public private(set) var isAsking = false
    /// The app's own plain error voice, or nil when nothing has failed.
    public private(set) var failure: String?

    private var nextID = 0
    private let limit: Int

    public init(title: String, limit: Int = 12) {
        self.title = title
        self.limit = limit
    }

    /// State moves before the call and after it, never during, so the network
    /// is never inside the object that the window is drawing from.
    public func begin(_ question: String, transcript: String) -> AskRequest? {
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isAsking else { return nil }
        isAsking = true
        failure = nil
        return AskRequest(title: title, question: trimmed, transcript: transcript)
    }

    public func finish(_ answer: AskAnswer, for request: AskRequest) {
        isAsking = false
        failure = nil
        turns.append(Turn(id: nextID, question: request.question, answer: answer.text))
        nextID += 1
        if turns.count > limit { turns.removeFirst(turns.count - limit) }
    }

    public func fail(_ error: Error) {
        isAsking = false
        failure = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}
