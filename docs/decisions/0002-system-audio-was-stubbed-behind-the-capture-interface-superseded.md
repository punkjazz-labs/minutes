# 0002: system audio was stubbed in v0.1, behind the capture interface

Date: 2026-08-04
Status: superseded on 2026-08-12. The stub was replaced in v0.2 by a real Core
Audio process tap in `SystemAudioCapture`, built to the constraints listed
below. The reasoning here is kept because it is why the tap is a tap and not
ScreenCaptureKit or a virtual device. What the tap does when it goes quiet is
`0004-a-quiet-tap-is-rebuilt-three-times-and-then-reported.md`.

## Context

Half the value of meeting notes is what the other people said. On macOS that
means capturing system audio, and spec 17 is specific about how: Core Audio
process taps, not ScreenCaptureKit.

The reasons, from the spec, are worth keeping here because they decide the
v0.2 implementation:

- ScreenCaptureKit is a video API with audio attached. An audio-only capture
  drops frames unless a dummy video output is attached, it needs Screen
  Recording permission with the recording indicator and Sequoia's periodic
  re-authorisation, and microphone capture through it needs macOS 15.
- Taps are audio only, work per process, can exclude the app's own audio, and
  use a separate TCC category.
- BlackHole and other virtual devices are not needed, and BlackHole is GPL-3.0
  anyway. A tap observes output without rerouting it, so the owner keeps
  hearing the meeting.

## Decision

v0.1 ships `SystemAudioCapture` as a stub that conforms to the same
`AudioCapturing` protocol as the microphone. It reports `isAvailable == false`
with a plain reason, and `start` throws rather than writing a silent file.

Writing silence would be worse than refusing. A silent `system.wav` next to a
real `mic.wav` looks like a recording that captured nothing, and the owner
would not know which of the two happened.

The app says on screen, and the transcript says in its own header, that only
one side of the meeting was recorded.

## What the v0.2 implementation has to satisfy

All of these are from the spec and none of them are optional:

- The aggregate device needs a real output device as its main sub-device with
  the tap as a sub-tap and `kAudioAggregateDeviceTapAutoStartKey` true.
  Tap-as-main with no sub-devices produces silence with no error.
- `AVAudioEngine` cannot retarget arbitrary HAL devices. Use
  `AudioDeviceCreateIOProcIDWithBlock`.
- The app must be a signed `.app` bundle or the permission prompt never
  appears.
- `NSAudioCaptureUsageDescription` has to be typed into the plist by hand, and
  there is no public API to query or request the permission, so the app cannot
  show its own permission state reliably and must handle "granted nothing,
  recorded silence".
- Taps show no menu bar indicator of their own. The app owns the honesty here.
- Taps have been reported delivering all-zero PCM after several minutes,
  recoverable only by tearing the tap down and rebuilding it.

## What v0.1 already does about the last two

The recording state is a red dot in the menu bar and a level meter in the
panel, and `SignalCheck` measures peak, RMS and runs of exact zeros while
recording. All-zero and stalled captures are reported on screen and in the
activity log, and a track that produced no signal is never sent to the speech
engine and is named in the transcript instead. That machinery is written
against the capture interface, so it applies to the tap the day the tap
arrives.

Reference implementation to read when writing it: `insidegui/AudioCap`, which
is BSD-2. Not `makeusabrew/audiotee`, which has no licence file at all.

## What v0.2 actually did

`SystemAudioCapture` builds a stereo global tap that excludes this app's own
process, wraps it in a private aggregate device whose main sub-device is the
real output device, sets `kAudioAggregateDeviceTapAutoStartKey`, reads it with
`AudioDeviceCreateIOProcIDWithBlock`, and converts whatever arrives to 16 kHz
mono through the same `TrackWriter` the microphone uses. The tap layer is
behind a `SystemAudioSource` protocol so the checks drive the capture object,
the rebuild counting and the two-track write-up with a fake and never need the
permission or a sound card.

`NSAudioCaptureUsageDescription` is in the bundle plist. The permission still
cannot be queried, so the app measures the track and says what it heard.
