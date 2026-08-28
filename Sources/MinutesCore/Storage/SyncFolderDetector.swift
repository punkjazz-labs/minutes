import Foundation

/// Names the sync service a folder belongs to, so the privacy claim on screen
/// describes the configuration actually in force. A notes folder inside
/// Dropbox is copied to Dropbox, and the app has to say so rather than repeat
/// a claim that stopped being true when the owner picked the folder.
public enum SyncFolderDetector {

    public static func service(for url: URL) -> String? {
        let path = url.standardizedFileURL.path
        let components = path.split(separator: "/").map(String.init)

        // iCloud Drive on disk.
        if components.contains("Mobile Documents") || path.contains("/com~apple~CloudDocs") {
            return "iCloud Drive"
        }

        // File provider mounts: ~/Library/CloudStorage/<Provider>-<account>
        if let index = components.firstIndex(of: "CloudStorage"), index + 1 < components.count {
            let mount = components[index + 1]
            let provider = mount.split(separator: "-").first.map(String.init) ?? mount
            return friendlyName(for: provider)
        }

        for component in components {
            if let name = friendlyName(forExactFolder: component) { return name }
        }
        return nil
    }

    /// The sentence the app shows when the folder syncs.
    public static func warning(for url: URL) -> String? {
        guard let service = service(for: url) else { return nil }
        return "This folder syncs to \(service). Your notes will be copied there."
    }

    private static func friendlyName(for provider: String) -> String {
        switch provider.lowercased() {
        case "dropbox": return "Dropbox"
        case "googledrive": return "Google Drive"
        case "onedrive": return "OneDrive"
        case "box": return "Box"
        case "icloud", "icloud drive": return "iCloud Drive"
        default: return provider
        }
    }

    private static func friendlyName(forExactFolder folder: String) -> String? {
        switch folder.lowercased() {
        case "dropbox": return "Dropbox"
        case "google drive", "googledrive": return "Google Drive"
        case "onedrive": return "OneDrive"
        // Box is found under ~/Library/CloudStorage as well, but it still
        // mounts at ~/Box, and the privacy claim named Box while the code did
        // not look for it there.
        case "box": return "Box"
        default: return nil
        }
    }
}
