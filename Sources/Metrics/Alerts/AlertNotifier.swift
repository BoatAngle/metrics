import AppKit
import Foundation
import UserNotifications

/// A notification the engine wants delivered. The notifier derives the category
/// (and therefore which action buttons appear) from `pid` / `volumePath`.
struct AlertNotification {
    var ruleID: UUID
    var title: String
    var body: String
    var pid: Int32? = nil
    var volumePath: String? = nil
}

/// Wraps UNUserNotificationCenter. Authorization is requested lazily on the
/// first enabled rule (feature #15). Every call is guarded by `isAvailable`,
/// which is false when Metrics runs as a bare executable (e.g. `--dump`) with
/// no bundle — touching `UNUserNotificationCenter.current()` there would crash,
/// so in that mode the notifier degrades to a no-op and just logs.
@MainActor
final class AlertNotifier: NSObject {
    static let shared = AlertNotifier()

    // Category identifiers (which action set the notification carries).
    static let categoryGeneric = "metrics.alert.generic"
    static let categoryProcess = "metrics.alert.process"
    static let categoryDisk = "metrics.alert.disk"

    // Action identifiers.
    static let actionSnooze30 = "metrics.action.snooze30"
    static let actionSnoozeTomorrow = "metrics.action.snoozeTomorrow"
    static let actionDisable = "metrics.action.disable"
    static let actionForceQuit = "metrics.action.forceQuit"
    static let actionReveal = "metrics.action.reveal"

    /// True only inside a real app bundle. UN requires one.
    let isAvailable: Bool = Bundle.main.bundleIdentifier != nil

    private(set) var authorizationRequested = false
    private(set) var authorized = false
    private var categoriesRegistered = false

    /// Set the delegate and register categories once, at launch.
    func configure() {
        guard isAvailable else { return }
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        registerCategories(on: center)
        // Adopt whatever authorization already stands so the UI can reflect it.
        center.getNotificationSettings { settings in
            let ok = settings.authorizationStatus == .authorized
                || settings.authorizationStatus == .provisional
            Task { @MainActor in self.authorized = ok }
        }
    }

    private func registerCategories(on center: UNUserNotificationCenter) {
        guard !categoriesRegistered else { return }
        categoriesRegistered = true

        let snooze30 = UNNotificationAction(identifier: Self.actionSnooze30,
                                            title: "Snooze 30 min", options: [])
        let snoozeTomorrow = UNNotificationAction(identifier: Self.actionSnoozeTomorrow,
                                                  title: "Snooze until tomorrow", options: [])
        let disable = UNNotificationAction(identifier: Self.actionDisable,
                                           title: "Disable rule", options: [.destructive])
        let forceQuit = UNNotificationAction(identifier: Self.actionForceQuit,
                                             title: "Force Quit", options: [.destructive, .authenticationRequired])
        let reveal = UNNotificationAction(identifier: Self.actionReveal,
                                          title: "Reveal in Finder", options: [.foreground])
        let common = [snooze30, snoozeTomorrow, disable]

        let generic = UNNotificationCategory(identifier: Self.categoryGeneric,
                                             actions: common, intentIdentifiers: [], options: [])
        let process = UNNotificationCategory(identifier: Self.categoryProcess,
                                             actions: [forceQuit] + common, intentIdentifiers: [], options: [])
        let disk = UNNotificationCategory(identifier: Self.categoryDisk,
                                          actions: [reveal] + common, intentIdentifiers: [], options: [])
        center.setNotificationCategories([generic, process, disk])
    }

    /// Ask for permission the first time a rule that could fire is enabled.
    func requestAuthorizationIfNeeded() {
        guard isAvailable, !authorizationRequested else { return }
        authorizationRequested = true
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
            Task { @MainActor in self.authorized = granted }
        }
    }

    /// Deliver a firing. Chooses the category from the supplied context so the
    /// right buttons appear.
    func post(_ notification: AlertNotification) {
        guard isAvailable else {
            NSLog("[Metrics] alert (no bundle, not posted): %@ — %@", notification.title, notification.body)
            return
        }
        requestAuthorizationIfNeeded()

        let content = UNMutableNotificationContent()
        content.title = notification.title
        content.body = notification.body
        content.sound = .default

        var info: [String: Any] = ["ruleID": notification.ruleID.uuidString]
        if let pid = notification.pid {
            info["pid"] = Int(pid)
            content.categoryIdentifier = Self.categoryProcess
        } else if let path = notification.volumePath {
            info["volumePath"] = path
            content.categoryIdentifier = Self.categoryDisk
        } else {
            content.categoryIdentifier = Self.categoryGeneric
        }
        content.userInfo = info

        let request = UNNotificationRequest(identifier: UUID().uuidString,
                                            content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    // MARK: - Response routing

    /// Executes a tapped notification action. Runs on the main actor.
    static func handle(actionID: String, userInfo: [AnyHashable: Any]) {
        let ruleID = (userInfo["ruleID"] as? String).flatMap(UUID.init)
        switch actionID {
        case actionSnooze30:
            if let ruleID { AlertEngine.shared.snooze(ruleID: ruleID, seconds: 30 * 60) }
        case actionSnoozeTomorrow:
            if let ruleID { AlertEngine.shared.snoozeUntilTomorrow(ruleID: ruleID) }
        case actionDisable:
            if let ruleID { AlertEngine.shared.setEnabled(ruleID: ruleID, enabled: false) }
        case actionForceQuit:
            if let pid = userInfo["pid"] as? Int { ProcessControl.forceKill(Int32(pid)) }
        case actionReveal:
            if let path = userInfo["volumePath"] as? String {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
            }
        default:
            break   // default tap: nothing intrusive.
        }
    }
}

// MARK: - UNUserNotificationCenterDelegate

extension AlertNotifier: UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        // Show the banner even when Metrics is frontmost.
        completionHandler([.banner, .sound, .list])
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let actionID = response.actionIdentifier
        let userInfo = response.notification.request.content.userInfo
        Task { @MainActor in
            AlertNotifier.handle(actionID: actionID, userInfo: userInfo)
            completionHandler()
        }
    }
}
