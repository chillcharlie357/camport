import CoreFoundation
import Flutter
import Network
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "TransferBackgroundBridge") {
      TransferBackgroundBridge.register(with: registrar)
    }
  }
}

/// Protects Dart's existing PTP/IP TCP transfer, never an HTTP download or a queue.
private final class TransferBackgroundBridge: NSObject, FlutterPlugin {
  private let channel: FlutterMethodChannel
  private var observers: [NSObjectProtocol] = []
  private var task: UIBackgroundTaskIdentifier = .invalid
  private var budgetTimer: Timer?
  private var active = false
  private var budgetSignalled = false
  private var wasBackground = false
  private var monitor: NWPathMonitor?
  private var wifiReady: Bool?
  private var networkResults: [FlutterResult] = []
  private var networkTimeout: DispatchWorkItem?

  static func register(with registrar: FlutterPluginRegistrar) {
    let bridge = TransferBackgroundBridge(messenger: registrar.messenger())
    registrar.addMethodCallDelegate(bridge, channel: bridge.channel)
    // Publishing also enables detachFromEngine cleanup when the engine shuts down.
    registrar.publish(bridge)
  }

  private init(messenger: FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(
      name: "sony_camera/transfer_background", binaryMessenger: messenger)
    super.init()
    let center = NotificationCenter.default
    // Observe both scene and app notifications; deduplicate the shared transition.
    // App-delegate overrides alone are insufficient with Flutter's scene lifecycle.
    observers.append(center.addObserver(
      forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main
    ) { [weak self] _ in self?.enteredBackground() })
    observers.append(center.addObserver(
      forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
    ) { [weak self] _ in self?.becameActive() })
    observers.append(center.addObserver(
      forName: UIScene.didEnterBackgroundNotification, object: nil, queue: .main
    ) { [weak self] _ in self?.enteredBackground() })
    observers.append(center.addObserver(
      forName: UIScene.didActivateNotification, object: nil, queue: .main
    ) { [weak self] _ in
      DispatchQueue.main.async { [weak self] in self?.becameActive() }
    })
    observers.append(center.addObserver(
      forName: UIApplication.willTerminateNotification, object: nil, queue: .main
    ) { [weak self] _ in
      guard let self = self else { return }
      if self.active { self.emit("pauseRequested") }
      self.shutdown()
    })
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "start":
      guard let args = call.arguments as? [String: Any],
        let count = integer(args["pendingFiles"]), count > 0, count <= Int64(Int32.max)
      else { return fail(result, "invalid_arguments", "pendingFiles must be a positive integer") }
      guard !budgetSignalled else {
        return fail(result, "background_budget_expired", "Pause and flush the queue; return to the foreground before resuming")
      }
      if !active {
        guard UIApplication.shared.applicationState != .background else {
          return fail(result, "transfer_state", "Start transfer while the app is visible")
        }
        guard beginTask() else {
          return fail(result, "background_task_denied", "iOS did not grant a finite background task")
        }
        active = true
      }
      result(["message": "PTP/IP transfer has a finite iOS background window; keep the app open for long transfers."])
    case "update":
      guard let args = call.arguments as? [String: Any],
        let filename = args["filename"] as? String,
        !filename.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
        let bytes = integer(args["bytes"]), bytes >= 0,
        validTotal(args["total"])
      else { return fail(result, "invalid_arguments", "A filename and nonnegative integer byte counts are required") }
      guard active, task != .invalid, !budgetSignalled else {
        return fail(result, "transfer_state", "Transfer protection is inactive or its background budget expired")
      }
      checkBudget()
      result(nil)
    case "stop":
      active = false
      endTask()
      result(nil)
    case "prepareNetwork":
      prepareNetwork(result)
    case "releaseNetwork":
      guard !active else { return fail(result, "transfer_state", "Stop the transfer before releasing network monitoring") }
      releaseNetwork()
      result(nil)
    case "openWifiSettings":
      guard UIApplication.shared.applicationState == .active,
        let url = URL(string: UIApplication.openSettingsURLString)
      else { return fail(result, "settings_unavailable", "Open Settings while the app is visible") }
      // Apple exposes app settings, not a public deep link to the Wi-Fi pane.
      UIApplication.shared.open(url, options: [:]) { opened in
        if opened { result(nil) }
        else { self.fail(result, "settings_unavailable", "iOS could not open app settings; join the camera Wi-Fi in Settings") }
      }
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func beginTask() -> Bool {
    if task != .invalid { return true }
    task = UIApplication.shared.beginBackgroundTask(withName: "Finish Sony PTP/IP transfer") { [weak self] in
      guard let self = self else { return }
      self.signalBudgetExpired()
      // The expiration handler runs on the main thread. Never wait for Dart's
      // async flush here; end even when the early warning already fired.
      self.endTask()
    }
    return task != .invalid
  }

  private func enteredBackground() {
    guard !wasBackground else { return }
    wasBackground = true
    guard active, task != .invalid else { return }
    checkBudget()
    guard !budgetSignalled else { return }
    let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in self?.checkBudget() }
    budgetTimer?.invalidate()
    budgetTimer = timer
    RunLoop.main.add(timer, forMode: .common)
  }

  private func checkBudget() {
    guard active, task != .invalid, UIApplication.shared.applicationState == .background else { return }
    if UIApplication.shared.backgroundTimeRemaining < 5 { signalBudgetExpired() }
  }

  private func signalBudgetExpired() {
    guard !budgetSignalled else { return }
    budgetSignalled = true
    budgetTimer?.invalidate()
    budgetTimer = nil
    emit("budgetExpired")
    // Retain the remaining (<5s) lease for Dart to pause and flush. Dart stop()
    // releases it; expiration is the mandatory fallback, not a renewal loop.
  }

  private func becameActive() {
    guard wasBackground, UIApplication.shared.applicationState == .active else { return }
    wasBackground = false
    endTask()
    budgetSignalled = false
    if active && !beginTask() {
      signalBudgetExpired()
      return
    }
    // This is a lifecycle hint. The parent runner must suppress it after a
    // user pause and decide whether its persisted queue should actually resume.
    emit("resumeRequested")
  }

  private func endTask() {
    budgetTimer?.invalidate()
    budgetTimer = nil
    let oldTask = task
    task = .invalid
    if oldTask != .invalid { UIApplication.shared.endBackgroundTask(oldTask) }
  }

  private func prepareNetwork(_ result: @escaping FlutterResult) {
    if let ready = wifiReady { result(networkState(ready)); return }
    networkResults.append(result)
    guard monitor == nil else { return }
    let current = NWPathMonitor(requiredInterfaceType: .wifi)
    monitor = current
    current.pathUpdateHandler = { [weak self, weak current] path in
      DispatchQueue.main.async {
        guard let self = self, let current = current, self.monitor === current else { return }
        let ready = path.status == .satisfied && path.usesInterfaceType(.wifi)
        let lost = self.wifiReady == true && !ready
        self.wifiReady = ready
        self.finishNetworkResults(self.networkState(ready))
        if lost && self.active { self.emit("networkLost") }
      }
    }
    let timeout = DispatchWorkItem { [weak self, weak current] in
      guard let self = self, let current = current, self.monitor === current else { return }
      self.releaseNetwork(error: FlutterError(
        code: "network_timeout", message: "iOS did not report a Wi-Fi path; join the camera Wi-Fi and retry", details: nil))
    }
    networkTimeout = timeout
    DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: timeout)
    current.start(queue: DispatchQueue(label: "sony_camera.transfer_wifi"))
  }

  private func networkState(_ ready: Bool) -> [String: Any] {
    return [
      "connected": ready,
      "message": ready
        ? "Wi-Fi path available only. First join the camera Wi-Fi; the Dart PTP/IP handshake must confirm the camera. Discovery may require Apple's multicast entitlement; use manual IP if unavailable."
        : "No usable Wi-Fi path. Join the camera Wi-Fi in Settings, allow Local Network access, then retry or enter its IP manually.",
    ]
  }

  private func finishNetworkResults(_ value: Any) {
    networkTimeout?.cancel()
    networkTimeout = nil
    let results = networkResults
    networkResults.removeAll()
    for result in results { result(value) }
  }

  private func releaseNetwork(error: FlutterError? = nil) {
    monitor?.cancel()
    monitor = nil
    wifiReady = nil
    finishNetworkResults(error ?? FlutterError(
      code: "network_released", message: "Network monitoring was released", details: nil))
  }

  private func integer(_ value: Any?) -> Int64? {
    guard let value = value as? NSNumber,
      CFGetTypeID(value) != CFBooleanGetTypeID(),
      ["i", "q"].contains(String(cString: value.objCType))
    else { return nil }
    return value.int64Value
  }

  private func validTotal(_ value: Any?) -> Bool {
    if value == nil || value is NSNull { return true }
    guard let total = integer(value) else { return false }
    return total >= 0
  }

  private func emit(_ event: String) { channel.invokeMethod("event", arguments: event) }

  private func fail(_ result: FlutterResult, _ code: String, _ message: String) {
    result(FlutterError(code: code, message: message, details: nil))
  }

  func detachFromEngine(for registrar: FlutterPluginRegistrar) { shutdown() }

  private func shutdown() {
    active = false
    endTask()
    releaseNetwork()
    for observer in observers { NotificationCenter.default.removeObserver(observer) }
    observers.removeAll()
    channel.setMethodCallHandler(nil)
  }

  deinit {
    budgetTimer?.invalidate()
    monitor?.cancel()
    for observer in observers { NotificationCenter.default.removeObserver(observer) }
    if task != .invalid { UIApplication.shared.endBackgroundTask(task) }
  }
}
