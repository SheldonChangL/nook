import Cocoa
import FlutterMacOS

@main
class AppDelegate: FlutterAppDelegate {
  /// 狀態列上的 Nook。關掉視窗後 app 留在這裡，點一下再把視窗叫回來。
  private var statusItem: NSStatusItem?

  // FlutterAppDelegate 不會把 applicationDidFinishLaunching 轉給子類別（它用
  // NotificationCenter 自己分發），所以在 nib 載入完成時裝狀態列項目。
  override func awakeFromNib() {
    super.awakeFromNib()
    if statusItem == nil { installStatusItem() }
  }

  /// 關視窗不等於結束：視窗只是藏起來，app 常駐在狀態列。要真的結束走 ⌘Q 或狀態列選單。
  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return false
  }

  /// 點 Dock 圖示時把藏起來的視窗叫回來。
  override func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
    if !flag { showMainWindow() }
    return true
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }

  private static let statusAutosaveName = "nook"

  private func installStatusItem() {
    // 新加的狀態列項目預設排在最左邊，在有瀏海的機型上、選單列擠的時候
    // 會直接被系統藏掉。先登記一個靠右的預設位置（從右邊算起的點數），
    // 使用者之後 ⌘ 拖曳調整的位置照樣會存下來覆蓋這個預設。
    UserDefaults.standard.register(defaults: [
      "NSStatusItem Preferred Position \(Self.statusAutosaveName)": 260,
    ])
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    item.autosaveName = Self.statusAutosaveName
    guard let button = item.button else { return }
    // 用系統的鎖頭 template 圖，深淺色選單列都會自動反色。
    let image = NSImage(named: NSImage.lockLockedTemplateName)
    image?.isTemplate = true
    button.image = image
    button.toolTip = "Nook"
    // 左鍵直接開視窗，右鍵才出選單（選單裡有「結束」）。
    button.target = self
    button.action = #selector(statusItemClicked(_:))
    button.sendAction(on: [.leftMouseUp, .rightMouseUp])
    statusItem = item
  }

  @objc private func statusItemClicked(_ sender: Any?) {
    if NSApp.currentEvent?.type == .rightMouseUp {
      showStatusMenu()
    } else {
      showMainWindow()
    }
  }

  private func showStatusMenu() {
    let menu = NSMenu()
    let open = NSMenuItem(title: "打開 Nook", action: #selector(openFromMenu(_:)), keyEquivalent: "")
    open.target = self
    menu.addItem(open)
    menu.addItem(.separator())
    menu.addItem(withTitle: "結束 Nook", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    // 選單只在右鍵時臨時掛上去再拿掉；常駐掛著的話左鍵也會變成只彈選單。
    statusItem?.menu = menu
    statusItem?.button?.performClick(nil)
    statusItem?.menu = nil
  }

  @objc private func openFromMenu(_ sender: Any?) {
    showMainWindow()
  }

  @objc func showMainWindow() {
    guard let window = mainFlutterWindow else { return }
    window.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
  }
}
