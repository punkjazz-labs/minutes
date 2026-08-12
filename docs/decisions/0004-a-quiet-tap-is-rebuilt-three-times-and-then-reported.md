# 0004: a quiet tap is rebuilt three times and then reported, not diagnosed

Date: 2026-08-12
Status: accepted for v0.2

## Context

Two facts about Core Audio process taps decide this, and they pull in opposite
directions.

The first is a live bug. Taps have been reported delivering nothing but digital
zero after several minutes, recoverable only by tearing the tap down and
building it again (https://developer.apple.com/forums/thread/825780). An app
that ignores this can record an hour of nothing.

The second is that a run of zeros is not evidence of that bug. A tap on the
output of a Mac where nothing is playing delivers exactly the same thing: exact
digital zero, indefinitely, correctly. This is unlike the microphone, where a
real room always has a noise floor and a run of exact zeros is already
suspicious. On the system audio track, silence is the normal state of a meeting
where nobody is talking.

There is also no way to tell either case apart from a third: macOS granting
nothing. The audio capture permission cannot be queried or requested through
any public API, and a denied tap produces zeros, not an error.

So the app is looking at one symptom with three causes, and it cannot ask
anybody which it is.

## Decision

An unbroken run of thirty seconds of digital zero on the system audio track
tears the tap down and builds a new one. At most three rebuilds per meeting.
The watchdog looks every five seconds.

Every rebuild is counted and written into the activity log, in a sentence that
says it is a retry and not a diagnosis. After the third, the app says that it
has stopped trying. If the track was still all zero when the meeting ended, it
is reported as silent in exactly the way v0.1 reports a dead microphone: named
on screen, named in the activity log, named in the transcript, never sent to
the speech engine, and the file is discarded rather than saved as a silent
`system.wav` sitting next to a real `mic.wav`.

The recording keeps going through a rebuild. The tap is rebuilt underneath the
same open file, so a meeting has one system track with a small gap in it, not
several files to reassemble.

## Why thirty seconds and three

Thirty seconds is long enough that a normal conversational pause never triggers
it, and short enough that a genuinely stalled tap costs half a minute of the
meeting rather than the rest of it. Three is enough to get past a transient and
few enough that a Mac which is simply quiet does not have its audio graph torn
down every half minute for an hour.

Neither number is measured. They are chosen against the failure mode described
in the forum thread, on a build where that failure has not been observed. They
are two constants in `TapRebuildPolicy`, the policy is a plain value with no
clock and no devices in it, and the checks drive it to the exact frame. When
real meetings produce evidence, the evidence changes the numbers and this
decision records what changed.

## The output device changing mid-meeting

The aggregate device is built around whichever device the Mac is playing
through. Connecting AirPods halfway through a meeting changes that device, and
the aggregate built around the old one stops being the right shape.

The app listens for the default output device notification and rebuilds the
aggregate around the new device. That rebuild is counted separately from the
silence rebuild and is not charged against the three, because it is a normal
event and not a suspected fault. If macOS refuses the listener, the app says so
on screen rather than pretending it is watching.

## What this deliberately does not do

It does not claim the tap is broken. It does not claim the permission was
denied. It does not claim the meeting was quiet. It says how many samples were
zero, how many times it rebuilt, and what it heard, and leaves the owner to
know which of the three it was.
