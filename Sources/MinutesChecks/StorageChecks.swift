import Foundation
import MinutesCore

func storageChecks(_ run: CheckRun) throws {
    run.section("Storage, settings and the privacy claim")

    var components = DateComponents()
    components.year = 2_026
    components.month = 8
    components.day = 4
    components.hour = 14
    components.minute = 0
    let date = Calendar.current.date(from: components)!

    run.equal(
        MeetingSlug.directoryName(title: "Pricing call", date: date), "2026-08-04-1400-pricing-call",
        "the directory name carries the date and a slug")
    run.equal(MeetingSlug.slug("  Q3 review: pricing & packaging  "), "q3-review-pricing-packaging", "slugs are readable")
    run.equal(MeetingSlug.slug("!!!"), "meeting", "a title with no letters still gets a name")

    let root = try Scratch.directory("store")
    let store = MeetingStore(root: root)
    let directory = try store.createMeeting(title: "Pricing call")

    run.expect(FileManager.default.fileExists(atPath: directory.audioDirectory.path), "the audio folder is created")
    run.equal(directory.transcriptURL.lastPathComponent, "transcript.md", "the transcript file is named as the spec says")
    run.equal(directory.notesURL.lastPathComponent, "notes.md", "the notes file is named as the spec says")
    run.equal(directory.metaURL.lastPathComponent, "meta.json", "the meta file is named as the spec says")
    run.equal(directory.audioURL(for: .me).lastPathComponent, "mic.wav", "your track is mic.wav")
    run.equal(directory.audioURL(for: .others).lastPathComponent, "system.wav", "the other track is system.wav")

    let sameMinute = try store.createMeeting(title: "Pricing call", date: date)
    let sameMinuteAgain = try store.createMeeting(title: "Pricing call", date: date)
    run.expect(sameMinute.url != sameMinuteAgain.url, "two meetings in the same minute do not collide")

    // Audio deletion is asserted on disk, both ways.
    let audio = directory.audioURL(for: .me)
    try Data([0, 1, 2]).write(to: audio)
    try store.deleteAudio(in: directory)
    run.expect(!FileManager.default.fileExists(atPath: audio.path), "audio is deleted when asked")
    try Data([0, 1, 2]).write(to: audio)
    run.expect(FileManager.default.fileExists(atPath: audio.path), "nothing deletes audio unless it is asked to")

    let typed = "- pricing concerns\n- renewal date"
    try store.writeNotes(
        title: "Pricing call",
        date: Date(timeIntervalSince1970: 0),
        duration: 1_800,
        ownerNotes: typed,
        body: "## Pricing\n\nThey asked about the renewal.",
        pendingReason: nil,
        transcriptionEngine: "FluidAudio Parakeet TDT",
        transcriptionModel: "parakeet-tdt-0.6b-v3-coreml",
        notesEndpoint: "http://127.0.0.1:4000/v1",
        notesModel: "profile/general",
        to: directory)
    let notes = try String(contentsOf: directory.notesURL, encoding: .utf8)
    run.expect(notes.hasPrefix("---\n"), "notes.md opens with front matter")
    run.expect(notes.contains("transcription_model: \"parakeet-tdt-0.6b-v3-coreml\""), "front matter names the speech model")
    run.expect(notes.contains("notes_model: \"profile/general\""), "front matter names the notes model")
    run.expect(notes.contains("notes_state: written"), "front matter records that notes were written")
    run.expect(notes.contains(typed), "what the owner typed is kept byte for byte")

    try store.writeNotes(
        title: "Pricing call",
        date: Date(),
        duration: 60,
        ownerNotes: "- one bullet",
        body: nil,
        pendingReason: "The endpoint did not answer.",
        transcriptionEngine: "engine",
        transcriptionModel: "model",
        notesEndpoint: "http://127.0.0.1:4000/v1",
        notesModel: "profile/general",
        to: directory)
    let pending = try String(contentsOf: directory.notesURL, encoding: .utf8)
    run.expect(pending.contains("notes_state: pending"), "a failure is recorded as pending, not as notes")
    run.expect(pending.contains("The endpoint did not answer."), "the pending file says why")
    run.expect(pending.contains("- one bullet"), "a failure never costs what the owner typed")

    let meta = MeetingMeta(
        title: "Pricing call",
        startedAt: Date(timeIntervalSince1970: 100),
        durationSeconds: 42,
        transcriptionEngine: "FluidAudio Parakeet TDT",
        transcriptionModel: "parakeet-tdt-0.6b-v3-coreml",
        transcriptionRealtimeFactor: 120,
        notesEndpoint: "http://127.0.0.1:4000/v1",
        notesModel: "profile/general",
        notesState: "written",
        tracksRecorded: ["me"],
        tracksMissing: ["others"],
        audioKept: false)
    try store.writeMeta(meta, to: directory)
    let readBack = try store.readMeta(in: directory)
    run.equal(readBack.transcriptionModel, "parakeet-tdt-0.6b-v3-coreml", "meta.json records the speech model used")
    run.equal(readBack.notesModel ?? "", "profile/general", "meta.json records the notes model used")
    run.equal(readBack.tracksMissing, ["others"], "meta.json records which track was missing")
    run.equal(readBack.audioKept, false, "meta.json records what happened to the audio")

    // Sync folders
    run.equal(
        SyncFolderDetector.service(for: URL(fileURLWithPath: "/Users/a/Dropbox/minutes")) ?? "", "Dropbox",
        "a Dropbox path is detected")
    run.equal(
        SyncFolderDetector.service(for: URL(fileURLWithPath: "/Users/a/Library/CloudStorage/Dropbox-Personal/minutes")) ?? "",
        "Dropbox", "a Dropbox file provider mount is detected")
    run.equal(
        SyncFolderDetector.service(
            for: URL(fileURLWithPath: "/Users/a/Library/Mobile Documents/com~apple~CloudDocs/minutes")) ?? "",
        "iCloud Drive", "an iCloud Drive path is detected")
    run.equal(
        SyncFolderDetector.service(for: URL(fileURLWithPath: "/Users/a/Library/CloudStorage/OneDrive-Work/x")) ?? "",
        "OneDrive", "a OneDrive mount is detected")
    run.expect(
        SyncFolderDetector.service(for: URL(fileURLWithPath: "/Users/a/Documents/minutes")) == nil,
        "a plain Documents folder is not called a sync folder")
    run.equal(
        SyncFolderDetector.warning(for: URL(fileURLWithPath: "/Users/a/Dropbox/minutes")) ?? "",
        "This folder syncs to Dropbox. Your notes will be copied there.",
        "the sync warning names the service")

    let claim = PrivacyClaim.text(endpoint: "http://127.0.0.1:4000/v1", syncService: nil)
    run.expect(claim.contains("http://127.0.0.1:4000/v1"), "the privacy claim names the endpoint in force")
    run.expect(!claim.lowercased().contains("nothing leaves"), "the claim never says nothing leaves the Mac")
    run.expect(
        PrivacyClaim.text(endpoint: "http://127.0.0.1:4000/v1", syncService: "Dropbox").contains("Dropbox"),
        "the claim names the sync service when there is one")

    // Settings
    let settings = AppSettings()
    run.equal(settings.notesBaseURL, "http://127.0.0.1:4000/v1", "the default endpoint is the local gateway")
    run.equal(settings.notesModel, "profile/general", "the default model is a profile alias")
    run.equal(settings.keepAudioAfterTranscription, false, "audio is deleted by default")
    run.expect(settings.problems.isEmpty, "the default settings are usable")

    let overridden = settings.applyingEnvironmentOverrides(["MINUTES_BASE_URL": "http://elsewhere:4000/v1"])
    run.equal(overridden.notesBaseURL, "http://elsewhere:4000/v1", "an environment override changes the endpoint")
    run.equal(overridden.notesModel, "profile/general", "an override leaves the other settings alone")

    let defaults = UserDefaults(suiteName: "minutes.checks.\(UUID().uuidString)")!
    let settingsStore = UserDefaultsSettingsStore(defaults: defaults)
    var edited = settingsStore.load()
    edited.notesModel = "profile/reasoning"
    edited.keepAudioAfterTranscription = true
    settingsStore.save(edited)
    let reloaded = UserDefaultsSettingsStore(defaults: defaults).load()
    run.equal(reloaded.notesModel, "profile/reasoning", "settings survive a round trip")
    run.equal(reloaded.keepAudioAfterTranscription, true, "the keep-audio setting survives a round trip")
}
