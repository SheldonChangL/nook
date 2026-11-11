# Nook

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Ko-fi](https://img.shields.io/badge/Ko--fi-%E8%AB%8B%E6%88%91%E5%96%9D%E6%9D%AF%E5%92%96%E5%95%A1-FF5E5B?logo=ko-fi&logoColor=white)](https://ko-fi.com/sheldonchang)

本機用的機密資料管理工具。管三類東西：

| 類型 | 存什麼 |
|---|---|
| **金鑰** | SSH 私鑰、API token、憑證。含 passphrase、演算法標記 |
| **帳號** | 服務帳號密碼，含網址、使用者名稱、備註 |
| **主機 / VM** | 位址、port、登入帳號、跳板機、sudo 密碼、環境變數，可引用某把金鑰 |

桌面 app（Flutter）。macOS 是主要平台；Windows 與 Linux 版已有可建置的程式碼與封裝腳本，
只提供主密碼解鎖，支援範圍與驗證狀態見下面「[平台支援](#平台支援)」。

> 這個 app 原本叫 SecureManage，後來改名為 Nook，bundle identifier 也一併從
> `tw.com.jetopto.securemanage` 換成 `tw.com.jetopto.nook`。
>
> 沙盒 app 的資料目錄是跟著 bundle identifier 走的，所以換了之後新版會看到一個
> 空的保險庫 —— 舊資料還在舊容器裡，只是 app 找不到。搬過去用：
>
> ```bash
> ./scripts/migrate_container.sh
> ```
>
> 那支是「複製」不是「移動」，舊容器原封不動留著當備份，確認新的能解鎖之後
> 再自己刪。
>
> 有一樣東西**沒有**跟著改：加密檔的檔頭 magic 仍然是 `SM01`。那四個位元組寫在
> 每個 `.item` 檔的最前面，改了既有項目就全部解不開。
**程式本身沒有任何對外連線**，保險庫只寫在本機。在 macOS 上這件事另外由作業系統擋著：
Release 版的 entitlements 裡沒有任何網路權限。Windows 與 Linux 沒有對應的沙盒，
「不連網」只是應用程式的行為，不是作業系統層級的保證。

## 平台支援

| | macOS | Windows | Linux |
|---|---|---|---|
| 主密碼解鎖、項目讀寫、自動上鎖、剪貼簿清除 | ✓ | ✓ | ✓ |
| 快速解鎖 | Touch ID（預設關閉） | 不提供 | 不提供 |
| 關閉視窗 | 收進狀態列 | 結束程式 | 結束程式 |
| 快捷鍵修飾鍵 | `⌘` | `Ctrl` | `Ctrl` |
| 安裝方式 | `scripts/install.sh` | 安裝器 `Nook-<版本>-windows-x64-setup.exe`（另有內測 ZIP） | `.deb` |
| 下載 | 無（自己在 Mac 上建置） | [Releases](https://github.com/SheldonChangL/nook/releases)（**尚未發佈**，見下方） | [Releases](https://github.com/SheldonChangL/nook/releases)（**尚未發佈**） |
| 安裝包怎麼建 | `scripts/install.sh` | [`Windows installer` workflow](.github/workflows/windows-installer.yml) 或 `scripts/package_windows.ps1` | [`Linux deb` workflow](.github/workflows/linux-deb.yml) 或 `scripts/build_linux_container.sh` |
| 程式碼簽章 | 本機 ad-hoc | **無**（SmartScreen 會警告） | 無（`.deb` 未簽） |
| 作業系統層級的網路隔離 | App Sandbox | 無 | 無 |
| 同時開多個執行個體 | 擋下（見下） | 擋下（見下） | 擋下（見下） |
| 驗收狀態 | 實機使用中 | Windows Server 2022 CI 已建置、安裝、啟動、重裝、解除安裝；**沒有** Windows 11 實體桌面驗收 | amd64 已在 Ubuntu 22.04 實體桌面啟動驗證；完整互動驗收仍未做，見下方 |

Windows 版的驗收狀態：2026-11-11 的 [PR #1](https://github.com/SheldonChangL/nook/pull/1) 在 Windows Server 2022 runner 通過 `flutter analyze`、58 項測試（另 6 項略過）、Release 建置及 Inno Setup 封裝；自動測試完成安裝、啟動、覆蓋安裝、解除安裝，並確認資料目錄保留。CI 產物的 SHA256 已在本機核對。Windows 11 實體桌面的中文顯示、主密碼操作、SmartScreen、睡眠喚醒與升級舊版本仍待驗收；目前尚未公開發佈。

Linux 版的驗收狀態：

- **支援範圍是 Ubuntu 22.04 以上**。2026-11-11 先踩到一次：在 Ubuntu 24.04 上編的 `.deb` 裝到
  Ubuntu 22.04 實機，`apt` 裝得上去，一開卻是 ``version `GLIBC_2.38' not found``。
  原因是 `flutter_secure_storage` 的外掛在 24.04 的 header 下被重導到 GLIBC_2.38 的 `__isoc23_strtoll`，
  而當時 `.deb` 的 `Depends` 只寫 `libc6` 沒有版本下限，apt 無從擋起。現在建置一律在 22.04 容器裡做，
  版本下限也會自動算出來寫進套件（見「[建置與安裝](#linuxubuntu-2204-以上-x64)」）。
- **amd64（首批目標）**：2026-11-11 在 Ubuntu 22.04 容器（`linux/packaging/build.Dockerfile`）裡
  `flutter analyze` 無問題、`flutter test` 64 項全過、`scripts/build_linux_container.sh` 產出
  `nook_1.0.0+1_amd64.deb`，`Depends` 為 `libc6 (>= 2.34)`。乾淨的 ubuntu:22.04 與 ubuntu:24.04 容器
  各用 `apt install --no-install-recommends` 安裝成功、`ldd` 無缺。
- **實體桌面**：同一份 bundle 在 Ubuntu 22.04 實機（X11）上啟動，視窗正常出現、無錯誤輸出。
  這只驗到「開得起來」。
- **較早的容器驗收（在 Ubuntu 24.04 上編的版本）**：乾淨容器裡啟動、用假密碼建立保險庫、第二個執行個體被擋下、
  第一個被 SIGKILL 後能重新取得鎖、`apt remove` 後保險庫保留；arm64 也跑過 analyze、test、release 建置、
  `.deb` 安裝與虛擬顯示器下的啟動與截圖。這些流程還沒有在 22.04 的新版套件上重跑。
- **還沒做**：實體 Ubuntu 桌面的互動驗收（建立／解鎖／編輯／剪貼簿清除／自動上鎖／睡眠喚醒／輸入法／HiDPI／
  從上一版升級）；22.04 容器建置也還沒在 GitHub Actions 上跑過。其他發行版都未驗證。

**Linux 的中文字型**：Flutter 在 Linux 上不會自己找到 CJK 字型（裝了 `fonts-noto-cjk`、fontconfig 也解析得到，
介面中文仍是方塊，實測）。所以 Linux 版主題明確把 Noto Sans CJK TC／SC／JP 列為字型備援
（`PlatformProfile.cjkFontFallback`），`.deb` 也把 `fonts-noto-cjk` 列為 **Depends**（不是 Recommends，
`--no-install-recommends` 才不會漏裝）。元件若自己指定整份 TextStyle（例如 `ButtonStyle.textStyle`、
`DropdownButton.style`），不會繼承主題的備援，要自己帶上；`test/platform_test.dart` 會掃過主畫面、設定、
指令面板、新增選單、編輯器與鎖定畫面，抓出沒帶備援的中文。2026-11-11 在全新 Ubuntu 24.04 arm64 容器裡用
`apt install --no-install-recommends` 裝 release `.deb`，截圖確認上述畫面的中文（含按鈕與下拉選單）都正常顯示。
macOS／Windows 不改，交給系統備援（Windows 未實機確認）。

**同一個使用者同時只能開一個 Nook。** `vault.json` 的寫入是「讀出 → 改 → 整份寫回」，兩個程序
真的重疊時，一邊換主密碼、另一邊存設定，就可能拿舊的 KDF 參數或被包住的 DEK 蓋掉新的。
所以開啟時會先在應用程式支援目錄（`vault/` 的上一層）獨占一個 `nook.lock`，拿不到就停在
「Nook 已經在執行中」畫面，完全不讀寫保險庫。

- 鎖檔位置跟保險庫一樣由應用程式 ID 決定，不看安裝位置；從兩個不同目錄啟動同一個 App，搶的是同一把鎖。
- 透過 `dart:ffi` 直接呼叫作業系統：POSIX 用 `open`＋`flock(LOCK_EX|LOCK_NB)`，Windows 用不共用的
  `CreateFileW`。程序結束或當掉時核心會自動釋放，不會有要手動刪的殘鎖。沒有用 dart:io 的
  `RandomAccessFile.lockSync`：Linux release 版實測，GC 的 finalizer 會把那個 fd 關掉、鎖跟著消失。
- 同一個程序裡的換主密碼與存設定也會排隊；暫存檔名每次都不同，不再共用固定的 `.tmp`。
- 跨程序互斥有測試另開真的程序驗證（`test/instance_lock_test.dart`）。Linux 另在容器裡用 `.deb` 安裝後，
  實際從兩個不同位置啟動同一個 App 驗過（見下方驗收狀態）；Windows 的 `CreateFileW` 路徑**尚未**在 Windows
  上建置或執行過。
- 網路磁碟上的家目錄是否尊重檔案鎖，依檔案系統而定，未驗證。

**為什麼 Windows／Linux 沒有快速解鎖**：macOS 版的 Touch ID 是把資料金鑰（DEK）另存一份在
Keychain、通過生物辨識才取出。Windows Hello 和 Windows 的安全儲存是兩個互不相干的介面，
只在讀出 DEK「之後」跳一次 Hello，DEK 並沒有被 Hello 保護，那只是個樣子；Linux 則沒有
`local_auth` 實作。在能把金鑰真正綁到系統驗證之前，這兩個平台一律只用主密碼，
設定裡也不會出現這個選項。

（Linux 版仍會連結 `libsecret`：那是 `flutter_secure_storage` 的 Linux 外掛在建置時就要的，
雖然快速解鎖沒開、執行時不會去用它，`.deb` 還是把它列為依賴。）

---

## 安裝

### macOS

需要 Flutter（開發時用的是 3.41.9 stable）與 Xcode。

```bash
cd ~/Projects/Private/Nook && flutter pub get
```

跑起來看看：

```bash
flutter run -d macos
```

做一份正式的 app 並裝到 `/Applications`：

```bash
./scripts/install.sh
```

**不要只是把 build 出來的 app 拖進 `/Applications` 之後自己 `codesign --deep --sign -`** ——
那會把 entitlements 整個剝掉，沙盒和「沒有網路權限」這兩件事會一起消失。腳本裡有說明，
而且會在簽完之後檢查沙盒還在、`get-task-allow` 已經拿掉。

### 下載安裝檔（Windows／Linux）

**目前還沒有可公開下載的版本。** 正式的下載點會是 [GitHub Releases](https://github.com/SheldonChangL/nook/releases)：
不必登入，每個版本附 Windows 安裝器、Windows ZIP、Ubuntu `.deb` 與 `SHA256SUMS.txt`。

| 檔案 | 平台 |
|---|---|
| `Nook-<版本>-windows-x64-setup.exe` | Windows 10／11 x64 安裝器（建議） |
| `Nook-<版本>-windows-x64.zip` | Windows x64 免安裝版（內測用） |
| `nook_<版本>_amd64.deb` | Ubuntu 22.04 以上 x64 |
| `SHA256SUMS.txt` | 以上檔案的 SHA256 |

`<版本>` 是 pubspec 的 version 把 `+` 換成 `-`（`1.0.0+1` → `1.0.0-1`）：GitHub 會改寫資產檔名裡的特殊字元，
用不含 `+` 的名字，`SHA256SUMS.txt` 才對得上。`.deb` 裡的套件版本仍是 `1.0.0+1`。

下載後先對雜湊再安裝（把要的檔案和 `SHA256SUMS.txt` 放在同一個資料夾）：

```powershell
Get-FileHash -Algorithm SHA256 .\Nook-1.0.0-1-windows-x64-setup.exe   # 和 SHA256SUMS.txt 裡那一行比對
```

```bash
sha256sum -c --ignore-missing SHA256SUMS.txt
```

#### 發行流程（維護者）

workflow 的 Artifacts 要登入 GitHub 才能下載，只給開發與驗收用，不是給使用者的下載點。給使用者的是 Release，
流程分三步，最後一步一定由人明確操作：

1. **PR 階段**：改到程式、平台目錄、封裝腳本或 workflow 的 PR，會自動跑
   [`Windows installer`](.github/workflows/windows-installer.yml) 與 [`Linux deb`](.github/workflows/linux-deb.yml)
   （唯讀權限；Windows 那支會實際安裝、啟動、覆蓋安裝、解除安裝；Linux 那支會在乾淨容器裡安裝）。
   PR 頁面的 Checks → 該次執行 → Artifacts 可以下載產物到測試機驗收。
2. **建立草稿**：合併進 `main` 後，在 Actions 手動執行 [`Release draft`](.github/workflows/release-draft.yml)，
   輸入 `v` + pubspec 的 `X.Y.Z`（例如 `v1.0.0`）。它在同一個 commit 上重新建置兩個平台、比對 SHA256SUMS、
   確認 tag 與 release 都還不存在，然後建立**草稿** release 並上傳安裝檔與 `SHA256SUMS.txt`。
   草稿只有對 repo 有寫入權限的人看得到，tag 要到發佈時才建立。（`workflow_dispatch` 只認預設分支上的
   workflow 檔，所以這步一定在合併之後。）
3. **驗收後發佈**：從草稿頁下載資產，在乾淨的 Windows 11 x64 與 Ubuntu 22.04／24.04 x64 測試機完成下面的驗收關卡，
   把結果寫進 release 說明，再在網頁上按 **Publish release**，或：

   ```bash
   gh release edit v1.0.0 --repo SheldonChangL/nook --draft=false
   ```

   發佈後任何人都能下載。草稿預設標為 pre-release；確定要當正式版再取消。

安裝檔都**沒有程式碼簽章**（沒有憑證）。Windows 會出現 SmartScreen 警告，見下一節；發佈說明裡要寫明這一點。

### Windows（未驗證）

首批目標是 Windows 11 x64（安裝器允許 Windows 10 以上）。

**安裝**：執行 `Nook-<版本>-windows-x64-setup.exe`。安裝器與程式都**沒有程式碼簽章**，SmartScreen 會顯示
「Windows 已保護您的電腦」，要按「其他資訊」→「仍要執行」；發行者會顯示為「未知的發行者」。
請只執行雜湊與 SHA256SUMS 相符的檔案。

- 只裝給目前使用者，位置 `%LOCALAPPDATA%\Programs\Nook`，不需要系統管理員權限。管理員要裝給所有使用者
  （`Program Files`，要 UAC）只能用命令列 `/ALLUSERS`，之後升級也要一直加 `/ALLUSERS`，不然會變成兩份安裝。
- 建立開始功能表的 Nook 捷徑；桌面捷徑是可勾選的選項（預設不勾）。
- 裝的是完整 Flutter Release 目錄（`nook.exe`、`flutter_windows.dll`、外掛 DLL、`data\`），加上 Visual C++
  runtime 的三個 DLL（`msvcp140.dll`、`vcruntime140.dll`、`vcruntime140_1.dll`）放在 `nook.exe` 旁邊，
  乾淨的 Windows 不必另裝 VC++ Redistributable。這三個 DLL 不會跟著 Windows Update 更新，靠 Nook 出新版帶新的。
- **升級**：直接執行新版安裝器（同一個 AppId，會覆蓋舊版；Nook 還開著會要求先關閉）。
- **解除安裝**：「設定」→「應用程式」→ Nook，或開始功能表。只移除程式與捷徑；
  保險庫 `%APPDATA%\tw.com.jetopto\Nook\vault\` 不在安裝目錄裡，升級、重裝、解除安裝都不會動到。
  真的要清掉資料，自己刪 `%APPDATA%\tw.com.jetopto\Nook`（先確定有備份）。
- 內測用的 ZIP：解壓縮後執行 `Nook\nook.exe`，**整個資料夾要一起搬**；升級就是關掉 Nook、刪掉舊資料夾、
  解壓新的。ZIP 與安裝器內容相同，不要兩種同時用，免得開到舊版。

**自己建置**：建置機需要 Flutter 3.41.9、Visual Studio 2022（「使用 C++ 的桌面開發」）與
[Inno Setup 7](https://jrsoftware.org/isdl.php)（只做 ZIP 可省略，加 `-SkipInstaller`）。

```powershell
flutter pub get
powershell -ExecutionPolicy Bypass -File scripts\package_windows.ps1
```

產出 `dist\` 底下的安裝器、ZIP 與 `SHA256SUMS-windows.txt`。安裝器的設定在 `windows\installer\nook.iss`；
其中的 `AppId` 是 Windows 認定「同一個程式」的依據，發佈後不能改，否則升級會變成裝兩份。

**驗收關卡**（在乾淨、沒有 Flutter 的 Windows 11 x64 上；`scripts\smoke_test_windows_installer.ps1`
會自動做前四項，CI 也跑同一支）：

1. 安裝器靜默安裝成功，安裝目錄有完整 Release 目錄與 VC++ runtime，開始功能表捷徑指向 `nook.exe`。
2. `nook.exe` 啟動後不會立刻結束，且在 `%APPDATA%\tw.com.jetopto\Nook\` 建立 `nook.lock`
   （順便確認資料目錄就是上面寫的位置）。
3. 覆蓋安裝（升級路徑）成功；用 `-PreviousInstaller` 可測從上一版升級。
4. 解除安裝移除程式、捷徑與登錄，`%APPDATA%\tw.com.jetopto\Nook\` 原封不動。
5. 人工：用測試用的假密碼建立保險庫、重開、解鎖、編輯、剪貼簿清除、最小化上鎖；升級到新版後用同一主密碼解鎖；
   第二個執行個體停在「已經在執行」畫面；中文顯示正常；SmartScreen 警告與「仍要執行」流程如上。

### Linux（Ubuntu 22.04 以上 x64）

要發佈的 `.deb` 一律在 Ubuntu 22.04 容器裡建，建置機只要有 Docker：

```bash
./scripts/build_linux_container.sh
```

容器的定義在 [`linux/packaging/build.Dockerfile`](linux/packaging/build.Dockerfile)（Ubuntu 22.04 + Flutter 3.41.9），
CI 的 [`Linux deb` workflow](.github/workflows/linux-deb.yml) 跑的是同一支腳本、同一個映像。

**為什麼不直接在自己的機器上編**：產出的 ELF 會帶著建置機 glibc 的符號版本需求。
在 Ubuntu 24.04 上編，`flutter_secure_storage` 的外掛會引用 GLIBC_2.38 的 `__isoc23_strtoll`
（不是真的用到新功能，是新版 header 把 `strtoll` 重導過去），那包 `.deb` 裝到 Ubuntu 22.04
上 apt 不會擋，但一啟動就被動態連結器以 ``version `GLIBC_2.38' not found`` 打回。
`scripts/package_linux.sh` 現在會把實際的 glibc 需求算出來寫進 `Depends: libc6 (>= X)`，
超過 2.35（22.04）基線就直接讓打包失敗；真的要放棄舊版支援才設 `NOOK_GLIBC_BASELINE`。

只想編給自己這台用，可以直接跑 `flutter pub get && ./scripts/package_linux.sh`，
建置機要有 Flutter 3.41.9 與：

```bash
sudo apt install clang cmake ninja-build pkg-config libgtk-3-dev libsecret-1-dev lld llvm dpkg-dev
```

（`llvm` 的版本要跟 `clang` 對齊 —— Dart native assets 會去 clang 所在的 `/usr/lib/llvm-<N>/bin`
找 `llvm-ar`：22.04 裝 `llvm`、24.04 裝 `llvm-18`。）

```bash
sudo apt install ./dist/nook_1.0.0+1_amd64.deb   # arm64 機器上檔名是 _arm64
sudo apt install ./nook_1.0.0-1_amd64.deb         # 從 Release 下載的檔名（+ 換成 -）
```

裝在 `/opt/nook/`，`nook` 指令與應用程式選單裡的 Nook 都指向它。升級一樣 `apt install`
新的 `.deb`；移除用 `sudo apt remove nook`。保險庫在家目錄底下，升級或移除都不會動到。

---

## 使用

第一次開會要你設主密碼。之後每次開都停在上鎖畫面。

Windows／Linux 把下表的 `⌘` 換成 `Ctrl`。

| 操作 | 做法 |
|---|---|
| 搜尋並複製 | `⌘K` → 打幾個字 → `Enter` 直接把密碼送進剪貼簿 |
| 搜尋並開啟 | `⌘K` → `⌘Enter` |
| 新增 | `⌘N`，或右上角「新增」挑類型 |
| 立刻上鎖 | `⌘L`，或左下角「立刻上鎖」 |
| 看密碼 | 開詳情 → 按該列的「顯示」。20 秒後自己遮回去 |
| 確認自己打了什麼 | 密碼輸入欄位右邊的眼睛。主密碼、換密碼、編輯器裡的密碼欄位都有 |
| 複製密碼 | 按該列的「複製」。左下角環形倒數繞完就清掉剪貼簿 |

主機詳情有一顆「複製成 export 指令」，把整組環境變數倒成 `export FOO='bar'`，貼進終端機就能用。

### 一把金鑰給多台機器

主機的「認證金鑰」是下拉選既有的金鑰項目，存的是引用不是副本。改一次金鑰，所有引用它的主機都跟著更新。金鑰詳情會列出「這把金鑰被誰用」。

### 環境變數分機密與非機密

每一條環境變數可以自己決定要不要遮。像 `PG_DSN` 這種連線字串通常想一眼看到就不要勾，token 就勾起來。

---

## 安全模型

### 加密

全部用 `package:cryptography` 的成熟實作，沒有任何自製的密碼學。

```
主密碼 ──Argon2id(m=128MiB, t=3, p=4)──► KEK（金鑰加密金鑰，只存在記憶體）
                                          │
隨機產生的 DEK（資料加密金鑰，32 bytes）──┴──► 被 KEK 包起來，存進 vault.json
                                          │
每一筆項目 ──ChaCha20-Poly1305(DEK)──► items/<隨機 id>.item
```

兩層金鑰的好處是改主密碼只要重新包一次 DEK，不必把所有項目重新加密。

Argon2id 在這台機器上大約跑 500 ms，這個慢是刻意的，用來墊高暴力破解的成本。參數跟著每個保險庫走（寫在 `vault.json` 裡），以後要調高不會讓舊檔打不開。

ChaCha20-Poly1305 帶認證標籤，檔案被改過會驗證失敗，而不是悄悄解出一堆垃圾。

### 落地的檔案長什麼樣

```
<資料目錄>/
  vault.json          明文。只有格式版本、Argon2id 參數、salt、被包住的 DEK、設定
  items/
    3f9a....item       整包密文：magic + nonce + mac + ciphertext
    7c21....item
```

**連項目名稱和類型都在密文裡**，所以 `cat` 任何一個 `.item` 或翻目錄，看不出那筆是 SSH 金鑰還是某個網站帳號。檔名是隨機 UUID，不是項目名稱。

有一個測試專門驗這件事（`test/vault_test.dart` 的「落地的檔案裡找不到任何明文」），它把所有落地檔案掃一遍，確認沒有任何一段明文出現。

### 自動上鎖與剪貼簿

- 閒置滿設定的時間（預設 5 分鐘）自動上鎖，右上角隨時顯示還剩多久
- 「閒置」算的是鍵盤與滑鼠都沒動。打字也算活動，所以填表填到一半不會被鎖掉；
  活動偵測掛在 Navigator 外面，對話框裡的操作一樣算得到
- 上鎖時會把還開著的對話框與詳情面板一起收掉 —— 不然編輯器會留在上鎖畫面上，
  繼續顯示已經按過「顯示」的機密
- **切換到其他 app 預設不會上鎖。** macOS 只要焦點離開就會回報 `hidden`，視窗根本不用被
  遮住，所以拿它當上鎖訊號的話，⌘Tab 一次就被鎖一次。要這個行為的話設定裡有開關，預設關著
- 這個開關只在 Flutter 回報 `hidden`／`paused` 時上鎖，只失去焦點（`inactive`）不算。Windows／Linux
  上焦點離開通常只會是 `inactive`，所以設定裡的標題寫成「視窗最小化或隱藏時立刻上鎖」，不宣稱切換焦點
  會鎖。各平台實際何時回報 `hidden` 尚未在 Windows／Linux 實機確認
- 機器睡著不需要特別處理：閒置判斷用的是真實經過時間，醒來第一次 tick 就會發現超時而上鎖
- 上鎖時記憶體裡的金鑰與已解密的項目一起清掉
- 複製後預設 30 秒清剪貼簿。**清之前會先確認剪貼簿裡還是我們放的那段**；你後來複製了別的東西就不會被吃掉

### 簽章

安裝腳本重簽一次，是為了拿掉 Xcode 本機簽章時塞進來的
`com.apple.security.get-task-allow` —— 那個 entitlement 允許別的程序掛除錯器進來讀記憶體，
對一個把主金鑰放在記憶體裡的 app 來說不該留著。簽完只剩 `com.apple.security.app-sandbox`。

```bash
codesign -d --entitlements - /Applications/Nook.app
```

### 刻意沒做的事

- **沒有「滑過就顯示密碼」**。揭露一定要是你按下按鈕的明確動作。
  輸入欄位的眼睛是另一回事 —— 那是你正在打的東西，看不到自己打了什麼只會讓人打錯；
  差別在於它預設仍然是遮的，要你主動按
- **沒有解碼 / 亂碼還原之類的揭露動畫**。那種動畫會把每個字逐一演出來，旁邊的人反而看得更清楚
- **密碼錯誤不細分原因**。只說「解不開」，不說是太短還是沒有特殊字元，免得幫人縮小破解範圍
- **沒有雲端同步**，也沒有任何對外連線

---

## Touch ID

只有 macOS 版有（Windows／Linux 為什麼沒有，見「[平台支援](#平台支援)」）。
預設關閉，要到「設定」自己開。

開了之後，**主密碼仍然是唯一能解開資料的金鑰**。Touch ID 做的事是把資料金鑰（DEK）另外存一份在 macOS Keychain，通過生物辨識之後才拿出來用。

要講清楚它的極限：Keychain 那一份是綁在你的 macOS 帳號下的。所以在「你的 Mac 已經登入、而且被別人碰到」這個情境下，它的保護力比主密碼弱。要最嚴格就別開。

關掉 Touch ID 會把 Keychain 裡那份刪掉。

### 為什麼不放進 iCloud Keychain

Keychain 那份明確設成不同步，這是刻意的，不是漏了設：

```dart
accessibility: KeychainAccessibility.first_unlock_this_device,
synchronizable: false,
```

`first_unlock_this_device` 的意思就是「這台裝置專屬，不進備份、不進 iCloud」。

**理由是信任域不能合一。** 現在是兩道鎖放在不同地方：加密後的保險庫檔在這台機器上，
開鎖的東西在你腦袋裡。把金鑰丟進 iCloud Keychain，等於宣告「拿到我的 Apple ID 的人就
拿到我全部的機密」—— 而 Apple ID 是收信、登入一堆服務、而且天天帶在手機上的那個帳號。

之後真的做了跨機同步，這件事會更嚴重：保險庫檔很可能走 iCloud Drive。那時候
**密文和金鑰會躺在同一個帳號底下**，加密就白做了。所以同步的時候要同步的是檔案，
金鑰留在各台機器自己手上（見「跨機同步」）。

還有一層：iCloud Keychain 的救援機制是用裝置密碼去解 Apple 的託管紀錄，那通常是六位
數字。Apple 用 HSM 限制嘗試次數，但保險庫的強度就從 Argon2id 128 MiB 掉到「六位數加上
別人家伺服器的防護」—— 防護主體從數學變成了某個服務的可用性。

另外還有個現實阻礙：要用 iCloud Keychain 同步，app 得帶 `keychain-access-groups`
entitlement，那需要正式開發憑證加 provisioning profile，等於把這個私人工具綁到公司的
Team ID 上。現在是 ad-hoc 簽章，刻意不綁任何團隊帳號。

**如果動機是不想每次打主密碼**，Touch ID 已經解決了，而且不需要雲端：每台機器各自保管
一份，在新機器上手動輸入一次主密碼、開啟 Touch ID，之後那台就不用再打，金鑰從頭到尾
沒離開過各自的機器。

**如果動機是怕忘記**，正確做法是把主密碼放進另一個信任域 —— 紙本，或你已經在用的另一套
密碼管理工具。重點是別跟保險庫檔放在同一個帳號底下。

---

## 資料檔位置

macOS 的 app 是沙盒化的，所以資料在 container 裡：

```
~/Library/Containers/tw.com.jetopto.nook/Data/Library/Application Support/tw.com.jetopto.nook/vault/
```

Windows 與 Linux：

```
%APPDATA%\tw.com.jetopto\Nook\vault\
~/.local/share/tw.com.jetopto.nook/vault/
```

Windows 的路徑來自 `nook.exe` 版本資訊裡的公司名稱與產品名稱（`windows/runner/Runner.rc`），
Linux 的來自應用程式 ID（`linux/CMakeLists.txt` 的 `APPLICATION_ID`）。改了這些，新版就會找不到
舊資料，跟 macOS 改 bundle identifier 是同一件事。（Windows 這條是依 `path_provider_windows`
的規則推得，還沒在 Windows 上實際確認。）

Linux 版開啟時會嘗試把 `vault/` 收成 `0700`，同一台機器的其他帳號進不去。收完會重新讀一次權限確認；
`chmod` 失敗、或指令回報成功但權限沒變（例如放在不支援 POSIX 權限的檔案系統上），設定頁「資料」區
會顯示紅字警告並寫到 stderr，不會假裝已經收緊（解鎖照常，因為內容本身是加密的）。
Windows 的 `%APPDATA%` 預設只有本人有權限，程式不另外調整 ACL。

路徑都很長，所以「設定」裡有顯示完整路徑和一顆「複製路徑」。

---

## 備份與還原

### 備份

把整個 `vault/` 資料夾複製走就是完整備份。

```bash
VAULT=~/Library/Containers/tw.com.jetopto.nook/Data/Library/Application\ Support/tw.com.jetopto.nook/vault
```

```bash
cp -R "$VAULT" ~/Dropbox/securemanage-backup-$(date +%Y%m%d)
```

裡面全是密文，放哪裡都不會洩漏內容 —— 但同樣地，**沒有主密碼誰也打不開，包括你自己**。所以主密碼要另外保管，不要只放在腦袋裡。

`vault.json` 和 `items/` 要一起備份。少了 `vault.json` 就沒有被包住的 DEK，那些 `.item` 檔等於永久廢掉。

### 還原

把備份的 `vault/` 整個蓋回原位，用當時的主密碼解鎖。

跨機器搬也是同一招：複製資料夾過去，在那台機器上用同一個主密碼解鎖就行。Touch ID 的設定不會跟著走，要在新機器上重新開。

跨作業系統也一樣（例如 Mac 搬到 Linux）：檔案格式三個平台相同，把整個 `vault/` 複製到
目標平台的資料目錄（見上面「資料檔位置」）即可。目標位置已經有保險庫的話，先把那份
改名留著，不要直接蓋掉。

---

## 忘記主密碼會怎樣

**資料救不回來。**

沒有後門、沒有救援金鑰、沒有重設流程。主密碼是唯一能推導出 KEK 的東西，而 KEK 是唯一能解開 DEK 的東西。沒有它，那些 `.item` 檔就是一堆沒有意義的位元組，誰也打不開。

這是刻意的設計：有找回機制，就表示存在一條不需要主密碼也能解開資料的路徑，那條路徑也會對別人開著。

實務上的建議：
- 主密碼寫在紙上，收在你放護照的地方
- 或是存進另一套你信得過的密碼管理工具
- 不要存在這台電腦上的任何檔案裡

---

## 跨機同步

這一版沒有做，但格式已經留好了：每筆項目是獨立的加密檔，各自帶 `updatedAt`。之後要同步，把 `vault/` 丟進你自己的 git repo 或用 rsync 搬就行，衝突以 `updatedAt` 判斷。

現在如果要在兩台機器用，就手動複製資料夾（見上面的備份與還原）。

不管用哪種管道搬，**只搬檔案，不要搬金鑰**。主密碼在你腦袋裡、Touch ID 的那份在各台機器
的 Keychain 裡，兩邊都不該進同步管道。這樣就算同步的地方外洩，拿到的也只是一堆密文。
把金鑰也放上雲端為什麼是壞主意，見上面「為什麼不放進 iCloud Keychain」。

---

## 開發

```bash
flutter test
```

64 個測試（含平台變體；macOS 上的數字），分成這幾層：

- `test/vault_test.dart` — 加密與儲存層。建立／寫入／重開解鎖／讀回、密碼錯打不開、落地檔無明文、檔案被竄改會擋下、換主密碼、Touch ID 的 DEK 解鎖、Argon2id 耗時
- `test/ui_flow_test.dart` — 驅動真實 UI 跑完整流程：建立保險庫 → 新增主機 → 上鎖 → 用錯密碼 → 用對密碼 → 讀回，以及閒置自動上鎖與密碼顯示切換
- `test/idle_activity_test.dart` — 掛真正的 `NookApp`，確認鍵盤與對話框裡的操作
  都算活動、切換 app 預設不會上鎖、以及上鎖時對話框會被收掉。這幾個測試一定要用真的 app，
  自己兜簡化的 harness 會測到假的接線
- `test/vault_fixture_test.dart` — 拿凍結的樣本保險庫 `test/fixtures/vault_v1/` 驗格式相容：
  每個 `.item` 還是 `SM01`、整個資料夾複製到別處後用原主密碼解得開、在新位置改寫與換主密碼後
  重開讀得回來、記憶體裡的 KDF 過期時存設定不會配錯 salt（先後執行的回歸測試）、同一程序裡換主密碼與
  存設定同時發出會排隊、寫入不留暫存檔，以及 Linux 的 0700 權限（含 chmod 失敗、指令成功但權限沒變兩條
  失敗路徑）。在哪個平台跑，就是在驗那個平台能打開別台產生的檔案。
  樣本由 `tool/make_vault_fixture.dart` 產生，全是假資料；只有格式升版時才重產
- `test/platform_test.dart` — 用 `TargetPlatformVariant` 模擬 Windows／Linux：快捷鍵改用 Ctrl、
  設定頁沒有 Touch ID、快速解鎖不碰 local_auth 與安全儲存、生命週期上鎖的標題與行為一致（失去焦點不鎖、
  隱藏才鎖）、Linux 的中文字型備援套到主題、等寬字與各畫面的每段中文。這只驗 Dart 端的分流，不能取代實機驗收
- `test/instance_lock_test.dart` — 另開真的 Dart 程序（`test/support/hold_instance_lock.dart`）握鎖，
  驗第二個程序拿不到、握鎖程序被強制終止後鎖會自動釋放、鎖檔開不了時不會被當成拿到鎖
- `test/app_guard_test.dart` — 掛真正的 `NookApp`：拿不到鎖時停在「已經在執行」畫面且保險庫檔案完全沒被
  讀寫、鎖檔放在 `vault/` 外面、權限收不緊時設定頁看得到警告

UI 測試建立保險庫時用的是輕量 KDF 參數（`KdfParams.weakForTests`）。不這樣做的話，
三個測試檔平行跑時每個都在算 128 MiB 的 Argon2，機器會被壓垮而出現一堆假的失敗。
正式強度由 `vault_test.dart` 把關，包含耗時那一項。

把各畫面算成 PNG 來人眼檢查版面：

```bash
flutter test tool/render_screens.dart --update-goldens
```

輸出在 `design/screens/`。

這支刻意放在 `test/` 外面，所以 `flutter test` 不會跑到它。原因是詳情面板會印出建立與更新時間，
每跑一次都不一樣，當成回歸基準比對一定會壞 —— 這些圖是給人看的，不是斷言。

注意算圖器沒有 Menlo 與圖示字型，等寬欄位會變黑塊、圖示會變空框，那是算圖環境的限制，不是 app 的問題。

**所有測試一律使用程式裡捏造的假資料**（`198.51.100.x`、`example.test`、`fake-*`），不碰任何真實憑證。

### Launchpad 出現重複的 Nook

`build/` 裡編出來的 `.app` 會被 Spotlight 索引，於是 Launchpad 會同時列出
`/Applications` 那個和建置產物，看起來像裝了好幾份。

`scripts/install.sh` 裝完之後會把 `build/` 裡的那份刪掉。產物本來就能重新編出來，
刪掉最乾脆；中間檔留著，下次重建一樣快。

（在 `build/` 放 `.metadata_never_index` 是沒用的 —— 那個標記只在磁碟區根目錄生效，
不適用於任意子目錄。）

`flutter run -d macos` 的 Debug 產物也會被索引到，開發途中出現重複是正常的。要清掉：

```bash
rm -rf build/macos/Build/Products && killall Dock
```

`killall Dock` 只是讓 Dock 重畫，不會動到 Launchpad 的排列。

### 動效

視覺動態取自一份內部素材庫的編號，在 Flutter 重新實作（編號對應該素材庫，外部看不到）：

| 編號 | 用在哪 |
|---|---|
| #148 提示字上浮欄位 | 主密碼欄位 |
| #151 欄位搖頭報錯 | 密碼錯誤 |
| #244 格狀強弱量尺 | 設定主密碼 |
| #125 區塊依序輕輕浮現 | 解鎖後列表、詳情內容 |
| #284 列表底色由左刷入 | 清單列滑過 |
| #216 點選放大成面板 | 列表點選長成詳情 |
| #320 側邊欄縮成圖示 | 側邊欄收合 |
| #321 鍵盤喚出搜尋清單 | `⌘K` |
| #139 弧線繞圈累加 | 剪貼簿倒數 |
| #140 畫圈勾選成功 | 複製完成 |
| #205 對話框浮出模糊背景 | 刪除確認 |
| #249 回車化膠囊 | 標籤輸入 |

版面參考素材庫模板：Keyhollow（上鎖畫面的左右分欄）、Docmoor（側邊欄）、Togglet（設定頁）。


---

## Icon

icon 是用 CoreGraphics 直接畫出來的，沒有依賴任何設計工具，所以改色改形狀就是改程式。

```bash
./design/build_icons.sh
```

這支會重算所有尺寸、放進 `macos/Runner/Assets.xcassets/AppIcon.appiconset/`，
並產生一份 `design/out/Nook.icns`（給不經過 Xcode 打包的場合用，例如做 DMG）。
同時產生 Windows 的 `windows/runner/resources/app_icon.ico`（`design/pack_ico.py` 把各尺寸的 PNG 原樣打包，不縮放）。
Linux 的 `.deb` 直接取用 asset catalog 裡的 PNG。

造型與顏色都在 [design/render_icon.swift](design/render_icon.swift)：
深藍 squircle 底板加白色盾牌，盾牌上挖一個鑰匙孔。盾牌呼應 app 裡的鎖定圖示，
鑰匙孔是負空間而不是另一個顏色，所以縮到 16px 還認得出來。

每個尺寸是各自重畫的，不是從 1024 縮下來，小尺寸的邊緣才不會糊掉。
日後加上 iOS / Android 平台時，同一支腳本改一下輸出清單就能產那兩邊的 icon set。

---

## 授權

[MIT](LICENSE)。

這是個人自用的工具，照你自己的判斷使用。原始碼公開，加密的部分全部用
`package:cryptography` 的成熟實作，沒有任何自製的密碼學 —— 歡迎自己讀過再決定
要不要把真的機密放進去。

---

## 支持

這個工具是自己要用才做的，放出來給有同樣需求的人。覺得有用的話：

[![Ko-fi](https://img.shields.io/badge/Ko--fi-%E8%AB%8B%E6%88%91%E5%96%9D%E6%9D%AF%E5%92%96%E5%95%A1-FF5E5B?logo=ko-fi&logoColor=white)](https://ko-fi.com/sheldonchang)

https://ko-fi.com/sheldonchang
