import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    self.contentViewController = flutterViewController

    RegisterGeneratedPlugins(registry: flutterViewController)

    super.awakeFromNib()

    // 側邊欄加清單加詳情面板，預設的 800 寬太擠。
    // 在 awakeFromNib 當下設尺寸會被之後的流程改掉，所以排到下一個 run loop
    // 週期再設。
    self.minSize = NSSize(width: 880, height: 600)
    DispatchQueue.main.async {
      self.setContentSize(NSSize(width: 1120, height: 740))
      self.center()
    }
  }
}
