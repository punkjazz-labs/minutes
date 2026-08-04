import Foundation

/// The two labelled inputs the model gets, and the rules it is held to.
///
/// The loop this copies is the one that makes the category useful: the owner's
/// sparse bullets are the prompt, and the transcript is the evidence. The
/// instruction against inventing agreements is deliberate and blunt, because a
/// model inventing a follow-up nobody agreed to is the failure that destroys
/// trust in meeting notes.
public enum NotesPrompt {

    public static let system = """
        You write meeting notes from a transcript that was recorded on the user's own \
        computer. You are given two labelled inputs: the notes the user typed during \
        the meeting, and the transcript of what was actually said.

        Rules:
        1. The user's notes set the agenda. Expand every point they typed, using the \
        transcript as the evidence for it.
        2. Write only what the transcript supports. Do not invent decisions, owners, \
        dates, numbers or follow-up actions. If something was discussed without being \
        agreed, say it was discussed and not agreed.
        3. Anchor claims. When a point rests on something specific that was said, quote \
        a short fragment and give its timestamp in the form [00:12:34].
        4. Put anything you cannot anchor to the transcript under a final heading called \
        "Not anchored to the transcript", or leave it out.
        5. Keep the user's own wording where it is already clear.
        6. Plain Markdown. No emoji. No preamble and no sign-off, start with the notes.
        """

    public static func user(title: String, ownerNotes: String, transcript: String) -> String {
        let bullets = ownerNotes.trimmingCharacters(in: .whitespacesAndNewlines)
        let typed = bullets.isEmpty
            ? "(The user typed nothing during this meeting. Summarise what was said, and do not invent structure that the transcript does not support.)"
            : bullets

        return """
            Meeting title: \(title)

            ## Input 1: notes the user typed during the meeting

            \(typed)

            ## Input 2: transcript

            \(transcript)
            """
    }
}
