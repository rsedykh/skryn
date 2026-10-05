import AppKit
import UserNotifications

/// Feedback for actions (saved, copied, link copied, failures) as native macOS notifications.
/// macOS asks for permission the first time one is shown; if the user declines, nothing is shown.
@MainActor
final class Notifier: NSObject {
    enum Style { case success, failure, info }
    /// A button on the notification; clicking the notification itself runs it too.
    struct Action {
        let title: String
        let handler: () -> Void
    }

    private static let shared = Notifier()
    nonisolated private static let actionID = "run"
    /// Handlers by notification ID, until the user responds (kept small: old ones are dropped)
    private var handlers: [String: () -> Void] = [:]
    private var handlerOrder: [String] = []
    private var categories: Set<UNNotificationCategory> = []

    /// Call at launch so clicks on notifications reach the app.
    static func setUp() {
        UNUserNotificationCenter.current().delegate = shared
    }

    static func show(_ message: String, detail: String? = nil, style: Style = .success, action: Action? = nil) {
        shared.post(message, detail: detail, style: style, action: action)
    }

    private func post(_ message: String, detail: String?, style: Style, action: Action?) {
        let content = UNMutableNotificationContent()
        content.title = message
        if let detail { content.body = detail }
        if style == .failure { content.sound = .default }  // successes stay quiet

        let id = UUID().uuidString
        if let action {
            content.categoryIdentifier = register(actionTitle: action.title)
            remember(action.handler, for: id)
        }
        let request = UNNotificationRequest(identifier: id, content: content, trigger: nil)
        Task {
            let center = UNUserNotificationCenter.current()
            // Prompts once; afterwards it returns the stored answer
            guard (try? await center.requestAuthorization(options: [.alert, .sound])) == true else { return }
            try? await center.add(request)
        }
    }

    /// One category per button title ("Show in Finder", "Open", "Open Settings…"), registered on first use.
    private func register(actionTitle: String) -> String {
        let categoryID = "skryn.\(actionTitle)"
        let category = UNNotificationCategory(
            identifier: categoryID,
            actions: [UNNotificationAction(identifier: Self.actionID, title: actionTitle)],
            intentIdentifiers: []
        )
        if categories.insert(category).inserted {
            UNUserNotificationCenter.current().setNotificationCategories(categories)
        }
        return categoryID
    }

    private func remember(_ handler: @escaping () -> Void, for id: String) {
        handlers[id] = handler
        handlerOrder.append(id)
        if handlerOrder.count > 50 {
            handlers[handlerOrder.removeFirst()] = nil
        }
    }

    fileprivate func respond(to id: String) {
        handlers.removeValue(forKey: id)?()
    }
}

extension Notifier: UNUserNotificationCenterDelegate {
    /// Show banners even while Skryn is the active app (e.g. right after the editor closes).
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse
    ) async {
        let id = response.notification.request.identifier
        guard response.actionIdentifier == Self.actionID
                || response.actionIdentifier == UNNotificationDefaultActionIdentifier else { return }
        await MainActor.run { Notifier.shared.respond(to: id) }
    }
}
