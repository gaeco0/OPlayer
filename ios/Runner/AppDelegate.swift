import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate {
  private var filesChannel: FlutterMethodChannel?
  private var filesReady = false
  private var pendingFiles: [[String: String]] = []
  private var scopedURLs: [URL] = []

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    GeneratedPluginRegistrant.register(with: self)
    if let controller = window?.rootViewController as? FlutterViewController {
      let channel = FlutterMethodChannel(name: "oplayer/open_files", binaryMessenger: controller.binaryMessenger)
      filesChannel = channel
      channel.setMethodCallHandler { [weak self] call, result in
        guard let self = self else { return }
        guard call.method == "ready" else { result(FlutterMethodNotImplemented); return }
        self.filesReady = true
        result(self.pendingFiles)
        self.pendingFiles.removeAll()
      }
    }
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  override func application(_ app: UIApplication, open url: URL,
                            options: [UIApplication.OpenURLOptionsKey: Any] = [:]) -> Bool {
    guard url.isFileURL else { return super.application(app, open: url, options: options) }
    if url.startAccessingSecurityScopedResource() { scopedURLs.append(url) }
    let file = ["uri": url.absoluteString, "name": url.lastPathComponent]
    if filesReady { filesChannel?.invokeMethod("open", arguments: [file]) }
    else { pendingFiles.append(file) }
    return true
  }
}
