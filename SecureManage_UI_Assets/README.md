# UI Assets

app 實際用到的圖檔都在這裡，透過 pubspec.yaml 的 `assets:` 打包進 bundle。

- hero/empty_state.svg — 主畫面沒有項目時的空狀態插圖
- icons/lock.svg、icons/shield.svg — 線性 SVG，用 `currentColor`，程式端用 ColorFilter 改色
- backgrounds/left_panel.svg — 側欄的藍色漸層＋波浪
- palette.json — 色票；程式端的對應在 lib/ui/theme.dart 的 NookPalette

沒被程式引用的圖不要放進來，`assets:` 是整個目錄打包，多放就是多塞進 app。
