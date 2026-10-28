import Foundation

/// What the owner typed for a meeting: the title, and the bullets that become
/// the prompt and are kept word for word in `notes.md`.
///
/// The draft belongs to one meeting. It is cleared when that meeting is handed
/// to the write-up, and at no other time.
///
/// Not clearing it puts one meeting's private words into a second meeting's
/// folder, sends them to the model a second time, and writes the second meeting
/// under a title that is not its own. Clearing it before the words are on disk
/// loses words that exist nowhere else yet, such as what a person types before
/// pressing Record. While a meeting records, the draft is kept in that
/// meeting's recording session on disk, so by the time Stop hands it to the
/// write-up the words are safe there, a write-up that fails keeps them with
/// the recording it failed on, and the next meeting can start at once.
public struct MeetingDraft: Sendable, Equatable {

    public var title: String
    public var bullets: String

    public init(title: String = "", bullets: String = "") {
        self.title = title
        self.bullets = bullets
    }

    public var isEmpty: Bool {
        title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && bullets.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The title to write the meeting under: what the owner typed, or the
    /// fallback when the field is empty or holds only spaces.
    public func meetingTitle(or fallback: String) -> String {
        title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? fallback : title
    }

    /// What is left after a meeting is handed to the write-up: nothing. Both
    /// fields are in that meeting's recording session now, and end up in its
    /// folder, the title in `meta.json` and the bullets in `bullets.md`.
    public mutating func clearAfterWriteUp() {
        self = MeetingDraft()
    }
}
