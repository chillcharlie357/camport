import Cocoa
import CoreFoundation
import FlutterMacOS
import Network

class MainFlutterWindow: NSWindow {
  private var transferBridge: TransferBackgroundBridge?

  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)
    transferBridge = TransferBackgroundBridge(
      messenger: flutterViewController.engine.binaryMessenger, window: self)

    super.awakeFromNib()
  }
}

/// A process activity protects Dart's live PTP/IP sockets from idle system sleep.
/// It neither downloads files nor runs after the application exits.
private final class TransferBackgroundBridge {
  private let channel: FlutterMethodChannel
  private var activity: NSObjectProtocol?
  private var observers: [NSObjectProtocol] = []
  private var workspaceObservers: [NSObjectProtocol] = []
  private var interruptedBySleep = false
  private var closed = false
  private var monitor: NWPathMonitor?
  private var networkReady: Bool?
  private var networkResults: [FlutterResult] = []
  private var networkTimeout: DispatchWorkItem?

  init(messenger: FlutterBinaryMessenger, window: NSWindow) {
    channel = FlutterMethodChannel(
      name: "camport/transfer_background", binaryMessenger: messenger)
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self = self, !self.closed else {
        result(FlutterError(code: "bridge_closed", message: "The transfer bridge has closed", details: nil))
        return
      }
      self.handle(call, result: result)
    }
    let center = NotificationCenter.default
    observers.append(center.addObserver(
      forName: NSWindow.willCloseNotification, object: window, queue: .main
    ) { [weak self] _ in self?.shutdown() })
    observers.append(center.addObserver(
      forName: NSApplication.willTerminateNotification, object: nil, queue: .main
    ) { [weak self] _ in self?.shutdown() })
    let workspace = NSWorkspace.shared.notificationCenter
    workspaceObservers.append(workspace.addObserver(
      forName: NSWorkspace.willSleepNotification, object: nil, queue: .main
    ) { [weak self] _ in
      guard let self = self, self.activity != nil else { return }
      self.interruptedBySleep = true
      self.emit("pauseRequested")
      self.stopActivity()
    })
    workspaceObservers.append(workspace.addObserver(
      forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
    ) { [weak self] _ in
      guard let self = self, self.interruptedBySleep else { return }
      self.interruptedBySleep = false
      // The Dart parent filters manually paused queues and reacquires via start.
      self.emit("resumeRequested")
    })
  }

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "start":
      guard let args = call.arguments as? [String: Any],
        let count = integer(args["pendingFiles"]), count > 0, count <= Int64(Int32.max)
      else { return fail(result, "invalid_arguments", "pendingFiles must be a positive integer") }
      if activity == nil {
        activity = ProcessInfo.processInfo.beginActivity(
          options: [.userInitiated, .idleSystemSleepDisabled],
          reason: "Import Sony camera files over PTP/IP")
      }
      result(["message": "Idle system sleep is prevented during this transfer. Explicit sleep or quitting can interrupt it; the Dart queue must persist progress."])
    case "update":
      guard let args = call.arguments as? [String: Any],
        let filename = args["filename"] as? String,
        !filename.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
        let bytes = integer(args["bytes"]), bytes >= 0,
        validTotal(args["total"])
      else { return fail(result, "invalid_arguments", "A filename and nonnegative integer byte counts are required") }
      guard activity != nil else { return fail(result, "transfer_state", "No active transfer protection") }
      result(nil)
    case "stop":
      stopActivity()
      result(nil)
    case "prepareNetwork":
      prepareNetwork(result)
    case "releaseNetwork":
      guard activity == nil else { return fail(result, "transfer_state", "Stop the transfer before releasing network monitoring") }
      releaseNetwork()
      result(nil)
    case "openWifiSettings":
      // Open the installed Settings application itself; no undocumented pane IDs
      // or private preference URL schemes. The user selects Wi-Fi there.
      let modern = URL(fileURLWithPath: "/System/Applications/System Settings.app")
      let legacy = URL(fileURLWithPath: "/System/Applications/System Preferences.app")
      let url = FileManager.default.fileExists(atPath: modern.path) ? modern : legacy
      if NSWorkspace.shared.open(url) { result(nil) }
      else { fail(result, "settings_unavailable", "macOS could not open System Settings; open Wi-Fi settings manually") }
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func prepareNetwork(_ result: @escaping FlutterResult) {
    if let ready = networkReady { result(networkState(ready)); return }
    networkResults.append(result)
    guard monitor == nil else { return }
    let current = NWPathMonitor()
    monitor = current
    current.pathUpdateHandler = { [weak self, weak current] path in
      DispatchQueue.main.async {
        guard let self = self, let current = current, self.monitor === current else { return }
        let ready = path.status == .satisfied
          && (path.usesInterfaceType(.wifi) || path.usesInterfaceType(.wiredEthernet))
        let lost = self.networkReady == true && !ready
        self.networkReady = ready
        self.finishNetworkResults(self.networkState(ready))
        if lost && self.activity != nil { self.emit("networkLost") }
      }
    }
    let timeout = DispatchWorkItem { [weak self, weak current] in
      guard let self = self, let current = current, self.monitor === current else { return }
      self.releaseNetwork(error: FlutterError(
        code: "network_timeout", message: "macOS did not report a local network path; check Wi-Fi and retry", details: nil))
    }
    networkTimeout = timeout
    DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: timeout)
    current.start(queue: DispatchQueue(label: "camport.transfer_network"))
  }

  private func networkState(_ ready: Bool) -> [String: Any] {
    return [
      "connected": ready,
      "message": ready
        ? "A Wi-Fi or Ethernet network path is available only; no camera connection or route binding is confirmed. Join the camera network and verify it with the Dart PTP/IP handshake."
        : "No usable Wi-Fi or Ethernet path. Join the camera network, allow Local Network access, then retry or enter its IP manually.",
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
    networkReady = nil
    finishNetworkResults(error ?? FlutterError(
      code: "network_released", message: "Network monitoring was released", details: nil))
  }

  private func stopActivity() {
    if let token = activity {
      activity = nil
      ProcessInfo.processInfo.endActivity(token)
    }
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

  private func shutdown() {
    guard !closed else { return }
    closed = true
    if activity != nil { emit("pauseRequested") }
    stopActivity()
    releaseNetwork()
    channel.setMethodCallHandler(nil)
    for observer in observers { NotificationCenter.default.removeObserver(observer) }
    observers.removeAll()
    for observer in workspaceObservers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
    workspaceObservers.removeAll()
  }

  deinit { shutdown() }
}
