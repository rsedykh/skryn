import AppKit

/// A cloud service that turns a file into a shareable link. Each provider lives in its own file,
/// together with its Settings controls; the rest of the app only sees this protocol and `UploadProviders`.
@MainActor
protocol UploadProvider: AnyObject {
    /// Stable identifier stored in UserDefaults; never change it, or users lose their choice.
    var id: String { get }
    /// Shown in Settings' "Service" menu and in failure notifications.
    var title: String { get }
    /// Nil when uploads can go ahead; otherwise what the user still has to set up.
    var setupProblem: String? { get }
    /// The provider's own Settings controls, shown under the Service menu; a `SettingsForm`, so its labels
    /// line up with the panel's. Call `onChange` after anything that affects `setupProblem` or the view's size.
    func makeSettingsView(onChange: @escaping () -> Void) -> SettingsForm
    /// Uploads the file and returns the link to copy.
    func upload(fileURL: URL, filename: String, contentType: String) async throws -> String
}

@MainActor
enum UploadProviders {
    /// Every provider, in Settings menu order. Adding a provider = adding it here.
    static let all: [UploadProvider] = [UploadcareProvider(), DropboxProvider()]

    static let defaultsKey = "uploadDestination"

    /// Posted when the chosen provider changes, or when its `setupProblem` may have (Settings edits)
    static let didChange = Notification.Name("UploadProvidersDidChange")

    /// The chosen provider; an unknown or missing ID falls back to the first.
    static var current: UploadProvider {
        get {
            let id = UserDefaults.standard.string(forKey: defaultsKey)
            return all.first { $0.id == id } ?? all[0]
        }
        set {
            UserDefaults.standard.set(newValue.id, forKey: defaultsKey)
            NotificationCenter.default.post(name: didChange, object: nil)
        }
    }
}
