import Foundation

/// Which Parakeet checkpoint the local speech engine loads.
public enum ASRModelChoice: String, Codable, Sendable, CaseIterable {
    /// Multilingual, 25 European languages plus Japanese.
    case v3
    /// English only, higher recall on English meetings.
    case v2

    public var displayName: String {
        switch self {
        case .v3: return "Parakeet TDT 0.6b v3 (multilingual)"
        case .v2: return "Parakeet TDT 0.6b v2 (English only)"
        }
    }
}

/// Everything the owner can change. Secrets are not in here: the gateway API
/// key lives in the login keychain and is read through `APIKeyStore`.
public struct AppSettings: Codable, Equatable, Sendable {

    /// OpenAI-compatible base URL used for notes generation.
    ///
    /// The default is the LiteLLM gateway on the local machine. Point it at
    /// another host by editing the setting, not by editing the source.
    public var notesBaseURL: String

    /// Model name asked for at that endpoint. Profile aliases are stable across
    /// backend changes, so the app asks for a profile rather than a checkpoint.
    public var notesModel: String

    /// Folder that holds one directory per meeting.
    public var notesFolderPath: String

    /// Audio is deleted after a successful transcription unless this is on.
    public var keepAudioAfterTranscription: Bool

    /// Speech checkpoint used by the local engine.
    public var asrModel: ASRModelChoice

    public static let defaultNotesBaseURL = "http://127.0.0.1:4000/v1"
    public static let defaultNotesModel = "profile/general"

    public static var defaultNotesFolderPath: String {
        let documents =
            FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Documents")
        return documents.appendingPathComponent("minutes", isDirectory: true).path
    }

    public init(
        notesBaseURL: String = AppSettings.defaultNotesBaseURL,
        notesModel: String = AppSettings.defaultNotesModel,
        notesFolderPath: String = AppSettings.defaultNotesFolderPath,
        keepAudioAfterTranscription: Bool = false,
        asrModel: ASRModelChoice = .v3
    ) {
        self.notesBaseURL = notesBaseURL
        self.notesModel = notesModel
        self.notesFolderPath = notesFolderPath
        self.keepAudioAfterTranscription = keepAudioAfterTranscription
        self.asrModel = asrModel
    }

    public var notesFolderURL: URL {
        URL(fileURLWithPath: (notesFolderPath as NSString).expandingTildeInPath, isDirectory: true)
    }

    /// Environment overrides, so a one-off run can point at another endpoint
    /// or folder without changing what the app stores.
    public func applyingEnvironmentOverrides(
        _ environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> AppSettings {
        var copy = self
        if let value = environment["MINUTES_BASE_URL"], !value.isEmpty { copy.notesBaseURL = value }
        if let value = environment["MINUTES_MODEL"], !value.isEmpty { copy.notesModel = value }
        if let value = environment["MINUTES_FOLDER"], !value.isEmpty { copy.notesFolderPath = value }
        if let value = environment["MINUTES_KEEP_AUDIO"] {
            copy.keepAudioAfterTranscription = ["1", "true", "yes"].contains(value.lowercased())
        }
        return copy
    }

    /// True when the trimmed value is a strict http/https URL with a host
    /// and no embedded credentials.
    private static func isValidEndpointURL(_ raw: String) -> Bool {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard
            let url = URL(string: trimmed),
            let scheme = url.scheme?.lowercased(),
            scheme == "http" || scheme == "https",
            let host = url.host, !host.isEmpty,
            url.user == nil, url.password == nil
        else { return false }
        return true
    }

    /// Reasons the settings cannot be used, in plain language. Empty means usable.
    public var problems: [String] {
        var found: [String] = []
        if !AppSettings.isValidEndpointURL(notesBaseURL) {
            found.append("The notes endpoint is not an http or https URL with a host.")
        }
        if notesModel.trimmingCharacters(in: .whitespaces).isEmpty {
            found.append("No model name is set for notes.")
        }
        if notesFolderPath.trimmingCharacters(in: .whitespaces).isEmpty {
            found.append("No notes folder is set.")
        }
        return found
    }

    /// Overrides baked into a prepared app bundle. The public source tree
    /// never contains a private address: the prepared build ships its own
    /// `MinutesDefaults.plist` in resources with `notesBaseURL` and
    /// `notesModel`. Values are used only when they validate, and saved
    /// preferences always win over these.
    public static func bundledDefaults(bundle: Bundle = .main) -> AppSettings {
        guard
            let url = bundle.url(forResource: "MinutesDefaults", withExtension: "plist"),
            let data = try? Data(contentsOf: url),
            let plist = try? PropertyListDecoder().decode(BundledDefaults.self, from: data)
        else { return AppSettings() }
        let baseURL = plist.notesBaseURL?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let model = plist.notesModel?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard isValidEndpointURL(baseURL), model.hasPrefix("profile/"), model.count > "profile/".count
        else { return AppSettings() }
        let settings = AppSettings(notesBaseURL: baseURL, notesModel: model)
        guard settings.problems.isEmpty else { return AppSettings() }
        return settings
    }

    private struct BundledDefaults: Decodable {
        var notesBaseURL: String?
        var notesModel: String?
    }
}
