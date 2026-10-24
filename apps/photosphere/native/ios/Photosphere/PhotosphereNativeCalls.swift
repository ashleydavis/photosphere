//
// Photosphere's native calls on iOS: the photo permission prompt, the device keychain, the connection type and
// the things the background work needs from the platform. Each request is named by its method and carries and returns JSON text. The core
// calls from a worker thread and waits, so a request may block on a permission prompt.
//

import Foundation
import os.log
import Photos
import UserNotifications
import ZiggyNativeIOS

// Photosphere's native call handler.
final class PhotosphereNativeCalls: ZiggyNativeCallHandler {
    // The keychain the app's secrets are in.
    private let secureStore = SecureStore(service: "au.com.codecapers.photosphere.securestore")

    // Reports the kind of connection the phone has.
    private let network = NetworkHost()

    // Keeps the app running while a background pass is.
    private let wakeHold = BackgroundWakeHold()

    // The log the background work reports to. The background work runs with the app off screen, when the app's own log file (written
    // through the page) is not being written, so what it is doing is told to the system log.
    private let backgroundLog = OSLog(subsystem: Bundle.main.bundleIdentifier ?? "au.com.codecapers.photosphere.ziggy", category: "AutoImportService")

    // The handlers for the methods this class does not handle, by method name. Fixed when the class is made, so the core's worker
    // threads read it without a lock.
    private let otherHandlers: [String: ZiggyNativeCallHandler]

    init(otherHandlers: [String: ZiggyNativeCallHandler]) {
        self.otherHandlers = otherHandlers
    }

    func handle(method: String, requestJson: String) throws -> String {
        switch method {
        case "requestMediaPermission":
            return try requestMediaPermission()
        case "requestNotificationPermission":
            return try requestNotificationPermission()
        case "networkConnectionType":
            return try NativeCallJson.quote(network.connectionType(), method: method)
        case "secureStoreGet":
            let request = try NativeCallJson.object(from: requestJson, method: method)
            let value = try keychain(method) {
                try self.secureStore.get(key: try NativeCallJson.string(request, "key", method: method))
            }
            let reply: [String: Any] = [
                "value": value ?? NSNull(),
            ]
            return try NativeCallJson.text(from: reply, method: method)
        case "secureStoreSet":
            let request = try NativeCallJson.object(from: requestJson, method: method)
            let key = try NativeCallJson.string(request, "key", method: method)
            let value = try NativeCallJson.string(request, "value", method: method)
            try keychain(method) {
                try self.secureStore.set(key: key, value: value)
            }
            return "null"
        case "secureStoreDelete":
            let request = try NativeCallJson.object(from: requestJson, method: method)
            let key = try NativeCallJson.string(request, "key", method: method)
            try keychain(method) {
                try self.secureStore.delete(key: key)
            }
            return "null"
        case "secureStoreKeys":
            let keys = try keychain(method) {
                try self.secureStore.keys()
            }
            let reply: [String: Any] = [
                "keys": keys,
            ]
            return try NativeCallJson.text(from: reply, method: method)
        case "holdAwake":
            let request = try NativeCallJson.object(from: requestJson, method: method)
            guard let awake = request["awake"] as? Bool else {
                throw ZiggyNativeCallError("The request \(method) was not understood: \"awake\" is missing or is not true or false.")
            }
            wakeHold.hold(awake)
            return "null"
        case "backgroundLog":
            let request = try NativeCallJson.object(from: requestJson, method: method)
            let message = try NativeCallJson.string(request, "message", method: method)
            guard let isError = request["error"] as? Bool else {
                throw ZiggyNativeCallError("The request \(method) was not understood: \"error\" is missing or is not true or false.")
            }
            os_log("%{public}@", log: backgroundLog, type: isError ? .error : .info, message)
            return "null"
        default:
            if let other = otherHandlers[method] {
                return try other.handle(method: method, requestJson: requestJson)
            }
            throw ZiggyNativeCallError("The Photosphere iOS app cannot do \"\(method)\" yet.")
        }
    }

    // Runs a keychain operation, turning a keychain failure into a failure of the request that names the keychain as the cause.
    private func keychain<Result>(_ method: String, _ operation: () throws -> Result) throws -> Result {
        do {
            return try operation()
        }
        catch let failure as ZiggyNativeCallError {
            throw failure
        }
        catch {
            throw ZiggyNativeCallError("The device keychain could not be used for \(method): \(error)")
        }
    }

    // Requests the photo library permission and reports whether it was granted, as {granted, partial}.
    //
    // Only read access is requested. Limited access (the user choosing particular photos) counts as granted: automatic import can
    // only see what it was given, and telling the user it was refused when they deliberately shared a few photos would be wrong. So
    // partial is always false on iOS.
    private func requestMediaPermission() throws -> String {
        let finished = DispatchSemaphore(value: 0)
        var granted = false
        PHPhotoLibrary.requestAuthorization { status in
            if #available(iOS 14, *) {
                granted = status == .authorized || status == .limited
            }
            else {
                granted = status == .authorized
            }
            finished.signal()
        }
        finished.wait()
        let reply: [String: Any] = [
            "granted": granted,
            "partial": false,
        ]
        return try NativeCallJson.text(from: reply, method: "requestMediaPermission")
    }

    // Reports whether notifications are allowed, as {granted}, without a prompt. iOS shows no ongoing notification while the background
    // work runs, so there is nothing to request, and the result only reports the system's setting.
    private func requestNotificationPermission() throws -> String {
        let finished = DispatchSemaphore(value: 0)
        var granted = false
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            granted = settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional
            finished.signal()
        }
        finished.wait()
        let reply: [String: Any] = [
            "granted": granted,
        ]
        return try NativeCallJson.text(from: reply, method: "requestNotificationPermission")
    }
}
