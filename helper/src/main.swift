// AllowShowNotifier: a tiny notification helper with real action buttons.
//
// macOS's modern notification API (UNUserNotificationCenter) only delivers
// registered notification *actions* (as opposed to just a body-click) to a
// process that is a real, bundled, identified app -- a bare command-line
// binary can't register categories or receive delegate callbacks. That's why
// this lives inside AllowShowNotifier.app rather than being a plain script,
// mirroring how terminal-notifier itself ships a .app bundle under the hood.
//
// Usage:
//   AllowShowNotifier post <permission|elicitation> <title> <subtitle> <message>
//   AllowShowNotifier status
//   AllowShowNotifier authorize
//   AllowShowNotifier probe
//
// `post` posts one notification with real "Allow"/"Show" (permission) or
// "Show" (elicitation) buttons, blocks (no timeout -- that's the whole point)
// until the user acts on it or clears it, prints exactly one line to stdout,
// then exits:
//   ALLOW | SHOW | DISMISS | UNKNOWN:<action-id>   the user acted (exit 0)
//   UNAUTHORIZED:<status>                          not authorized; nothing posted (exit 1)
//   ERROR                                          failed; nothing posted (exit 1)
// It never asks for permission itself (a hook must not block on a consent
// prompt); run `authorize` once by hand for that. After a successful post it
// writes `posted <request-id>` to stderr, so a caller can tell "died before
// showing anything" from "died while a card was up". All the tmux/xirp logic
// the stdout line drives lives in notify.sh, not here -- this only answers
// "what did the user click".
//
// Routing: every `post` process shares one bundle id, and macOS hands a
// response to whichever of those processes it picks -- NOT necessarily the one
// that posted that card (observed: with four cards up, all four responses
// landed in the wrong process). So each process relays a response that isn't
// for its own request id to the right process over a distributed notification
// whose object is that request id, and listens for relays addressed to its own.
//
// `status` prints this app's notification authorization without ever
// prompting -- one line, `<authorized|denied|notDetermined|provisional|...>
// alertStyle=<none|banner|alert>` -- and exits 0 only when authorized. It is a
// diagnostic for humans; notify.sh does not call it per event.
//
// `authorize` asks for permission (macOS shows its "would like to send you
// notifications" prompt only if it has never been answered for this bundle
// id -- once answered, or dismissed, the only way back is System Settings ->
// Notifications), waits for the answer, prints GRANTED or DENIED, and exits
// 0 / 1.
//
// `probe` posts a plain card that removes itself after 3 seconds and prints
// `posted <id>`; setup.sh then reads donotdisturbd's verdict on it from the
// unified log to tell whether the current Focus lets these cards through.

import Foundation
import UserNotifications

let ALLOW_ACTION = "ALLOW_ACTION"
let SHOW_ACTION = "SHOW_ACTION"
let PERMISSION_CATEGORY = "PERMISSION_CATEGORY"
let ELICITATION_CATEGORY = "ELICITATION_CATEGORY"
let RESPONSE_RELAY = Notification.Name("com.leobelyi.notify-hook.allowshownotifier.response")

func eprint(_ s: String) {
    FileHandle.standardError.write((s + "\n").data(using: .utf8)!)
}

func emitAndExit(_ result: String) -> Never {
    print(result)
    fflush(stdout)
    exit(0)
}

/// The request id of the card this process posted; nil outside `post`.
var myRequestId: String?

final class Delegate: NSObject, UNUserNotificationCenterDelegate {
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list, .sound])
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let result: String
        switch response.actionIdentifier {
        case UNNotificationDefaultActionIdentifier:
            result = "SHOW" // body tap, no explicit button -- treat as the safe one
        case ALLOW_ACTION:
            result = "ALLOW"
        case SHOW_ACTION:
            result = "SHOW"
        case UNNotificationDismissActionIdentifier:
            result = "DISMISS"
        default:
            result = "UNKNOWN:\(response.actionIdentifier)"
        }
        let rid = response.notification.request.identifier
        if let mine = myRequestId, rid == mine {
            completionHandler()
            emitAndExit(result)
        }
        // Someone else's card: hand it to the process that posted it.
        DistributedNotificationCenter.default().postNotificationName(
            RESPONSE_RELAY, object: rid, userInfo: ["result": result], deliverImmediately: true)
        eprint("relayed \(result) for \(rid)")
        completionHandler()
    }
}

func registerCategories() {
    let allow = UNNotificationAction(identifier: ALLOW_ACTION, title: "Allow", options: [])
    // No .foreground: the helper has no UI to bring forward, and with it macOS
    // also launches a fresh, argument-less copy of the app on every Show click.
    let show = UNNotificationAction(identifier: SHOW_ACTION, title: "Show", options: [])

    let permission = UNNotificationCategory(
        identifier: PERMISSION_CATEGORY,
        actions: [allow, show],
        intentIdentifiers: [],
        options: [.customDismissAction]
    )
    let elicitation = UNNotificationCategory(
        identifier: ELICITATION_CATEGORY,
        actions: [show],
        intentIdentifiers: [],
        options: [.customDismissAction]
    )
    UNUserNotificationCenter.current().setNotificationCategories([permission, elicitation])
}

func requestAuthorizationSync() -> Bool {
    let sema = DispatchSemaphore(value: 0)
    var granted = false
    UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { ok, error in
        granted = ok
        if let error = error { eprint("authorization error: \(error)") }
        sema.signal()
    }
    sema.wait()
    return granted
}

/// Never prompts. Bounded wait so a wedged usernoted can't hang the caller.
func settingsSync() -> UNNotificationSettings? {
    let sema = DispatchSemaphore(value: 0)
    var result: UNNotificationSettings?
    UNUserNotificationCenter.current().getNotificationSettings { settings in
        result = settings
        sema.signal()
    }
    return sema.wait(timeout: .now() + 5) == .timedOut ? nil : result
}

func describe(_ status: UNAuthorizationStatus) -> String {
    switch status {
    case .authorized: return "authorized"
    case .denied: return "denied"
    case .notDetermined: return "notDetermined"
    case .provisional: return "provisional"
    @unknown default: return "unknown(\(status.rawValue))"
    }
}

func describe(_ style: UNAlertStyle) -> String {
    switch style {
    case .none: return "none"
    case .banner: return "banner"
    case .alert: return "alert"
    @unknown default: return "unknown(\(style.rawValue))"
    }
}

let args = CommandLine.arguments
let usage = """
usage: \(args.first ?? "AllowShowNotifier") post <permission|elicitation> <title> <subtitle> <message>
       \(args.first ?? "AllowShowNotifier") status
       \(args.first ?? "AllowShowNotifier") authorize
       \(args.first ?? "AllowShowNotifier") probe
"""

// Every mode installs the relaying delegate before touching the center: any
// process holding this bundle id's connection can be handed someone's click.
let delegate = Delegate()
let center = UNUserNotificationCenter.current()
center.delegate = delegate

if args.count == 2, args[1] == "status" {
    guard let settings = settingsSync() else {
        print("timeout")
        exit(3)
    }
    print("\(describe(settings.authorizationStatus)) alertStyle=\(describe(settings.alertStyle))")
    exit(settings.authorizationStatus == .authorized ? 0 : 1)
}

if args.count == 2, args[1] == "authorize" {
    let granted = requestAuthorizationSync()
    print(granted ? "GRANTED" : "DENIED")
    exit(granted ? 0 : 1)
}

if args.count == 2, args[1] == "probe" {
    // setup.sh's Focus check: a plain card (no buttons) that removes itself.
    // Prints `posted <id>`, UNAUTHORIZED:<status>, or ERROR.
    guard let settings = settingsSync() else {
        print("ERROR")
        exit(1)
    }
    guard settings.authorizationStatus == .authorized else {
        print("UNAUTHORIZED:\(describe(settings.authorizationStatus))")
        exit(1)
    }
    let probeId = "probe-\(UUID().uuidString)"
    let probe = UNMutableNotificationContent()
    probe.title = "notify-hook setup check"
    probe.body = "Checking whether cards get through your Focus. This card removes itself."
    let sema = DispatchSemaphore(value: 0)
    var probeError: Error?
    center.add(UNNotificationRequest(identifier: probeId, content: probe, trigger: nil)) { error in
        probeError = error
        sema.signal()
    }
    sema.wait()
    if let probeError = probeError {
        eprint("failed to post probe: \(probeError)")
        print("ERROR")
        exit(1)
    }
    Thread.sleep(forTimeInterval: 3)
    center.removeDeliveredNotifications(withIdentifiers: [probeId])
    Thread.sleep(forTimeInterval: 0.5) // let the removal reach usernoted before exiting
    print("posted \(probeId)")
    exit(0)
}

guard args.count >= 6, args[1] == "post" else {
    eprint(usage)
    exit(2)
}

let kind = args[2]
let title = args[3]
let subtitle = args[4]
let message = args[5]

let categoryId: String
switch kind {
case "permission": categoryId = PERMISSION_CATEGORY
case "elicitation": categoryId = ELICITATION_CATEGORY
default:
    eprint("unknown category: \(kind)")
    exit(2)
}

registerCategories()

guard let settings = settingsSync() else {
    eprint("timed out reading notification settings")
    print("ERROR")
    exit(1)
}
guard settings.authorizationStatus == .authorized else {
    let status = describe(settings.authorizationStatus)
    eprint("notifications not authorized (\(status)); run `\(args[0]) authorize` once, or enable it in System Settings -> Notifications")
    print("UNAUTHORIZED:\(status)")
    exit(1)
}

let requestId = UUID().uuidString
myRequestId = requestId

// Listen for our own response being relayed from another process -- before
// posting, so a fast click can't beat the observer.
let relayObserver = DistributedNotificationCenter.default().addObserver(
    forName: RESPONSE_RELAY, object: requestId, queue: .main
) { note in
    emitAndExit((note.userInfo?["result"] as? String) ?? "UNKNOWN:relay")
}

let content = UNMutableNotificationContent()
content.title = title
if !subtitle.isEmpty { content.subtitle = subtitle }
content.body = message
content.categoryIdentifier = categoryId
content.sound = .default

let request = UNNotificationRequest(identifier: requestId, content: content, trigger: nil)

let addSema = DispatchSemaphore(value: 0)
var addError: Error?
center.add(request) { error in
    addError = error
    addSema.signal()
}
addSema.wait()

if let addError = addError {
    eprint("failed to post notification: \(addError)")
    print("ERROR")
    exit(1)
}
eprint("posted \(requestId)")

// No timeout: the notification -- and this process waiting on it -- persists
// until the user acts or clears it.
withExtendedLifetime(relayObserver) {
    RunLoop.main.run()
}
