# SecureManage

本機用的機密資料管理工具。管三類東西：

| 類型 | 存什麼 |
|---|---|
| **金鑰** | SSH 私鑰、API token、憑證。含 passphrase、演算法標記 |
| **帳號** | 服務帳號密碼，含網址、使用者名稱、備註 |
| **主機 / VM** | 位址、port、登入帳號、跳板機、sudo 密碼、環境變數，可引用某把金鑰 |

macOS app（Flutter），同一份程式碼之後可以編成 iOS / Android。
**沒有任何資料離開這台機器**，Release 版的 entitlements 裡沒有任何網路權限。

---

## 安裝

需要 Flutter（開發時用的是 3.41.9 stable）與 Xcode。

```bash
cd ~/Projects/Private/SecureManage && flutter pub get
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

---

## 使用

第一次開會要你設主密碼。之後每次開都停在上鎖畫面。

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
- app 切到背景立刻上鎖，不等倒數
- 上鎖時記憶體裡的金鑰與已解密的項目一起清掉
- 複製後預設 30 秒清剪貼簿。**清之前會先確認剪貼簿裡還是我們放的那段**；你後來複製了別的東西就不會被吃掉

### 簽章

安裝腳本重簽一次，是為了拿掉 Xcode 本機簽章時塞進來的
`com.apple.security.get-task-allow` —— 那個 entitlement 允許別的程序掛除錯器進來讀記憶體，
對一個把主金鑰放在記憶體裡的 app 來說不該留著。簽完只剩 `com.apple.security.app-sandbox`。

```bash
codesign -d --entitlements - /Applications/SecureManage.app
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

app 是沙盒化的，所以資料在 container 裡：

```
~/Library/Containers/tw.com.jetopto.securemanage/Data/Library/Application Support/tw.com.jetopto.securemanage/vault/
```

這串很長，所以「設定」裡有顯示完整路徑和一顆「複製路徑」。

---

## 備份與還原

### 備份

把整個 `vault/` 資料夾複製走就是完整備份。

```bash
VAULT=~/Library/Containers/tw.com.jetopto.securemanage/Data/Library/Application\ Support/tw.com.jetopto.securemanage/vault
```

```bash
cp -R "$VAULT" ~/Dropbox/securemanage-backup-$(date +%Y%m%d)
```

裡面全是密文，放哪裡都不會洩漏內容 —— 但同樣地，**沒有主密碼誰也打不開，包括你自己**。所以主密碼要另外保管，不要只放在腦袋裡。

`vault.json` 和 `items/` 要一起備份。少了 `vault.json` 就沒有被包住的 DEK，那些 `.item` 檔等於永久廢掉。

### 還原

把備份的 `vault/` 整個蓋回原位，用當時的主密碼解鎖。

跨機器搬也是同一招：複製資料夾過去，在那台機器上用同一個主密碼解鎖就行。Touch ID 的設定不會跟著走，要在新機器上重新開。

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

11 個測試，分成兩層：

- `test/vault_test.dart` — 加密與儲存層。建立／寫入／重開解鎖／讀回、密碼錯打不開、落地檔無明文、檔案被竄改會擋下、換主密碼、Touch ID 的 DEK 解鎖、Argon2id 耗時
- `test/ui_flow_test.dart` — 驅動真實 UI 跑完整流程：建立保險庫 → 新增主機 → 上鎖 → 用錯密碼 → 用對密碼 → 讀回，以及閒置自動上鎖

把各畫面算成 PNG 來人眼檢查版面：

```bash
flutter test tool/render_screens.dart --update-goldens
```

輸出在 `design/screens/`。

這支刻意放在 `test/` 外面，所以 `flutter test` 不會跑到它。原因是詳情面板會印出建立與更新時間，
每跑一次都不一樣，當成回歸基準比對一定會壞 —— 這些圖是給人看的，不是斷言。

注意算圖器沒有 Menlo 與圖示字型，等寬欄位會變黑塊、圖示會變空框，那是算圖環境的限制，不是 app 的問題。

**所有測試一律使用程式裡捏造的假資料**（`198.51.100.x`、`example.test`、`fake-*`），不碰任何真實憑證。

### 動效

視覺動態取自內部素材庫（`192.168.162.158/motion/`）的編號，在 Flutter 重新實作：

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
並產生一份 `design/out/SecureManage.icns`（給不經過 Xcode 打包的場合用，例如做 DMG）。

造型與顏色都在 [design/render_icon.swift](design/render_icon.swift)：
深藍 squircle 底板加白色盾牌，盾牌上挖一個鑰匙孔。盾牌呼應 app 裡的鎖定圖示，
鑰匙孔是負空間而不是另一個顏色，所以縮到 16px 還認得出來。

每個尺寸是各自重畫的，不是從 1024 縮下來，小尺寸的邊緣才不會糊掉。
日後加上 iOS / Android 平台時，同一支腳本改一下輸出清單就能產那兩邊的 icon set。
