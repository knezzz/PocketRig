import ActivityKit
import Flutter
import UIKit
import UserNotifications

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  /// Contract: host/watcher/PUSH.md.
  private var push: FlutterMethodChannel?
  /// A tapped link that arrived before Dart asked for it (cold start).
  private var pendingLink: String?
  private var watching = false
  private var lastStartToken: String?
  private var lastActivityToken: String?
  /// Dart has called register(), so its handler for "open" is set.
  private var dartReady = false

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    let center = UNUserNotificationCenter.current()
    center.delegate = self
    center.setNotificationCategories(AppDelegate.categories)
    watchActivities()  // a push-started activity wakes the app only for this; Dart may never run
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    let channel = FlutterMethodChannel(name: "dev.pocketrig/push", binaryMessenger: engineBridge.applicationRegistrar.messenger())
    channel.setMethodCallHandler { [weak self] call, result in
      if call.method == "startLiveActivity" {
        let host = (call.arguments as? [String: Any])?["host"] as? String ?? ""
        return result(self?.startLiveActivity(host: host) ?? false)
      }
      guard call.method == "register" else { return result(FlutterMethodNotImplemented) }
      UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
        DispatchQueue.main.async {
          if granted { UIApplication.shared.registerForRemoteNotifications() }
          self?.replayActivityTokens()
          self?.dartReady = true
          if let link = self?.pendingLink {
            self?.pendingLink = nil
            self?.push?.invokeMethod("open", arguments: ["link": link])
          }
          result(["granted": granted])
        }
      }
    }
    push = channel
  }

  override func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
    push?.invokeMethod("token", arguments: [
      "platform": "ios",
      "token": AppDelegate.hex(deviceToken),
      "env": AppDelegate.apsEnvironment,
    ])
  }

  // MARK: live activity

  /// Starts the activity on this phone when none runs (iOS 16.2+); the watcher updates and ends it. Returns whether one is running.
  private func startLiveActivity(host: String) -> Bool {
    guard #available(iOS 16.2, *), ActivityAuthorizationInfo().areActivitiesEnabled else { return false }
    if !Activity<PocketRigAttributes>.activities.isEmpty { return true }
    let empty = PocketRigAttributes.ContentState(needsCount: 0, workingCount: 0, updatedAt: Date().timeIntervalSince1970)
    let started = try? Activity.request(attributes: PocketRigAttributes(host: host), content: .init(state: empty, staleDate: nil), pushType: .token)
    if let started { report(started) }
    return started != nil
  }

  /// Sends Dart each activity's push token, and (iOS 17.2+) the token that lets the watcher start one with the app closed.
  private func watchActivities() {
    guard #available(iOS 16.2, *), !watching else { return }
    watching = true
    Activity<PocketRigAttributes>.activities.forEach(report)
    Task { for await a in Activity<PocketRigAttributes>.activityUpdates { self.report(a) } }
    if #available(iOS 17.2, *) {
      Task {
        for await data in Activity<PocketRigAttributes>.pushToStartTokenUpdates {
          await MainActor.run {
            self.lastStartToken = AppDelegate.hex(data)
            if self.dartReady { self.push?.invokeMethod("activityStartToken", arguments: ["token": self.lastStartToken!]) }
          }
        }
      }
    }
  }

  @available(iOS 16.2, *)
  private func report(_ a: Activity<PocketRigAttributes>) {
    Task {
      for await data in a.pushTokenUpdates {
        let token = AppDelegate.hex(data)
        // The watcher started it: tell the watcher directly, no Dart or SSH needed.
        if let url = a.attributes.tokenUrl, let ticket = a.attributes.ticket {
          self.postToken(url: url, body: ["token": token, "ticket": ticket])
        }
        await MainActor.run {
          self.lastActivityToken = token
          if self.dartReady { self.push?.invokeMethod("activityToken", arguments: ["token": token]) }
        }
      }
    }
  }

  /// Tokens that arrived before Dart was listening.
  private func replayActivityTokens() {
    if let t = lastStartToken { push?.invokeMethod("activityStartToken", arguments: ["token": t]) }
    if let t = lastActivityToken { push?.invokeMethod("activityToken", arguments: ["token": t]) }
  }

  private func postToken(url: String, body: [String: String]) {
    guard let url = URL(string: url), let data = try? JSONSerialization.data(withJSONObject: body) else { return }
    var req = URLRequest(url: url, timeoutInterval: 10)
    req.httpMethod = "POST"
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    req.httpBody = data
    // A network error (no HTTP answer) is tried again twice, 5 s apart; any HTTP status, 404 included, is final.
    func send(_ left: Int) {
      URLSession.shared.dataTask(with: req) { _, resp, _ in
        if resp == nil, left > 0 { DispatchQueue.global().asyncAfter(deadline: .now() + 5) { send(left - 1) } }
      }.resume()
    }
    send(2)
  }

  private static func hex(_ d: Data) -> String { d.map { String(format: "%02x", $0) }.joined() }

  // MARK: notifications

  private static let categories: Set<UNNotificationCategory> = {
    func a(_ id: String, _ title: String, _ options: UNNotificationActionOptions = []) -> UNNotificationAction {
      UNNotificationAction(identifier: id, title: title, options: options)
    }
    let open = a("open", "Open", .foreground)
    func c(_ id: String, _ actions: [UNNotificationAction]) -> UNNotificationCategory {
      UNNotificationCategory(identifier: id, actions: actions, intentIdentifiers: [], options: [])
    }
    return [
      c("pr-permission", [a("allow", "Allow once"), a("deny", "Deny", .destructive), open]),
      c("pr-question", [a("reply", "Reply…", .foreground), open]),
      c("pr-blocked", [open, a("snooze", "Snooze 1 h")]),
      c("pr-result", [open]),
    ]
  }()

  /// "production" or "sandbox": a development-signed build (even a release one) uses the sandbox gateway.
  private static let apsEnvironment: String = {
    guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
          let data = try? Data(contentsOf: url),
          let text = String(data: data, encoding: .isoLatin1),
          let key = text.range(of: "<key>aps-environment</key>"),
          let value = text[key.upperBound...].range(of: "<string>(.*?)</string>", options: .regularExpression)
    else { return "production" }  // App Store / TestFlight builds carry no profile
    return text[value].contains("development") ? "sandbox" : "production"
  }()

  // The app has its own needs-you banner while it is open.
  override func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                       withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
    completionHandler([])
  }

  override func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                       withCompletionHandler completionHandler: @escaping () -> Void) {
    let info = response.notification.request.content.userInfo
    let link = info["link"] as? String
    switch response.actionIdentifier {
    case "allow", "deny", "snooze":
      let actions = (info["actions"] as? String).flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) } as? [[String: Any]] ?? []
      guard let action = actions.first(where: { $0["id"] as? String == response.actionIdentifier }) else { return completionHandler() }
      post(action) { ok in
        // The phone couldn't reach the host: let Dart try, and keep the ask up.
        if !ok { DispatchQueue.main.async { self.push?.invokeMethod("action", arguments: action) } }
        completionHandler()
      }
    case "reply":
      open(link.map { $0.contains("view=chat") ? $0 : $0 + ($0.contains("?") ? "&" : "?") + "view=chat" })
      completionHandler()
    default:  // open, or a tap on the body
      open(link)
      completionHandler()
    }
  }

  private func open(_ link: String?) {
    guard let link else { return }
    if dartReady, let push, UIApplication.shared.applicationState != .background {
      push.invokeMethod("open", arguments: ["link": link])
    } else {
      pendingLink = link
    }
  }

  private func post(_ action: [String: Any], done: @escaping (Bool) -> Void) {
    guard let url = (action["url"] as? String).flatMap(URL.init(string:)), let body = action["body"] as? String else { return done(false) }
    var req = URLRequest(url: url, timeoutInterval: 10)
    req.httpMethod = "POST"
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    req.httpBody = Data(body.utf8)
    URLSession.shared.dataTask(with: req) { _, resp, _ in
      done(resp != nil)  // any HTTP answer: the watcher already replaced the ask with its result
    }.resume()
  }
}
