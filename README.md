# minutes

A local meeting notes app for macOS. The recording and the transcript are made
on your Mac. The transcript is sent to a model endpoint you choose to write the
notes. Nothing is sent to any other service.

This is v0.2. It records both sides of the meeting, and this file says plainly
which parts work, which are stubs, and which have been measured on real
hardware rather than assumed.

## What works in v0.2

- **A menu bar app.** SwiftUI `MenuBarExtra`, no dock icon. The menu bar item
  turns into a record dot while recording, because a Core Audio tap shows no
  indicator of its own and the app owns that honesty.
- **Microphone capture.** Real. It opens the default input device, converts
  whatever format the device gives to 16 kHz mono, and writes a WAV while the
  meeting runs. Verified on this Mac by recording three seconds and reading the
  file back: `RIFF WAVE, Microsoft PCM, 16 bit, mono 16000 Hz`.
- **System audio capture, meaning the other side of the meeting.** A Core Audio
  process tap on everything this Mac plays, minus this app, inside a private
  aggregate device whose main sub-device is the real output device, with
  `kAudioAggregateDeviceTapAutoStartKey` set and read through
  `AudioDeviceCreateIOProcIDWithBlock`. It observes the audio on its way out
  and changes nothing, so you keep hearing the meeting. It is not
  ScreenCaptureKit, it needs no virtual device, and it raises no screen
  recording indicator. Meetings now write two tracks, `mic.wav` and
  `system.wav`, and the transcript labels them `You` and `Others`.
  **Whether the permission was actually granted on this machine has not been
  measured. See what was measured, below.**
- **A tap that goes quiet is rebuilt, counted and reported.** Thirty seconds of
  unbroken digital zero rebuilds the tap, at most three times a meeting, and
  every rebuild is named in the activity log as a retry rather than a
  diagnosis. A quiet meeting and a permission that was never granted look
  identical to any app, so minutes measures the track and says what it heard.
  The reasoning is in
  `docs/decisions/0004-a-quiet-tap-is-rebuilt-three-times-and-then-reported.md`.
- **The output device changing mid-meeting is handled.** Connecting headphones
  changes the device the aggregate is built around, so the app listens for that
  change and rebuilds the tap around the new device, counting and logging it.
- **A track that heard nothing is never written as if it were fine.** A silent
  `system.wav` is discarded rather than saved next to a real `mic.wav`, the
  transcript says the track was recorded and carried nothing, and `meta.json`
  names it under `tracksSilent`. The warning that only one side was recorded
  disappears only when the second track actually carried signal.
- **A signal check that runs while recording.** Peak, RMS and runs of exact
  zeros. A capture that delivers digital silence is reported as such, on
  screen, in the activity log and in the transcript, and is never sent to the
  speech engine. Digital silence and a quiet room are indistinguishable once
  they are on disk, so the app measures instead of assuming.
- **Local transcription with Parakeet.** FluidAudio, Core ML on the Apple
  Neural Engine, `parakeet-tdt-0.6b-v3-coreml`. Offline once the model is
  downloaded. Token timings become timestamped lines.
- **Notes generation.** The transcript and the bullets you typed go to an
  OpenAI-compatible endpoint as two labelled inputs. The prompt forbids
  inventing decisions, owners, dates and follow-up actions, asks for
  timestamped quotes as anchors, and puts anything unanchored under its own
  heading.
- **Storage as plain files.** One directory per meeting, Markdown and JSON, no
  database and no sync. Audio is deleted once the transcript exists unless you
  ask to keep it.
- **A folder that syncs is named.** If the notes folder is inside Dropbox,
  iCloud Drive, OneDrive, Google Drive or Box, the app says which service it
  copies to, and the privacy claim on screen names it too.
- **A command line face**, `minutes-cli`, so the model download, a
  transcription, the endpoint probe and the whole meeting path can be run
  without a window or a permission prompt.
- **Checks**, `minutes-checks`, 180 assertions covering the hardware seams with
  fakes behind all of them. The tap is behind a `SystemAudioSource` protocol,
  so the rebuild counting, the two-track write-up and the silence reporting are
  all checked without a permission grant or a sound card.

## What is stubbed or missing in v0.2

- **No speaker diarization.** Speaker labels come from which device the audio
  arrived on, not from voice recognition, and the transcript says so. Everyone
  on the far end of the call is one speaker called `Others`, because they
  arrive on one track.
- **The notes are not streamed.** One request, one answer. Streaming is a
  change behind the `NotesGenerating` protocol.
- **No traceability control in the interface.** The model is asked for
  timestamps in the notes text, and it gives them, but there is no click that
  jumps from a note line to the transcript line.
- **No re-run of enhance from the interface.** Notes are written once per
  meeting. `minutes-cli notes <transcript>` can be run again by hand.
- **No meeting library.** No list, no search, no rename, no delete. There is a
  button that opens the folder in Finder.
- **No calendar integration and no automatic meeting detection.**
- **The build is signed ad-hoc, not notarised.** It is fit for the machine that
  built it and not for handing to anyone. A Developer ID identity and
  notarisation are not wired up.
- **No Windows and no Linux.** macOS only.

## What was measured, and what was not

Measured on this Mac (Apple M4, 10 cores, 32 GB, macOS 26.5.1), so these are
numbers and not estimates:

- Transcribing 11.1 seconds of synthesised speech took 0.17 seconds once the
  model was loaded, which is 66 times faster than real time. Loading the model
  from cold takes roughly 20 seconds on top of that, once per process.
- The transcript was word accurate on that clip, including "15%" from "fifteen
  percent".
- The full path, transcribe then write the meeting folder then ask for notes,
  ran against a live LiteLLM gateway and produced `notes.md`, `transcript.md`
  and `meta.json`, and deleted the audio.
- **System audio capture records the other side.** On 2026-08-12 the signed
  bundle was run, the permission granted at the prompt, and a 37 second meeting
  recorded while a video played through the speakers. Both tracks were
  recorded, neither was silent, and the transcript carried the video's speech
  on the `Others` track word for word, timestamped, alongside the owner's voice
  on the `You` track. The audio was deleted after transcription, as the default
  says. The failure path ran in the same session: the notes endpoint did not
  answer, the notes were left pending, and the transcript survived.
- From a bare command line binary the same tap delivers a continuous stream of
  digital zeros, because macOS grants the permission to a signed bundle only
  and never says so. The app reported that run as a refusal, which is the
  honest-silence path working.

Not measured, and not claimed:

- Whether a tap on this macOS version delivers all-zero PCM after several
  minutes. The rebuild path exists and is checked against a fake, and it has
  never fired against a real tap.
- Word error rate against a hand-corrected transcript of a real hour-long
  meeting. The product spec asks for this and it needs real meeting audio.
- Realtime factor and peak memory on an hour of audio.
- Anything at all about a fallback engine. Only FluidAudio was run.

## Build and run

Xcode is not needed. Everything works with the Command Line Tools.

```
make build          # swift build
make checks         # run the verification suite, exits non-zero on failure
make fetch-models   # download the Parakeet model, a few hundred megabytes, once
make app            # assemble and ad-hoc sign build/Minutes.app
make run            # assemble and open the app
```

The app must be run from the bundle. macOS grants microphone access on the
signing identity of a bundle, and a bare executable in `.build/debug` never
even raises the prompt.

### The command line tool

```
swift run minutes-cli settings                      # what is in force, and where notes go
swift run minutes-cli probe                         # ask the endpoint for its models
swift run minutes-cli fetch-models                  # download the speech model
swift run minutes-cli record 5                      # record the microphone and report what arrived
swift run minutes-cli record 5 --source system      # the same for the system audio tap
swift run minutes-cli transcribe meeting.wav        # transcribe and print, with timings
swift run minutes-cli notes transcript.md           # notes from an existing transcript
swift run minutes-cli meeting meeting.wav --title T # the whole path
```

Environment overrides, for a one-off run against another endpoint or folder:
`MINUTES_BASE_URL`, `MINUTES_MODEL`, `MINUTES_FOLDER`, `MINUTES_KEEP_AUDIO`,
`MINUTES_API_KEY`.

## Permissions

- **Microphone.** Needed and used. macOS asks the first time you record from
  the app bundle. `NSMicrophoneUsageDescription` is in
  `packaging/macos/Info.plist`.
- **Audio capture, meaning system audio.** Needed and used since v0.2.
  `NSAudioCaptureUsageDescription` is in the plist because it has to be typed
  in by hand. There is no public API to query or request this one, so the app
  cannot show its own permission state and does not pretend to: it measures
  what the track carried and says that instead.
- **Screen recording.** Not needed and not requested. The app does not use
  ScreenCaptureKit.

Because the bundle is signed ad-hoc, its TCC identity changes if it is rebuilt
with a different identity, and macOS will ask again.

### Proving system audio works, by hand

This is the part no automated check and no bare binary can do, because macOS
grants the permission to a signed bundle and only in answer to a prompt a
person clicks. Ten minutes, once:

1. `make app`, then `open build/Minutes.app`.
2. Click the menu bar item and press Record. Answer the macOS prompt asking to
   record what your Mac plays. If no prompt appears, open System Settings,
   Privacy and Security, and look for minutes under the audio recording entry.
3. While it records, play something with sound for ten seconds. `afplay
   /System/Library/Sounds/Glass.aiff` in a terminal is enough, or unmute a
   video.
4. Press Stop and write up. Expect the activity log to say
   `Others: 10.x s recorded, peak level 0.xx.` and expect no line saying
   nothing was heard, no rebuild lines, and no line about only one side being
   recorded.
5. Open the meeting folder. With `keep audio` on, expect both `audio/mic.wav`
   and `audio/system.wav`, and expect `transcript.md` to carry `Others:` lines.

If step 4 says every sample was digital zero, the permission was not granted.
That is the honest failure and the app reports it rather than saving a silent
file. Write what you saw into the measured section above, either way.

## The model download

The speech model is fetched once from Hugging Face, no token needed, to
`~/Library/Application Support/FluidAudio/Models/parakeet-tdt-0.6b-v3`. It is
roughly 470 MB on disk. Run `make fetch-models`, or press the download button
in the app settings. Transcription is offline after that.

## Where the notes go

Default `~/Documents/minutes`, one directory per meeting:

```
2026-08-04-1400-pricing-call/
  notes.md        front matter naming the engine, the model and the endpoint used
  transcript.md   timestamped, with the track each line came from
  audio/          mic.wav and system.wav, deleted after transcription unless you keep them
  meta.json       durations, engine, model, what ran where, what happened to the audio
```

## The endpoint

The default is `http://127.0.0.1:4000/v1` with the model `profile/general`, a
profile alias rather than a checkpoint name, so the app does not depend on
which model is behind it. Both are settings. No other machine address appears
in the source.

The API key lives in the login keychain. When no key is set, the app sends the
string `local-placeholder`, which is not a secret and is documented as a
placeholder because OpenAI-compatible clients require a non-empty field and a
local gateway accepts anything there.

If the endpoint does not answer, the transcript is still written and `notes.md`
records `notes_state: pending` with the reason. A machine being off costs the
notes, never the meeting.

## What this app does not tell you

minutes does not tell the other people in the room that you are recording. The
app says this once, on first run. It is product design, not decoration.

## Layout

```
Sources/MinutesCore     settings, capture, speech, notes, storage, pipeline
Sources/Minutes         the menu bar app
Sources/MinutesCLI      the command line face
Sources/MinutesChecks   the verification suite
packaging/macos         Info.plist for the app bundle
scripts/build-app.sh    assembles and ad-hoc signs Minutes.app
docs/decisions          the choices the product spec left open
```

## Why the checks are an executable and not XCTest

XCTest ships with Xcode. On a Command Line Tools installation `swift test`
fails with "no such module XCTest", so an XCTest suite here would be one that
nobody on this machine could run. `minutes-checks` is an ordinary executable
with a small assertion harness that exits non-zero on failure. It uses only the
public API of `MinutesCore`, so moving it to a test target later is mechanical.
