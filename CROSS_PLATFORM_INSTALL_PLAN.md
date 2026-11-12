# Nook 桌面版跨平台安裝計畫

狀態：實作中。程式碼、runner、封裝腳本已完成；Windows 安裝器（Inno Setup）、Windows／Linux 建置 workflow 與草稿 Release workflow 已寫好但**都還沒在 GitHub 上跑過**；Linux amd64 `.deb` 已在原生 x86_64 的容器內建置與安裝驗證；Linux 中文字型已修正；Windows 尚未在 Windows 上建置或驗證，Linux（amd64／arm64）僅有容器內驗證、沒有實體桌面驗收（見文末「進度紀錄」）。更新：2026-11-11。

## 目標與首批範圍

讓使用者不必安裝 Flutter、也不必自己建置，**下載安裝檔**就能在 macOS、Windows 與 Linux 安裝、升級並使用 Nook（Windows：安裝器 `.exe`；Linux：`.deb`；各附 SHA256）。首批驗收環境暫定 Windows 11 x64 與 Ubuntu 24.04 x64；其他系統版本、CPU 架構和 Linux 發行版要經實測後才列入支援。iOS、Android、跨機同步與自動搬移保險庫不在這次範圍內。

第一版 Windows／Linux 以主密碼解鎖為完整功能基線。保留現有 `vault.json`、`.item` 與 `SM01` 加密格式；跨系統搬移以複製整個 `vault/` 目錄為起點，不自動改寫原始資料。快速解鎖須另經安全設計與平台測試才能加入。

## 已確認的現況

- 專案的 `.metadata` 只記錄 macOS 平台；目前沒有 `windows/` 或 `linux/` runner。[安裝腳本](scripts/install.sh)只建置 macOS，並安裝到 `/Applications`。
- [macOS 視窗實作](macos/Runner/MainFlutterWindow.swift)負責鎖定／保險庫視窗尺寸、標題列外觀、狀態列收合與 `windowVisible` 通知；[Dart 端](lib/main.dart)透過 `nook/window` 通道呼叫它。
- [快速解鎖](lib/services/biometric_gate.dart)使用 `MacOsOptions`、Touch ID 與 Keychain；[設定介面](lib/ui/settings_sheet.dart)也有 macOS 專用文案。
- [保險庫路徑](lib/app/app_state.dart)取自 `getApplicationSupportDirectory()`，再附加 `vault`；跨平台資料夾名稱與備份／還原步驟仍需實機驗證。
- [macOS Release entitlement](macos/Runner/Release.entitlements)啟用 App Sandbox；這項設定不會自動套用到 Windows 或 Linux。

Flutter 官方提供替既有專案加入桌面平台的做法，以及 Windows、Linux 的建置與發行說明。這只證明可建立平台骨架，不代表本專案已可在兩個平台安裝。

## 實作順序

### 1. 建立可重複的基準

- 固定 Flutter／Dart 與 `pubspec.lock` 的版本；記錄 macOS 現有測試、`flutter analyze` 和 Release 建置結果。
- 用測試資料建立保險庫樣本，涵蓋建立、解鎖、項目讀寫、換主密碼、備份還原與損毀檔處理。不得使用真實機密作測試資料。
- 決定 Windows／Linux 的應用程式識別名稱、資料目錄與測試矩陣，避免日後改名造成使用者誤以為資料遺失。

**完成條件：**基準檢查可重跑；測試保險庫有可驗證的備份，且 macOS 能還原並解鎖。

### 2. 先完成 Windows 主密碼版

- 在 Windows 開發環境產生 `windows/` runner；保留既有 macOS runner，設定 Nook 的名稱、圖示與版本。
- 將視窗尺寸／外觀通道改為可分平台處理；先明定 Windows 關窗後退出、重新啟動後上鎖，避免尚未完成的常駐背景行為。
- 調整平台專用文案；Windows 第一版不顯示 Touch ID／Keychain 選項。檢查路徑組合、檔案權限與備份位置。
- 在 Windows 實機跑建立、重啟、解鎖、編輯、剪貼簿清除、自動上鎖與跨平台測試保險庫還原。

**完成條件：**`flutter analyze`、`flutter test`、`flutter build windows --release` 通過；在乾淨的 Windows 測試機上，主密碼流程與既有加密檔格式可用。

### 3. 交付 Windows 安裝包

- 內測先封裝完整 Release 目錄為 ZIP，不可只交付 `.exe`；確認所需 DLL、資料目錄與 Visual C++ runtime 已備妥。
- 給使用者下載的是 Inno Setup 7 安裝器 `Nook-<版本>-windows-x64-setup.exe`（`windows/installer/nook.iss`，
  由 `scripts/package_windows.ps1` 產生，與 ZIP 收同一份排好的目錄）：裝給目前使用者（不需管理員）、開始功能表捷徑、
  可選桌面捷徑、固定 AppId 供升級辨識、解除安裝不碰 `%APPDATA%` 的保險庫。不選 MSIX：MSIX 必須簽章才能安裝，
  目前沒有憑證；MSIX 的檔案系統虛擬化也會改變 `%APPDATA%` 的實際位置，需另外驗證資料搬移。
- 可重現建置：`.github/workflows/windows-installer.yml`（PR／手動觸發、windows-2022、Flutter 3.41.9、
  Inno Setup 7.1.1 以 SHA256 釘版），跑 analyze／test、封裝，再用 `scripts/smoke_test_windows_installer.ps1`
  實際安裝、啟動、覆蓋安裝、解除安裝，最後上傳安裝器、ZIP 與 `SHA256SUMS-windows.txt`（Artifacts，需登入）。
- 公開下載：`.github/workflows/release-draft.yml` 重建並比對雜湊後建立**草稿** GitHub Release；驗收後由人發佈
  （流程見 README「發行流程（維護者）」）。
- 簽章：目前沒有程式碼簽章憑證，安裝器與 `nook.exe` 都未簽，SmartScreen 會警告；README 寫明「其他資訊 →
  仍要執行」與雜湊比對步驟。有憑證後在 `nook.iss` 加 `SignTool`，憑證只放在 CI secret，不進 repo。

**完成條件：**workflow 在 Windows runner 上全綠（含安裝冒煙測試）；未裝 Flutter 的乾淨 Windows 11 x64 機器用下載的
安裝器能安裝、啟動、從上一版升級、解除安裝後資料保留；升級前後以同一主密碼解鎖同一保險庫；
安裝器已發佈在不需登入的 GitHub Release 上，附 `SHA256SUMS.txt`。

### 4. 完成 Linux 主密碼版與安裝包

- 在 Linux 開發環境產生 `linux/` runner，設定名稱、圖示、桌面啟動項與關窗行為。
- 第一版不提供生物辨識。雖然快速解鎖停用，目前鎖定的 `flutter_secure_storage_linux` 仍要求建置時有 `libsecret` 開發套件、執行時有其 runtime；將必要套件列入建置與安裝依賴，並在目標桌面環境驗證。
- 建立 Ubuntu `.deb`，檢查可執行檔、`lib/`、`data/` 與系統函式庫依賴；完成同一套主密碼、資料搬移與升級測試。

**完成條件：**`flutter analyze`、`flutter test`、`flutter build linux --release` 通過；未裝 Flutter 的乾淨 Ubuntu 測試機能安裝、啟動、升級及還原測試保險庫。

### 5. 安全與發行驗收

- 三平台檢查關窗、切換應用程式、閒置、睡眠／喚醒、鎖定後清除畫面與剪貼簿、保險庫檔案權限及升級資料保留。
- 分平台驗證網路行為及安全控制，修正 README 的適用範圍；不得把 macOS 沙盒的「無網路權限」宣稱直接沿用至 Windows／Linux。
- 發行包只收必要檔案，排除 `build/` 中間產物、測試保險庫、快取與簽章私鑰；記錄可重現的建置和安裝步驟。

**完成條件：**上述檢查有結果紀錄；三平台安裝包都通過乾淨環境測試，且 README 的支援範圍與實際驗收一致。

## 延後處理：快速解鎖

`local_auth` 目前列出 Windows 支援，但沒有 Linux 實作。Windows Hello 與安全儲存套件是兩個不同介面；僅在讀取已儲存 DEK 之後顯示 Hello 驗證，不能逕稱 DEK 受到 Hello 綁定保護。要先定義威脅模型、驗證金鑰保護方式與失敗時的主密碼回退，再決定是否加入 Windows 快速解鎖。Linux 也要先選定可信的驗證與金鑰儲存方案。

## 待確認的產品決策

1. 首批 Linux 是否以 Ubuntu 24.04 x64 為唯一正式支援環境；其他發行版先標為未驗證。
2. ~~Windows 正式發行採 MSIX 或其他安裝器~~：先採 Inno Setup 安裝器（未簽章）；公開下載通路是 GitHub Releases（草稿 → 驗收 → 人工發佈）。仍待決定：程式碼簽章憑證由誰申請與管理。
3. Windows／Linux 是否需要像 macOS 一樣關窗後常駐系統列；本計畫的第一版採關窗退出。
4. 「無資料離開本機」要表述為應用程式行為，還是要求作業系統層級的網路隔離；後者需另外設計並驗證。

## 參考資料

- [Flutter：Desktop support](https://docs.flutter.dev/platform-integration/desktop)
- [Flutter：Building Windows apps](https://docs.flutter.dev/platform-integration/windows/building)
- [Flutter：Build Linux apps](https://docs.flutter.dev/platform-integration/linux/building)
- [local_auth 支援平台](https://pub.dev/packages/local_auth)
- [flutter_secure_storage Linux 需求](https://pub.dev/packages/flutter_secure_storage_linux)

## 進度紀錄

### 2026-11-10

已完成（程式碼層級）：

- 新增 `windows/`、`linux/` runner（Flutter 3.41.9 範本），名稱 Nook、執行檔 `nook`、Linux 應用程式 ID `tw.com.jetopto.nook`、Windows 版本資訊 CompanyName `tw.com.jetopto`／ProductName `Nook`；初始視窗 1120×740；關窗即結束程式。
- 資料目錄（依 path_provider 規則）：Windows `%APPDATA%\tw.com.jetopto\Nook\vault`、Linux `~/.local/share/tw.com.jetopto.nook/vault`。Linux 開啟時把 `vault/` 收成 0700。
- `lib/app/platform_profile.dart` 集中平台差異：快捷鍵 macOS 用 ⌘、其他用 Ctrl；`nook/window` 通道只在 macOS 呼叫；快速解鎖只在 macOS 開啟，Windows／Linux 不顯示選項、不碰 local_auth 與安全儲存。
- Windows 圖示 `.ico` 由 `design/render_icon.swift` 各尺寸獨立重畫後以 `design/pack_ico.py` 打包；Linux 圖示沿用 macOS asset catalog 的 PNG。
- 修正 `VaultStore.saveSettings` 沿用記憶體中舊 KDF 參數的問題（先後執行的回歸測試；這不能證明並發安全，並發問題見 2026-11-11 的單一執行個體鎖）。
- 封裝：`scripts/package_windows.ps1`（ZIP，含 VC++ runtime DLL）、`scripts/package_linux.sh`（`.deb`，安裝到 `/opt/nook`）。
- 測試：`test/platform_test.dart`（平台分流）、`test/vault_fixture_test.dart`＋凍結樣本 `test/fixtures/vault_v1`（SM01 格式相容、複製整個 vault/ 後解鎖、權限）。`.gitattributes` 讓樣本在 Windows checkout 時不被改換行。

已驗證：

- macOS（開發機）：`flutter analyze` 無問題、`flutter test` 44 項全過。
- macOS Release 建置：**未驗證**。這次的執行環境裡 xcodebuild 無法讀取 workspace（CoreSimulator 連線被拒），macOS 原生檔案沒有修改。
- Windows：`package_windows.ps1` 只做過 PowerShell 語法剖析（0 錯誤）。**沒有**在 Windows 上跑過 `flutter build windows`、測試或安裝。
- Linux（Docker 容器，非實體桌面）：
  - Ubuntu 24.04 **arm64**（原生）：`flutter analyze` 無問題、`flutter test` 44 項全過（含只在 Linux 實際執行的 0700 權限測試）、`flutter build linux --release` 成功、`scripts/package_linux.sh` 產出 `nook_1.0.0+1_arm64.deb`。
  - 另一個乾淨的 Ubuntu 24.04 arm64 容器（沒有 Flutter）：`apt install` 該 `.deb` 成功；在 xvfb＋mesa 軟體算圖下實際啟動，畫出建立保險庫畫面；資料目錄確實建在 `~/.local/share/tw.com.jetopto.nook`；`apt remove` 後資料目錄保留。
  - 實測抓到並已修正：Linux 上 `boot()` 等待非同步 chmod 會讓 widget test 卡死（改 `Process.runSync`）；建置機少 `lld`；執行期缺 `libegl1`、`libgles2`（Flutter 引擎 dlopen，ldd 看不到）；沒有 CJK 字型時中文全變方塊（加 `Recommends: fonts-noto-cjk`）；外掛 `.so` 單獨跑 ldd 會誤報（改從執行檔解析）。
  - 補上 `libegl1`／`libgles2`／`fonts-noto-cjk` 之後的 `.deb` **沒有**重新產出並重測；啟動測試是手動加裝這兩個函式庫後做的，字型修正未經截圖確認。
  - **x64（首批目標）未完成**：Rosetta 模擬的 amd64 容器跑過 `flutter analyze` 與 43 項測試（當時的版本）皆通過，但 release 建置因缺 `lld` 失敗，補上後重跑因模擬過慢未完成。x64 的建置與安裝仍需在實體或原生 x64 環境驗證。

尚未完成的驗收（需要實機或資源）：

- Windows 11 x64：建置、`flutter test`、乾淨機器解壓執行、主密碼流程、升級保留資料、生命週期上鎖時機。
- Windows 正式安裝包：簽署的 MSIX 或安裝器，需要程式碼簽章憑證與發行通路決策（待確認決策 2）。
- Ubuntu 24.04 實體桌面：互動流程（建立、重開、解鎖、編輯、剪貼簿清除、自動上鎖、睡眠喚醒）、升級。
- 三平台安全驗收（第 5 階段）的實測紀錄。


### 2026-11-11（驗收回饋修正）

修正：

- **多執行個體寫壞保險庫**：新增 `lib/app/instance_lock.dart`。開啟時在應用程式支援目錄（`vault/` 上一層）
  獨占 `nook.lock`，拿不到就進 `VaultPhase.blocked`（「Nook 已經在執行中」），完全不讀寫保險庫；鎖檔開不了
  也一樣不開啟。鎖位置由應用程式 ID 決定，與安裝位置無關。POSIX 用 `open`＋`flock(LOCK_EX|LOCK_NB)`，
  Windows 用 dwShareMode=0 的 `CreateFileW`，都經 `dart:ffi`（`ffi` 由間接依賴改為直接依賴，版本不變）。
  - 第一版用 dart:io 的 `RandomAccessFile.lockSync`，單元測試全過，但 Linux release `.deb` 實測第二個執行個體
    照樣開得起來。gdb 抓到 GC finalizer（`dart::bin::File::~File` ← `Scavenger::MournWeakHandles`）把鎖檔 fd
    關掉，所以改成 GC 管不到的原始 fd／HANDLE。
  - `VaultStore` 同程序內的 `create`／`changePassword`／`saveSettings` 排隊執行（突變測試：拿掉排隊後，同時送出
    換主密碼與存設定，保險庫會變成解不開）；`_writeAtomic` 改用每次不同的暫存檔名，失敗時清掉。
- **權限收緊不實**：`restrictPermissions()` 檢查 chmod 退出碼，事後重新 stat 確認是 0700；失敗回 false、
  設 `permissionProblem`、寫 stderr，設定頁「資料」區顯示紅字。測試涵蓋非零退出碼、指令成功但權限沒變、
  找不到 chmod 三條失敗路徑，以及警告確實出現在設定頁。
- **設定標題與行為不一致**：Windows／Linux 標題改為「視窗最小化或隱藏時立刻上鎖」（程式只在 hidden／paused
  上鎖），macOS 維持原文。測試驗證 Windows／Linux 的 inactive 不鎖、hidden 才鎖。
- 「兩個執行個體同時開著」的回歸測試改名為它實際驗的事（先後執行、記憶體 KDF 過期），不再宣稱並發安全。

已驗證：

- macOS（開發機）：`flutter analyze` 無問題、`flutter test --concurrency=1` 59 項全過。
- Ubuntu 24.04 **arm64** 容器（原生）：`flutter analyze` 無問題、`flutter test --concurrency=1` 59 項全過、
  `flutter build linux --release`＋`scripts/package_linux.sh` 重新產出 `nook_1.0.0+1_arm64.deb`
  （Depends 含 `libegl1`、`libgles2`；Recommends `fonts-noto-cjk`）。
- 另一個乾淨的 Ubuntu 24.04 arm64 容器（沒有 Flutter，安裝前 libegl1／libgles2／GTK／libsecret／CJK 字型
  都沒有）：只靠 `apt install ./nook_*.deb` 帶入依賴，`ldd` 無缺；xvfb＋mesa 軟體算圖下啟動成功，用假密碼
  建立保險庫後進入主畫面，`vault/` 為 0700，`nook.lock` 在 `vault/` 外面。
  - 單一執行個體：第一個從 `/usr/bin/nook` 啟動並持有 flock（`/proc/locks` 可見），把整個 `/opt/nook` 複製到
    `/tmp/nook-elsewhere` 再啟動，第二個停在「已經在執行」畫面。第一個以 SIGTERM 或 SIGKILL 結束後，
    再啟動都拿得到鎖、正常進入畫面。
  - `apt remove` 後資料目錄保留。

新發現的發行阻礙（同日稍後已修，見下一節）：

- **Linux 中文顯示成方塊**：乾淨容器裡已裝 `fonts-noto-cjk`、fontconfig 的 `fc-match 'sans-serif:lang=zh-tw'`
  解析得到 Noto Sans CJK TC，在 `C.UTF-8`、`zh_TW.UTF-8` 兩種 locale 下截圖，介面上的中文仍全是方塊（英文正常）。

仍未驗證：

- Windows 11 x64：沒有可用環境。`flutter build windows`、測試、安裝、`CreateFileW` 單一執行個體鎖、
  生命週期上鎖時機都**沒有**跑過。
- Linux **x64**（首批目標）與實體 Ubuntu 桌面：沒有跑過；以上都是 arm64 容器結果。
- macOS Release 建置與 macOS 上的單一執行個體鎖（只在 `flutter test` 下跑過 POSIX 路徑）。
- 網路磁碟家目錄上的檔案鎖行為。

### 2026-11-11（Linux 中文字型）

修正：

- `PlatformProfile.cjkFontFallback`：Linux 回傳 Noto Sans CJK TC／SC／JP，其他平台回空清單（macOS／Windows
  行為不變）。`AppTheme` 的兩組主題設為 `fontFamilyFallback`，等寬字 `monoFallback` 接在拉丁等寬字後面。
- 兩個自己指定整份 TextStyle、不會繼承主題的地方補上同一份備援：鎖定畫面主按鈕的 `ButtonStyle.textStyle`
  （第一次重打包後截圖發現「建立保險庫／解除鎖定」仍是方塊）、設定頁 `DropdownButton.style`
  （新測試抓到「5 分鐘／30 秒」）。
- `scripts/package_linux.sh`：`fonts-noto-cjk` 從 Recommends 移到 Depends。
- 測試：`test/platform_test.dart` 新增 Linux／macOS／Windows 的備援清單與主題套用檢查，以及 Linux 下掃過主畫面、
  設定、指令面板、新增選單、項目編輯器、鎖定畫面，所有含中文的 RichText 都要帶 Noto Sans CJK TC
  （突變檢查：拿掉按鈕的備援後，這個測試以「解除鎖定」失敗）。

已驗證：

- macOS（開發機）：`flutter analyze` 無問題、`flutter test --concurrency=1` 64 項全過。
- Ubuntu 24.04 **arm64** 建置容器：`flutter analyze` 無問題、`flutter test --concurrency=1` 64 項全過，
  重新產出 `nook_1.0.0+1_arm64.deb`（Depends 最後一項為 `fonts-noto-cjk`，沒有 Recommends）。
- 全新 Ubuntu 24.04 arm64 容器（安裝前沒有任何 CJK 字型、沒有 EGL／GLES／GTK／libsecret）：
  `apt-get install --no-install-recommends ./nook_*.deb` 成功，依賴自動帶入 `fonts-noto-cjk`、`fontconfig`、
  `libegl1`、`libgles2`、`libgtk-3-0t64`、`libsecret-1-0`；`ldd` 無缺。xvfb＋mesa 軟體算圖下啟動，截圖確認
  建立保險庫畫面、主畫面、設定對話框（含下拉選單）、「已經在執行」畫面、解鎖畫面的中文全部可讀（含主按鈕）。
- 同一輪：用假密碼建立保險庫，`vault/` 為 700；從 `/tmp/nook-elsewhere` 再啟動，第二個停在「已經在執行」，
  `/proc/locks` 顯示第一個程序對 `nook.lock` 的 flock；第一個被 SIGKILL 後，從另一位置重開拿到同一個 inode 的鎖、
  正常進入解鎖畫面。

仍未驗證：

- Windows 11 x64 與 Linux **x64**：都沒有跑過（Windows 的中文顯示也未確認）。
- 實體 Ubuntu 桌面（Wayland／X11 實際桌面環境、輸入法、HiDPI）：沒有跑過，以上都是 xvfb 容器截圖。
- 未逐一截圖每個對話框；`platform_test` 只靜態檢查上列畫面的文字樣式，沒涵蓋到的元件若自訂整份 TextStyle，
  仍可能漏掉備援。

### 2026-11-11（可下載的安裝檔）

目標修正：交付的是使用者可下載的安裝檔，不只是原始碼建置說明。

新增：

- `windows/installer/nook.iss`：Inno Setup 7 安裝器。`SetupArchitecture=x64`、`x64compatible`、Windows 10 以上；
  `PrivilegesRequired=lowest`（裝到 `%LOCALAPPDATA%\Programs\Nook`；裝給所有使用者只開放命令列 `/ALLUSERS`，
  避免同一台機器 HKCU／HKLM 各裝一份）；
  固定 AppId `{0B98D084-6C56-4575-8B63-54A36D8E034A}`；開始功能表捷徑＋可選桌面捷徑；升級前清掉舊版的 `data\`
  與 `*.dll` 避免殘留；`CloseApplications=yes`；不碰 `%APPDATA%`（`[UninstallDelete]` 刻意留空）；未簽章。
- `scripts/package_windows.ps1`：同一份排好的目錄產出安裝器與 ZIP（`-SkipInstaller`／`-SkipZip`），
  寫出 `dist\SHA256SUMS-windows.txt`；版本從 pubspec 取（`1.0.0+1` → 檔名 `1.0.0-1`、版本資訊 `1.0.0.1`）。
  ZIP 檔名也跟著從 `Nook-1.0.0+1-windows-x64.zip` 改成 `Nook-1.0.0-1-windows-x64.zip`。
- `scripts/smoke_test_windows_installer.ps1`：靜默安裝 → 檢查檔案、VC++ runtime、開始功能表捷徑、登錄 →
  啟動並等 `%APPDATA%\tw.com.jetopto\Nook\nook.lock` 出現 → 覆蓋安裝（可加 `-PreviousInstaller` 測上一版升級）→
  解除安裝 → 確認程式、捷徑、登錄都移除而資料目錄保留。已裝 Nook 的機器預設拒跑。
- `.github/workflows/windows-installer.yml`、`.github/workflows/linux-deb.yml`：都只有 `workflow_dispatch`、
  `contents: read`，產物只上傳成 workflow artifact（保留 30 天），不建立 Release、不簽章。Linux 那支在原生 x64 的
  ubuntu-24.04 runner 建 `amd64` `.deb`、檢查套件內容、寫 `SHA256SUMS-linux.txt`；不改 `scripts/package_linux.sh`。

已驗證（本機 macOS，沒有 Windows）：

- 兩個 workflow：`actionlint` 1.7.12 檢查 0 錯誤，Python `yaml.safe_load` 可解析。
- 另請一個獨立的審查 agent 對照 Inno Setup 7／PowerShell 官方文件讀過 `nook.iss` 與兩支 `.ps1`：沒有阻擋性問題；
  其指出的五項（解除安裝自我複製後的等待、ISCC 7 警告寫 stderr、版本號每段 ≤ 65535、per-user／all-users
  重複安裝、`ExitCode` 讀不到）已修正。這是閱讀審查，不是執行結果。
- Inno Setup 7.1.1 安裝檔（GitHub release `is-7_1_1`）下載後算出的 SHA256 已釘進 workflow；官方沒有公布雜湊，
  這只保證每次 CI 用到同一個檔案。

**沒有**驗證（不得宣稱可用）：

- `nook.iss` 沒有被 ISCC 編譯過；`package_windows.ps1`、`smoke_test_windows_installer.ps1` 沒有在任何 PowerShell
  上執行或剖析過（本機無 Windows／PowerShell／Wine 可用）。
- 兩個 workflow 都沒有在 GitHub 上跑過（依指示未 commit／push）。
- Windows 上的建置、安裝、啟動、升級、解除安裝、SmartScreen 流程全部未實測。

發行前的驗收關卡（依序）：

（此清單已由下一節「公開下載通路」的發行關卡取代。）

1. 手動觸發 `Windows installer` workflow 全綠（analyze、test、封裝、安裝冒煙測試）。
2. 下載 artifact，在乾淨、沒有 Flutter 的 Windows 11 x64 上比對 SHA256、執行安裝器，走過 SmartScreen；
   跑 `scripts\smoke_test_windows_installer.ps1`，再做 README「驗收關卡」第 5 項的人工流程。
3. 用上一版安裝器 → 新版安裝器測升級（`-PreviousInstaller`），升級後同一主密碼解鎖同一保險庫。
4. 手動觸發 `Linux deb` workflow，產出的 `amd64` `.deb` 在乾淨的 Ubuntu 24.04 x64 桌面安裝與互動驗收
   （與 jetubuntu 上另行進行的 amd64 驗證結果交叉比對）。
5. 以上都過了，才考慮建立 GitHub Release 並附上安裝檔與 SHA256SUMS；簽章問題在 Release 說明中寫明。

### 2026-11-11（公開下載通路與 Linux amd64 驗證）

修正：workflow 的 Artifacts 要登入 GitHub 才能下載，`workflow_dispatch` 也只能觸發預設分支上的 workflow 檔
（GitHub Docs：Downloading workflow artifacts、Manually running a workflow），所以只有 Artifacts 不符合
「使用者可下載的安裝檔」。公開下載點改為 GitHub Releases，並把發佈拆成必須由人明確操作的最後一步。

新增／修改：

- `.github/workflows/release-draft.yml`（新增）：只有 `workflow_dispatch`（輸入 tag 與是否 pre-release）。
  以 `workflow_call` 重用兩支建置 workflow（唯讀），在同一個 commit 上重建；`draft` job 是唯一有
  `contents: write` 的 job：檢查 tag 等於 `v` + pubspec 的 `X.Y.Z`、該 tag 沒有 release（含草稿）也沒有指向別的
  commit，下載產物、`sha256sum -c` 兩份校驗檔、確認檔案清單剛好是安裝器／ZIP／`.deb`，合併成 `SHA256SUMS.txt`，
  `gh release create --draft --target <commit>` 上傳，最後確認草稿上的資產名稱與 `SHA256SUMS.txt` 一致。
  `.deb` 上傳時改名為 `nook_<X.Y.Z-N>_amd64.deb`（GitHub 會改寫資產檔名的特殊字元，`+` 會讓校驗檔對不上；
  套件內版本不變）。公開發佈要人在網頁按 Publish release 或 `gh release edit <tag> --draft=false`。
- `windows-installer.yml`、`linux-deb.yml`：加上 `pull_request`（限相關路徑）與 `workflow_call` 觸發，PR 分支上就能
  先跑建置；權限仍是 `contents: read`。concurrency 群組改用固定前綴（被呼叫時 `github.workflow` 是呼叫端名字，
  兩支會互相取消）。
- `linux-deb.yml`：建置依賴加 `llvm-18`；封裝後在乾淨的 `ubuntu:24.04` 容器裡 `apt-get install --no-install-recommends`
  該 `.deb` 並檢查 `ldd` 無缺。
- `scripts/package_linux.sh` 只改開頭註解的建置依賴清單（加 `llvm-18`），程式邏輯沒動。README 的 Linux 建置依賴同步。
- README：「下載安裝檔」改寫成 Releases 下載與雜湊比對，加「發行流程（維護者）」三步驟；平台表與 Linux 驗收狀態
  分開寫容器結果與實體桌面。

Linux amd64 驗證（由 Codex 在 jetubuntu 進行，原生 x86_64 主機上的 Ubuntu 24.04 **容器**，非實體桌面）：

- 第一次 release 建置失敗：`Failed to find any of [llvm-ar, ar] in LocalDirectory: '/usr/lib/llvm-18/bin'`；
  建置依賴加上 `llvm-18` 後成功。
- `flutter analyze` 無問題、`flutter test` 64 項全過；產出 `dist/nook_1.0.0+1_amd64.deb`。
- 乾淨容器 `apt install --no-install-recommends` 安裝成功；啟動、用假密碼建立保險庫、第二個執行個體被擋下、
  第一個被 SIGKILL 後能恢復、`apt remove` 後保險庫保留。
- 這份結果是轉述 Codex 的回報，本 session 沒有重跑。

本 session 的檢查（本機 macOS）：

- `actionlint` 1.7.12（含 shellcheck）檢查三個 workflow：0 錯誤。
- 把 `release-draft.yml` 的 `draft` job 裡的 shell 步驟抽出來，以假檔案在本機 bash 跑過：tag 與 pubspec 一致／不一致／
  格式錯誤；校驗檔正確、`.deb` 或 `.exe` 被竄改、多出未預期的檔案、缺檔；說明文字產生。結果都符合預期。
  `gh release create`／`gh api` 與 GitHub 上的實際行為**沒有**測（不得在本機建立 release）。
- 另請獨立審查 agent 讀過三個 workflow：沒有阻擋性問題；其指出的五項已修正——草稿只能從 `main` 建（`guard` job）、
  既有 release 改用 `gh api --paginate` 列舉（API 失敗即中止，不當成「沒有」）、任何同名 tag 都拒絕、
  寫入權限的 checkout 不保留憑證、PR 路徑過濾補上 `SecureManage_UI_Assets/**`、`.gitattributes` 與 `.deb` 圖示來源。
  排隊中的 `Release draft` 只保留一個（GitHub concurrency 行為），已寫在 workflow 註解。這是閱讀審查，不是執行結果。

公開下載前的發行關卡（依序；取代上一節的清單）：

1. PR 上的 `Windows installer` 與 `Linux deb` 全綠（Windows 含安裝冒煙測試；Linux 含乾淨容器安裝）。
   這是 Windows 版**第一次**真的在 Windows 上建置與安裝，失敗就修到綠為止。
2. 從 PR 的 Artifacts 下載，在乾淨的 Windows 11 x64 實機上比對 SHA256、走過 SmartScreen、跑
   `scripts\smoke_test_windows_installer.ps1`，再做 README「驗收關卡」第 5 項的人工流程。
3. Ubuntu 24.04 x64 **實體桌面**安裝同一份 `.deb`，做建立／重開／解鎖／編輯／剪貼簿清除／自動上鎖／睡眠喚醒／
   輸入法與 HiDPI 檢查。
4. 合併進 `main`，手動執行 `Release draft`（例如 tag `v1.0.0`）→ 產生草稿。
5. 從草稿下載資產，`sha256sum -c --ignore-missing SHA256SUMS.txt`，抽驗安裝（至少 Windows 安裝器一次，有上一版就測
   `-PreviousInstaller` 升級），把驗收結果與「未簽章」說明寫進 release 說明。
6. 由人明確發佈（Publish release／`gh release edit <tag> --draft=false`）。在這之前沒有任何公開下載。

### 2026-11-11（PR 上的安裝包驗收）

- [PR #1](https://github.com/SheldonChangL/nook/pull/1) 已建立，Windows 與 Linux 工作流在 commit `49aa544` 上全綠。
- [Windows run 42965527686](https://github.com/SheldonChangL/nook/actions/runs/42965527686)：Windows Server 2022 上 `flutter analyze` 通過、58 項測試通過（6 項略過）、`flutter build windows --release` 成功；產出 `Nook-1.0.0-1-windows-x64-setup.exe` 與 ZIP。冒煙測試實際安裝、啟動、覆蓋安裝、解除安裝，確認程式和捷徑移除、資料目錄保留。下載 artifact 後在本機比對 SHA256，兩個檔案皆通過。
- [Linux run 42965527828](https://github.com/SheldonChangL/nook/actions/runs/42965527828)：Ubuntu 24.04 x64 上分析、測試、Release 建置、`.deb` 封裝與乾淨容器安裝全綠；下載後在本機比對 SHA256 通過。
- 工作流 artifact 供驗收使用，公開 Releases 仍未建立。Windows 11 x64 與 Ubuntu 24.04 x64 實體桌面的人機互動驗收尚未完成；依上述發行關卡，不能宣稱正式支援或公開發佈。

### 2026-11-11（Ubuntu 22.04 相容性：建置改在 22.04 容器）

起因：把 PR #1 產出的 `.deb`（Ubuntu 24.04 runner 上建）裝到 jetubuntu（Ubuntu 22.04.5、glibc 2.35）後
`apt` 裝得上去，執行卻是：

```
/opt/nook/nook: /lib/x86_64-linux-gnu/libc.so.6: version `GLIBC_2.38' not found
  (required by /opt/nook/lib/libflutter_secure_storage_linux_plugin.so)
```

逐檔檢查 bundle 的符號版本需求，只有 `libflutter_secure_storage_linux_plugin.so` 要 GLIBC_2.38
（`nook` 2.34、`libflutter_linux_gtk.so` 2.18），卡住的符號是 `__isoc23_strtoll` / `__isoc23_strtoull` ——
不是外掛真的用到新功能，是 glibc 2.38 以上的 header 把 `strtoll` 重導過去，純粹是「在哪台機器編的」留下的痕跡。
`.deb` 的 `Depends` 當時只寫 `libc6` 沒有版本下限（control 是手寫的，不是 `dpkg-shlibdeps` 產生），
所以 apt 無從擋起，裝完才在啟動時掛掉。`package_linux.sh` 原本的 `ldd` 檢查抓不到：它只驗「函式庫找不到」，
而且是在 24.04 的建置機上跑的。

修正（支援範圍定為 Ubuntu 22.04 以上）：

- `linux/packaging/build.Dockerfile`（新增）：Ubuntu 22.04 + Flutter 3.41.9 的建置映像。
  刻意不裝 JDK —— 相依樹裡的 `jni`（`local_auth` 帶進來的 FFI 外掛）在有 JDK 的建置機上會多編一個
  `lib/libdartjni.so` 進 bundle（24.04 那版就有），但 Linux 上從來不會載入它，`native_assets.json` 也是空的 `{}`；
  裝 `default-jdk` 實測也不會產出。重點是不要讓「建置機剛好有沒有 Java」決定套件內容。
- `scripts/build_linux_container.sh`（新增）：在該映像裡跑打包，或跑任意指令（CI 用它跑 analyze／test）。
- `scripts/package_linux.sh`：用 `objdump -T` 算出產物實際需要的 glibc 版本，寫進 `Depends: libc6 (>= X)`；
  超過基線 2.35（Ubuntu 22.04）就直接讓打包失敗，不留下「裝得上去但開不起來」的套件。
  `NOOK_GLIBC_BASELINE` 可覆寫。建置依賴註解的 `llvm-18` 改成「版本跟 clang 對齊」（22.04 是 `llvm`）。
- `.github/workflows/linux-deb.yml`：analyze／test／建置全部改在 22.04 容器裡跑（不再用
  `subosito/flutter-action` 與 host 上的 apt 依賴）；封裝後檢查 `Depends` 的 `libc6` 下限不超過 2.35；
  乾淨安裝測試從只測 ubuntu:24.04 擴成 ubuntu:22.04 與 ubuntu:24.04 各一輪 ——
  glibc 符號版本不合時 `ldd` 也會印「not found」，所以 22.04 那輪正是這次問題的回歸測試。
- README：平台表、下載表、Linux 驗收狀態與建置章節同步。

本次實測（在 jetubuntu 上，原生 x86_64 的 Ubuntu 22.04.5 主機）：

- 22.04 容器裡 `flutter analyze` 無問題、`flutter test` 64 項全過。
- `scripts/build_linux_container.sh` 產出 `dist/nook_1.0.0+1_amd64.deb`
  （sha256 `f18fc98dec4da36b74c8760b566d4870a494c9a5aa4647173463357358429674`），
  打包時印出「glibc 需求 2.34（基線 2.35）」，`Depends` 為 `libc6 (>= 2.34)`。
- 乾淨的 ubuntu:22.04 與 ubuntu:24.04 容器各 `apt install --no-install-recommends` 成功、`ldd` 無缺。
- 同一份 bundle 在 22.04 **實體桌面**（X11，`DISPLAY=:0`）啟動：視窗出現（WM class `tw.com.jetopto.nook`）、
  程序存活、無錯誤輸出。只驗到「開得起來」，互動流程未做。
- 建置途中踩到的坑：`build/native_assets/` 被手動刪掉、或 `.dart_tool/` 與 `build/` 狀態不一致時，
  `flutter build linux` 會以 `cmake_install.cmake: file INSTALL cannot find .../build/native_assets/linux` 中斷。
  乾淨的 checkout 不會遇到（CI 每次都是乾淨的）；本機重建前先 `flutter clean`。

還沒做：

- 新的 22.04 容器建置還沒在 GitHub Actions 上跑過（依指示未 commit／push）。
- 新套件還沒在 jetubuntu 上用 `apt install` 真的裝過（需要 sudo 密碼，本 session 沒有）；
  實機驗證是直接執行 bundle 完成的。
- 實體桌面的互動驗收（建立／解鎖／編輯／剪貼簿清除／自動上鎖／睡眠喚醒／輸入法／HiDPI／升級）仍待做。
- arm64 沒有在 22.04 上重新驗過。

### 2026-11-12（v1.0.0 公開為測試版）

- PR #1（安裝檔與 Ubuntu 22.04 建置）與 PR #2（跨機同步）合併進 `main` 之後，從 `main` 的 `548b14c` 手動執行
  [`Release draft`](https://github.com/SheldonChangL/nook/actions/runs/43135602153)（`tag=v1.0.0`、`prerelease=true`），
  guard／windows／linux／draft 四個 job 全綠。
- 下載草稿的三個安裝檔，與 `SHA256SUMS.txt` 比對全部相符；`nook_1.0.0-1_amd64.deb` 在乾淨的 `ubuntu:22.04`
  容器安裝成功（`libc6 (>= 2.34)`、`ldd` 無缺）；Windows ZIP 內含 `nook.exe` 與 `file_selector_windows_plugin.dll`。
- 草稿說明換成完整版本（下載與雜湊比對、macOS 不提供下載的原因、同步功能、未簽章、換主密碼不換 DEK、驗收狀態），
  經維護者同意後公開：[v1.0.0](https://github.com/SheldonChangL/nook/releases/tag/v1.0.0)，標為 pre-release，
  `v1.0.0` tag 在 `548b14c`。未登入狀態下四個資產都能下載，雜湊相符。
- 上一節的關卡中仍未完成、因此標為測試版而非正式版：Windows 11 x64 實體桌面驗收、Ubuntu 實體桌面的完整互動驗收、
  實際雲端硬碟程式（Dropbox／Google Drive／iCloud Drive）的同步實測、macOS 版的選資料夾與 bookmark 實際操作。
- `release-draft.yml` 自動產生的說明原本寫「Ubuntu 24.04」，改成「Ubuntu 22.04 以上」。
