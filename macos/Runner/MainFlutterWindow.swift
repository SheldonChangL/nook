import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow, NSWindowDelegate {
  private let lockSize = NSSize(width: 540, height: 700)
  private let vaultSize = NSSize(width: 1120, height: 740)
  private var windowChannel: FlutterMethodChannel?

  /// 同步資料夾的存取權。沙盒裡的 app 只能碰使用者在選擇視窗裡親手選過的資料夾；
  /// 重開 app 後靠 security-scoped bookmark 拿回來，整個程序存活期間都不放。
  private var accessedFolders: [URL] = []

  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    self.contentViewController = flutterViewController

    RegisterGeneratedPlugins(registry: flutterViewController)

    let windowChannel = FlutterMethodChannel(
      name: "nook/window",
      binaryMessenger: flutterViewController.engine.binaryMessenger
    )
    self.windowChannel = windowChannel
    windowChannel.setMethodCallHandler { [weak self] call, result in
      switch (call.method, call.arguments as? String) {
      case ("setMode", let mode?):
        self?.setWindowMode(mode)
        result(nil)
      case ("setAppearance", let appearance?):
        // 鎖定畫面預設深色，標題列跟著 Flutter 的深淺色設定，不跟系統。
        self?.appearance = NSAppearance(named: appearance == "dark" ? .darkAqua : .aqua)
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }

    let folderChannel = FlutterMethodChannel(
      name: "nook/folder",
      binaryMessenger: flutterViewController.engine.binaryMessenger
    )
    folderChannel.setMethodCallHandler { [weak self] call, result in
      guard let self = self else { return result(nil) }
      switch call.method {
      case "pick":
        self.pickFolder(prompt: call.arguments as? String ?? "", result: result)
      case "restore":
        self.restoreFolder(bookmark: call.arguments as? String, result: result)
      default:
        result(FlutterMethodNotImplemented)
      }
    }

    super.awakeFromNib()

    // 紅色關閉鈕只把視窗藏起來，app 留在狀態列；見 AppDelegate。
    self.delegate = self

    // App 每次都先進鎖定畫面；解鎖後由 Flutter channel 展開成保險庫尺寸。
    // 預設外觀是深色，先設好免得第一幀閃一下白色標題列。
    self.appearance = NSAppearance(named: .darkAqua)
    self.minSize = NSSize(width: 500, height: 640)
    DispatchQueue.main.async {
      self.setContentSize(self.lockSize)
      self.center()
    }
  }

  func windowShouldClose(_ sender: NSWindow) -> Bool {
    hideToStatusBar()
    return false
  }

  /// 收進狀態列：視窗藏起來、Dock 圖示一起收掉，只留狀態列那個鎖頭。
  func hideToStatusBar() {
    orderOut(nil)
    NSApp.setActivationPolicy(.accessory)
    windowChannel?.invokeMethod("windowVisible", arguments: false)
  }

  /// 從狀態列開回來：先放回 Dock，再帶視窗到最前面。
  /// 切回 regular 之後同一個 run loop 內 activate 不一定生效，所以延後一拍。
  func showFromStatusBar() {
    NSApp.setActivationPolicy(.regular)
    DispatchQueue.main.async {
      self.makeKeyAndOrderFront(nil)
      NSApp.activate(ignoringOtherApps: true)
      self.windowChannel?.invokeMethod("windowVisible", arguments: true)
    }
  }

  /// 讓使用者選同步資料夾，順便做一個 security-scoped bookmark 給下次開機用。
  /// 選完的當下這個程序就有權限了（沙盒對使用者選的路徑開例外），不用另外 start。
  private func pickFolder(prompt: String, result: @escaping FlutterResult) {
    let panel = NSOpenPanel()
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.allowsMultipleSelection = false
    panel.canCreateDirectories = true
    panel.prompt = "選擇"
    panel.message = prompt
    panel.beginSheetModal(for: self) { response in
      guard response == .OK, let url = panel.url else {
        result(nil)
        return
      }
      do {
        let bookmark = try url.bookmarkData(
          options: [.withSecurityScope],
          includingResourceValuesForKeys: nil,
          relativeTo: nil
        )
        result(["path": url.path, "bookmark": bookmark.base64EncodedString()])
      } catch {
        result(FlutterError(
          code: "bookmark",
          message: error.localizedDescription,
          details: nil
        ))
      }
    }
  }

  /// 開機時用存下來的 bookmark 拿回同步資料夾的存取權。資料夾被搬走或改名時
  /// bookmark 會跟著找到新位置，這時順便換一個新的 bookmark 回去存。
  private func restoreFolder(bookmark: String?, result: @escaping FlutterResult) {
    guard let bookmark = bookmark, let data = Data(base64Encoded: bookmark) else {
      result(nil)
      return
    }
    do {
      var stale = false
      let url = try URL(
        resolvingBookmarkData: data,
        options: [.withSecurityScope],
        relativeTo: nil,
        bookmarkDataIsStale: &stale
      )
      guard url.startAccessingSecurityScopedResource() else {
        result(FlutterError(code: "access", message: "macOS 拒絕存取這個資料夾", details: nil))
        return
      }
      accessedFolders.append(url)
      var out: [String: Any] = ["path": url.path]
      if stale, let fresh = try? url.bookmarkData(
        options: [.withSecurityScope],
        includingResourceValuesForKeys: nil,
        relativeTo: nil
      ) {
        out["bookmark"] = fresh.base64EncodedString()
      }
      result(out)
    } catch {
      result(FlutterError(code: "resolve", message: error.localizedDescription, details: nil))
    }
  }

  private func setWindowMode(_ mode: String) {
    let targetSize: NSSize
    let targetMinimum: NSSize

    switch mode {
    case "lock":
      targetSize = lockSize
      targetMinimum = NSSize(width: 500, height: 640)
    case "vault":
      targetSize = vaultSize
      targetMinimum = NSSize(width: 880, height: 600)
    default:
      return
    }

    minSize = targetMinimum
    let oldCenter = NSPoint(x: frame.midX, y: frame.midY)
    var targetFrame = frameRect(forContentRect: NSRect(origin: .zero, size: targetSize))
    targetFrame.origin = NSPoint(
      x: oldCenter.x - targetFrame.width / 2,
      y: oldCenter.y - targetFrame.height / 2
    )
    setFrame(targetFrame, display: true, animate: true)
  }
}
