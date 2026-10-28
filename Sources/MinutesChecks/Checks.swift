import Foundation
import MinutesCore

@main
struct Checks {
    static func main() async {
        let run = CheckRun()
        print("minutes \(MinutesBuild.version) checks")

        do {
            packagingChecks(run)
            try audioChecks(run)
            try systemAudioChecks(run)
            transcriptChecks(run)
            try storageChecks(run)
            await notesChecks(run)
            try await pipelineChecks(run)
            try await libraryChecks(run)
            await askChecks(run)
            try captureLivenessChecks(run)
            try await recoveryChecks(run)
            try await writeUpFixChecks(run)
            try libraryFixChecks(run)
            libraryLayoutChecks(run)
        } catch {
            run.failed("a check threw: \(error.localizedDescription)")
        }

        Scratch.cleanUp()
        run.report()
        exit(run.exitCode)
    }
}
