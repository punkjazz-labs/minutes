import Foundation

/// What stopping a meeting produced.
public struct MeetingStopOutcome: Sendable {
    /// The tracks that closed, in the order they were stopped.
    public let captures: [CaptureResult]
    /// The tracks this meeting will not have.
    public let missingTracks: [AudioTrack]
    /// What could not be stopped, in sentences fit for the activity log.
    public let failures: [String]

    public init(captures: [CaptureResult], missingTracks: [AudioTrack], failures: [String]) {
        self.captures = captures
        self.missingTracks = missingTracks
        self.failures = failures
    }

    /// The owner's own track. A meeting cannot be written up without it.
    public var ownCapture: CaptureResult? { captures.first { $0.track == .me } }
}

/// Stopping every source of a meeting at once.
///
/// A Core Audio process tap raises no indicator of its own, so the record dot
/// in the menu bar is the only thing on the screen that says this Mac is
/// recording what it plays. A stop that gives up at the first error leaves that
/// tap running with the dot already off, the file it writes keeps growing, and
/// the next meeting is handed that file under its own title.
///
/// So both sources are stopped here, one after the other, with no early return
/// and no branch of any kind between the two stops. An error is a thing to
/// report at the end. It is never a reason to leave a source running.
public enum MeetingStop {

    /// Stops the microphone and the system audio tap, whatever either one does.
    ///
    /// - Parameters:
    ///   - microphone: the owner's own track.
    ///   - systemAudio: the other side, or nil when it never started.
    public static func everything(
        microphone: any AudioCapturing,
        systemAudio: (any AudioCapturing)?
    ) -> MeetingStopOutcome {

        // Both results are taken before anything is decided about either one.
        // This is the whole fix: there is no statement between these two lines
        // that an error is able to skip.
        let ownStop = Result { try microphone.stop() }
        let otherStop = systemAudio.map { source in Result { try source.stop() } }

        var captures: [CaptureResult] = []
        var missing: [AudioTrack] = []
        var failures: [String] = []

        switch ownStop {
        case .success(let capture):
            captures.append(capture)
        case .failure(let error):
            missing.append(microphone.track)
            failures.append("Stopping the recording failed: \(error.localizedDescription)")
        }

        switch otherStop {
        case .some(.success(let capture)):
            captures.append(capture)
        case .some(.failure(let error)):
            missing.append(systemAudio?.track ?? .others)
            failures.append("The system audio track could not be closed: \(error.localizedDescription)")
        case .none:
            missing.append(.others)
        }

        return MeetingStopOutcome(captures: captures, missingTracks: missing, failures: failures)
    }
}
