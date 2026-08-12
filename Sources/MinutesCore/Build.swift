import Foundation

/// Identity of the product. Kept in one place so the app, the CLI and the
/// files written to disk all report the same thing.
public enum MinutesBuild {
    public static let productName = "minutes"
    public static let version = "0.2.0"

    /// Stable application id sent to the model gateway as `x-litellm-customer-id`.
    public static let appID = "minutes"
}
