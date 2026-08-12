# 0005: a note anchor is an exact timestamp, and what the owner typed has its own file

Date: 2026-08-12
Status: accepted for the library and the meeting window

## Context

Spec 17 asks for two things that the interface has to make real. Every model
line should link back to the transcript lines it came from, and enhance should
be repeatable without ever destroying what the owner typed.

The prompt already asks the model for timestamps in the form `[00:12:34]`, and
the model gives them. Nothing until now turned them into anything.

## An anchor is an exact match, or it is not an anchor

A chip appears on a note line when the transcript has a line at exactly the
timecode the model wrote. There is no nearest-line search and no tolerance
window.

The alternative, snapping a timestamp to the closest line within a few seconds,
looks better in a demo and is worse in use. The whole value of the control is
that clicking it proves the claim. A link that lands near the words, or on the
wrong speaker's turn, is a claim of evidence where there is none, and it fails
in exactly the case where the model was least reliable.

So a line whose timestamps resolve to nothing is not shown with a dead chip and
is not silently dropped either. It is moved to a box headed "Not in the
transcript", alongside anything the model itself filed under the unanchored
heading the prompt asks for. The owner sees the claim and sees that the
transcript does not back it.

The cost is honest and worth naming: a model that writes a timestamp one second
out produces a line in that box rather than a link. That is the safe direction
to be wrong in.

## What the owner typed lives in bullets.md

`notes.md` is rewritten every time notes are generated. The owner's own words
were a section inside it, which made them a hostage of that rewrite.

They are now written once to `bullets.md` when the meeting is written up, and
that file is only ever read afterwards. Writing the notes again reads it, sends
it as the first labelled input, and replaces `notes.md` alone. The checks
assert the file is byte identical across a re-run.

`notes.md` still carries the same text in its own section, because the folder
has to be readable without this app. The file that must not change and the file
that is regenerated are now two different files.

## A failed re-run changes nothing

Notes are written again only once the endpoint has answered. A refused
connection leaves `notes.md` exactly as it was, so a meeting whose notes are
good cannot be turned into a meeting whose notes are waiting by a machine being
off, and a meeting whose notes are waiting stays waiting until a re-run works.

## Questions about a meeting are not part of the meeting

The question box under the transcript sends the question and the transcript to
the same endpoint, under the operation name `meeting-ask` so the gateway can
tell the two kinds of request apart. The answers are held in memory while the
app runs and are written nowhere.

A meeting folder is the record of the meeting. What someone asked about it
afterwards is not, and writing it there would quietly change what the folder
is.
