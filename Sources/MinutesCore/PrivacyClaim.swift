import Foundation

/// The claim the app is allowed to make, built from the configuration
/// actually in force. It does not say that nothing leaves the machine,
/// because the transcript does leave it for the model endpoint. It does not
/// say the recording is lawful or that anyone consented.
///
/// It also does not speak for the endpoint. minutes sends the transcript to
/// one address and nowhere else, and that is all it can know: a gateway such
/// as LiteLLM decides for itself which model, on which machine or which
/// service, the transcript reaches next.
public enum PrivacyClaim {

    public static func text(endpoint: String, syncService: String?) -> String {
        var sentences = [
            "The recording and the transcript are made on this Mac.",
            "The transcript is sent to the model endpoint at \(endpoint) to write the notes.",
            "minutes sends nothing to any other service. Where that endpoint passes the transcript on to is set by the endpoint, not by minutes.",
        ]
        if isPlainHTTPToAnotherMachine(endpoint) {
            sentences.append("That address is plain http to another machine, so the transcript crosses the network unencrypted.")
        }
        if let syncService {
            sentences.append("Your notes folder syncs to \(syncService), so the notes are copied there too.")
        }
        return sentences.joined(separator: " ")
    }

    /// True when the endpoint is http rather than https and is not this Mac.
    /// Traffic to this Mac never touches a network, so http there is fine.
    public static func isPlainHTTPToAnotherMachine(_ endpoint: String) -> Bool {
        guard let url = URL(string: endpoint), url.scheme?.lowercased() == "http" else { return false }
        let host = (url.host ?? "").lowercased()
        return !["localhost", "127.0.0.1", "::1", "[::1]"].contains(host) && !host.isEmpty
    }

    /// Shown once, on first run. Given the litigation around recording other
    /// people, this line is product design and not decoration.
    public static let firstRunNotice =
        "minutes does not tell the other people in the room that you are recording."
}
