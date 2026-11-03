import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  private let lockSize = NSSize(width: 540, height: 700)
  private let vaultSize = NSSize(width: 1120, height: 740)

  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    self.contentViewController = flutterViewController

    RegisterGeneratedPlugins(registry: flutterViewController)

    let windowChannel = FlutterMethodChannel(
      name: "nook/window",
      binaryMessenger: flutterViewController.engine.binaryMessenger
    )
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

    super.awakeFromNib()

    // App 每次都先進鎖定畫面；解鎖後由 Flutter channel 展開成保險庫尺寸。
    // 預設外觀是深色，先設好免得第一幀閃一下白色標題列。
    self.appearance = NSAppearance(named: .darkAqua)
    self.minSize = NSSize(width: 500, height: 640)
    DispatchQueue.main.async {
      self.setContentSize(self.lockSize)
      self.center()
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
