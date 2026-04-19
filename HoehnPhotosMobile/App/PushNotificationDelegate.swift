import UIKit
import CloudKit
import HoehnPhotosCore

/// UIApplicationDelegate adapter that handles CloudKit silent-push wake-ups.
/// Call `register()` at app launch to hook remote notifications.
@MainActor
final class PushNotificationDelegate: NSObject, UIApplicationDelegate {
    private weak var cloudSyncEngine: CloudSyncEngine?

    init(engine: CloudSyncEngine) {
        self.cloudSyncEngine = engine
        super.init()
    }

    func register() {
        // Request silent push only — no user-visible notifications.
        UIApplication.shared.registerForRemoteNotifications()
    }

    func application(_ application: UIApplication,
                     didReceiveRemoteNotification userInfo: [AnyHashable: Any],
                     fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void) {
        // Decode as CKNotification — is it from our zone?
        guard let notification = CKNotification(fromRemoteNotificationDictionary: userInfo as? [String: NSObject] ?? [:]),
              notification.subscriptionID != nil else {
            completionHandler(.noData)
            return
        }
        Task { @MainActor in
            await cloudSyncEngine?.sync()
            completionHandler(.newData)
        }
    }

    func application(_ application: UIApplication,
                     didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        // CloudKit doesn't need the device token, but we log receipt for debug.
        #if DEBUG
        print("[Push] registered")
        #endif
    }

    func application(_ application: UIApplication,
                     didFailToRegisterForRemoteNotificationsWithError error: Error) {
        #if DEBUG
        print("[Push] register failed: \(error.localizedDescription)")
        #endif
    }
}
