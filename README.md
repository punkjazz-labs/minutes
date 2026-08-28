# minutes

A local meeting notes app for macOS. The recording and the transcript are made
on your Mac. The transcript is sent to a model endpoint you choose to write the
notes. Nothing is sent to any other service.

This is v0.3. It records both sides of the meeting, it ships as a signed and
notarised disk image, and this file says plainly which parts work, which are
stubs, and which have been measured on real hardware rather than assumed.

## What works in v0.3

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
  database and no sync. What you typed is written to its own `bullets.md` and
  is only ever read again. Audio is deleted once the transcript exists unless
  you ask to keep it.
- **A meeting library.** Meetings in the menu bar popover opens a window
  listing every meeting in the notes folder
  with its date, length and notes state, read from the files rather than from
  an index. Rename edits the row and renames the directory. Files reveals it in
  Finder. Delete asks first and then removes the whole directory, audio
  included. The header names the notes folder and the service it syncs to.
- **Search across meetings.** Titles, notes and transcripts, with the words
  around the match shown under the title of each meeting that matched.
- **Traceable notes.** The timestamps the model already writes become chips.
  Clicking one scrolls the transcript to that line and marks it. A line whose
  timestamp is not in the transcript is not given a link that lands on the
  wrong words: it is moved to a box that says it is not in the transcript,
  along with anything the model itself filed as unanchored.
- **Write notes again.** Notes generation runs again for a meeting already on
  disk, from the same two inputs. `bullets.md` is read and never written, and
  `notes.md` is replaced only once the endpoint has answered, so a failed
  re-run costs nothing. A meeting whose notes failed shows as waiting for the
  Spark until a re-run succeeds.
- **A question box under the transcript.** The question and the transcript go
  to the same endpoint the notes use, under its own operation name. The answer
  carries the same timestamp chips and jumps the same way. The questions and
  answers are held in memory while the app runs and are written nowhere.
- **A folder that syncs is named.** If the notes folder is inside Dropbox,
  iCloud Drive, OneDrive, Google Drive or Box, the app says which service it
  copies to, and the privacy claim on screen names it too.
- **A command line face**, `minutes-cli`, so the model download, a
  transcription, the endpoint probe and the whole meeting path can be run
  without a window or a permission prompt.
- **A disk image assessed the way a download is assessed.** `make dmg` produces
  `build/Minutes.dmg`. The app is signed with a Developer ID identity under the
  hardened runtime, and Apple has notarised it. The image holds the app and a
  link to /Applications, and the image is signed and notarised too. Both the
  app and the image carry the ticket on disk, which is what lets a Mac with no
  network open them. A copy of the image was marked with the quarantine flag a
  browser adds, and Gatekeeper accepted it, and accepted the app inside it. The
  entitlements file grants one thing, audio input, because the microphone needs
  it under the hardened runtime and the system audio tap needs no key at all.
  No second Mac has installed it, and the two permission prompts still need a
  person to answer them. The measured section below says what was verified, and
  by which command.
- **Checks**, `minutes-checks`, 261 assertions covering the hardware seams
  with fakes behind all of them. The tap is behind a `SystemAudioSource`
  protocol, so rebuild counting, the two-track write-up and the silence
  reporting run without a permission grant or a sound card; anchor parsing,
  search, rename, re-run and the question box run against a stub endpoint.
  One of them reads `packaging/macos/Info.plist` and fails when the version in
  the bundle and the version in the source stop agreeing, because those two
  numbers are moved by hand. None of them needs a microphone, a permission or
  the network.

## What is stubbed or missing in v0.3

- **No speaker diarization.** Speaker labels come from which device the audio
  arrived on, not from voice recognition, and the transcript says so. Everyone
  on the far end of the call is one speaker called `Others`, because they
  arrive on one track.
- **The notes are not streamed.** One request, one answer, for the notes and
  for a question alike. Streaming is a change behind the `NotesGenerating` and
  `Asking` protocols.
- **An anchor is an exact timestamp match and nothing cleverer.** A chip
  appears when the transcript has a line at exactly the timecode the model
  wrote. A model that is a second out produces a line in the box that says it
  is not in the transcript, rather than a link to the wrong words.
- **Long meetings are sent whole.** No chunking with overlap and no summary of
  summaries yet, so a meeting long enough to exceed the endpoint's context
  window fails as a server error rather than being split.
- **The notes pane is not a Markdown renderer.** Headings, bullets and plain
  lines are shown; tables, links and nested lists are shown as the plain text
  they are written in.
- **Questions and answers are not kept.** They live in memory while the app
  runs and are gone when it quits. Nothing about them is written to the
  meeting folder.
- **No calendar integration and no automatic meeting detection.**
- **Apple Silicon only.** The binary is `arm64` and the build is not universal,
  so the disk image does not open on an Intel Mac. `make dmg` builds for the
  kind of Mac it runs on.
- **No automatic updates.** The app does not look for a newer version and
  carries no updater. A new version is a new download.
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
- **The disk image is accepted the way a download is accepted.** On 2026-08-28
  the whole release path ran on this Mac. Apple accepted both submissions: the
  app as `8aac89a5-f385-4f84-84fa-296d4a9d4eaf`, the image as
  `d91434ca-96f4-4efc-ae6f-d0651f25f6ac`. A copy of the image was then marked
  with the quarantine flag a browser adds, and asked the question a download
  asks. `spctl --assess --type open --context context:primary-signature`
  answered `accepted, source=Notarized Developer ID`. The image was mounted and
  the app inside it answered the same to `spctl --assess --type exec`.
  `codesign --verify --strict --deep` passed on the app and on the image, and
  `stapler validate` passed on both, which means each ticket is on the disk and
  is not fetched from Apple at open time. The image is 3,062,367 bytes. Its
  sha256 is
  `5bc88567c390bf222ed2ffc7b83545014a0d59510c19a2b63736259bdac75068`.
- **The hardened runtime costs the speech engine nothing.** The command line
  face was signed with the same identity, the same hardened runtime and the
  same single entitlement, and it then transcribed a real file with the model
  on the Neural Engine, 6.25 seconds of audio in 0.34 seconds. So Core ML needs
  no entitlement of its own here and the list stays at one key.

Not measured, and not claimed:

- Whether a tap on this macOS version delivers all-zero PCM after several
  minutes. The rebuild path exists and is checked against a fake, and it has
  never fired against a real tap.
- Word error rate against a hand-corrected transcript of a real hour-long
  meeting. The product spec asks for this and it needs real meeting audio.
- Realtime factor and peak memory on an hour of audio.
- Anything at all about a fallback engine. Only FluidAudio was run.
- Whether the microphone and the system audio tap work under the Developer ID
  identity. No capture code changed. But macOS records both permissions against
  the signing identity, and the identity changed, so both are new permissions
  as far as macOS is concerned. It asks for them in a prompt a person clicks,
  and no automated check can click it. The v0.2 run that proved system audio
  was made under the ad-hoc signature.
- Whether the image installs on a second Mac. It was built and assessed on the
  machine that built it. Gatekeeper was asked the question a download asks, and
  it accepted, but no other Mac has opened the image.

## Build and run

Xcode is not needed. Everything works with the Command Line Tools.

```
make build          # swift build
make checks         # run the verification suite, exits non-zero on failure
make fetch-models   # download the Parakeet model, a few hundred megabytes, once
make app            # assemble and ad-hoc sign build/Minutes.app
make run            # assemble and open the app
make dmg            # the signed, notarised disk image, needs the network
```

The app must be run from the bundle. macOS grants microphone access on the
signing identity of a bundle, and a bare executable in `.build/debug` never
even raises the prompt.

### The disk image

`make dmg` writes `build/Minutes.dmg`. It runs the checks first, builds and
signs the app, notarises it, staples the answer to it, puts it in the image
beside a link to /Applications, signs the image, notarises the image, staples
that too, and then proves the result with `codesign`, `spctl` and `stapler`.
Apple has to answer twice, so it takes a few minutes and it needs the network.

It also needs a Developer ID identity and a notarytool keychain profile. The
Makefile names the two this project uses, and the environment replaces either:

```
SIGN_IDENTITY="Developer ID Application: Name (TEAMID)" NOTARY_PROFILE=other make dmg
```

No secret is in this repository. Both are names, and macOS holds what sits
behind each name. `scripts/build-app.sh` still makes the ad-hoc bundle when
`SIGN_IDENTITY` is not set, so `make app` behaves as it always did.

To install, open the image and drag minutes to Applications.

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

macOS records both permissions against the signing identity and not against the
file. The v0.2 builds were signed ad-hoc, and the v0.3 disk image is signed
with a Developer ID identity, so macOS treats the installed app as an app it
has never seen and asks for both permissions again. This is the one step no
command can do, on this Mac or on any other. Answer the two prompts once, and
the answer holds for every later build that carries the same identity.

### Proving system audio works, by hand

This is the part no automated check and no bare binary can do, because macOS
grants the permission to a signed bundle and only in answer to a prompt a
person clicks. It has to be done once for each signing identity, so the
Developer ID build needs a run of its own. Ten minutes, once:

1. Open `build/Minutes.dmg`, drag minutes to Applications, and open it from
   there. For the ad-hoc build instead, run `make app` and then `open
   build/Minutes.app`.
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
  bullets.md      what you typed, word for word, written once and only read after
  transcript.md   timestamped, with the track each line came from
  audio/          mic.wav and system.wav, deleted after transcription unless you keep them
  meta.json       durations, engine, model, what ran where, what happened to the audio
```

Renaming a meeting renames the directory and the title in `meta.json`. It does
not rewrite `notes.md` or `transcript.md`, because a rename must never be able
to lose what was said.

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
Sources/MinutesCore         settings, capture, speech, notes, storage, pipeline
Sources/Minutes             the menu bar app
Sources/MinutesCLI          the command line face
Sources/MinutesChecks       the verification suite
packaging/macos             Info.plist and entitlements for the app bundle
scripts/build-app.sh        assembles and signs Minutes.app, ad-hoc or Developer ID
scripts/package-release.sh  the signed, notarised, stapled disk image
docs/decisions              the choices the product spec left open
```

## Why the checks are an executable and not XCTest

XCTest ships with Xcode. On a Command Line Tools installation `swift test`
fails with "no such module XCTest", so an XCTest suite here would be one that
nobody on this machine could run. `minutes-checks` is an ordinary executable
with a small assertion harness that exits non-zero on failure. It uses only the
public API of `MinutesCore`, so moving it to a test target later is mechanical.
