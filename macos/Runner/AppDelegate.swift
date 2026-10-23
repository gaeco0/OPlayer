import Cocoa
import FlutterMacOS

@main
class AppDelegate: FlutterAppDelegate {
  private var filesChannel: FlutterMethodChannel?
  private var pendingFiles: [[String: String]] = []
  private var filesReady = false
  private var scopedURLs: [URL] = []

  func configureOpenFiles(_ messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(name: "oplayer/open_files", binaryMessenger: messenger)
    filesChannel = channel
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self = self else { return }
      guard call.method == "ready" else { result(FlutterMethodNotImplemented); return }
      self.filesReady = true
      result(self.pendingFiles)
      self.pendingFiles.removeAll()
    }
  }

  override func application(_ sender: NSApplication, open urls: [URL]) {
    let documents = urls.filter { $0.isFileURL }
    let other = urls.filter { !$0.isFileURL }
    if !other.isEmpty { super.application(sender, open: other) }
    let files = documents.map { url -> [String: String] in
      if url.startAccessingSecurityScopedResource() { scopedURLs.append(url) }
      return ["uri": url.absoluteString, "name": url.lastPathComponent]
    }
    if filesReady { filesChannel?.invokeMethod("open", arguments: files) }
    else { pendingFiles.append(contentsOf: files) }
  }

  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return true
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }
}
