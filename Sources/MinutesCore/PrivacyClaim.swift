import Foundation

/// The claim the app is allowed to make, built from the configuration
/// actually in force. It does not say that nothing leaves the machine,
/// because the transcript does leave it for the model endpoint. It does not
/// say the recording is lawful or that anyone consented.
public enum PrivacyClaim {

    public static func text(endpoint: String, syncService: String?) -> String {
        var sentences = [
            "The recording and the transcript are made on this Mac.",
            "The transcript is sent to the model endpoint at \(endpoint) to write the notes.",
            "Nothing is sent to any other service.",
        ]
        if let syncService {
            sentences.append("Your notes folder syncs to \(syncService), so the notes are copied there too.")
        }
        return sentences.joined(separator: " ")
    }

    /// Shown once, on first run. Given the litigation around recording other
    /// people, this line is product design and not decoration.
    public static let firstRunNotice =
        "minutes does not tell the other people in the room that you are recording."
}
