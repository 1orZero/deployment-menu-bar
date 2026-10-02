# 02: App 圖示

**What to build:** App 圖示改為與平台無關的「向上箭頭 + 狀態點」：深色漸層 macOS 圓角方形底、白色向上箭頭、右下角綠色狀態點，不含文字與任何商標。用 Codex CLI 的 image generation 產生 3 張 1024px 候選圖，由使用者挑選一張。選定後轉成 app 用的 icns 與 repo 根目錄的 app 圖示 png，打包時使用新圖示。只為 Vercel 三角形存在的圖示產生腳本與未使用的 SVG 一併移除；若保留產生流程，改為「從選定 PNG 轉出 icns」。

**Blocked by:** None (can start immediately)

**Status:** ready-for-agent

- [x] 產生 3 張候選圖並交給使用者挑選（需要使用者決定，不可自行選定）
- [x] icns 含 macOS 所需的全部尺寸，`iconutil` 轉檔成功
- [x] 打包後的 app 在 Finder 與 Dock 切換器顯示新圖示
- [x] 畫三角形的舊腳本與未使用的 SVG 已刪除，沒有殘留引用

## 完成說明

- 候選圖：以 `codex exec -s workspace-write -C .scratch/open-deployment-menu-bar/icon-candidates --skip-git-repo-check "<brief>"` 產生 3 張（內建 image_gen 輸出 1254px，以 `sips` 縮成 1024×1024），放在 `.scratch/open-deployment-menu-bar/icon-candidates/`。使用者選定 candidate-1（置中實心箭頭）。
- 新增 `Resources/AppIcon-source.png`（candidate-1 的 1024×1024 原圖），保留 macOS 慣例的透明邊距。
- `Scripts/create-app-icon.sh` 改寫為「從來源 PNG 轉出 icns」：以 `sips` 產生 16/32/128/256/512 的 @1x 與 @2x，再執行 `iconutil -c icns` 輸出 `Resources/AppIcon.icns`。實際執行成功；`iconutil -c iconset` 拆回後 10 個尺寸都在。
- 根目錄 `app-icon.png` 換成新圖，維持原本的 512×512。
- 已刪除 `Scripts/generate-icon.py` 與 `Resources/vercel-icon.svg`。排除 .scratch/.build/build 後 grep 不到殘留引用，README 也沒有提到它們。
- 驗證：`swift build -c release && ./Scripts/package-app.sh`（未設定 SIGNING_IDENTITY）成功，`build/Open Deployment Menu Bar.app/Contents/Resources/AppIcon.icns` 與 `Resources/AppIcon.icns` 逐位元組相同（`cmp`）。從 icns 取出 32px 圖檢視，箭頭與綠點清楚可辨。
- 修正 macOS 26+ 的灰框（icon jail）：
  - 原因：只有 `CFBundleIconFile` + icns 時，macOS 26 以後所有 app 圖示都必須套系統的 squircle 遮罩；icns 的圖若不是滿版不透明（候選圖自帶圓角方形、四周透明邊距與陰影），系統會把它縮小後放進灰色 squircle 底板。在本機（macOS 27.0）以 `lsregister -f` 註冊後，用 `NSWorkspace.icon(forFile:)` 輸出的 256px 圖確認有灰色外框。
  - 做法：新增 Icon Composer 格式的 `Resources/AppIcon.icon/`（`icon.json` + `Assets/Background.png`、`Arrow.png`、`Dot.png`，皆 1024px 滿版）。三層由 `AppIcon-source.png` 推得：裁出原圖 squircle 內部放大成滿版，箭頭與綠點以去背方式拆成獨立圖層，背景在箭頭、綠點與原本圓角邊緣處用周圍漸層補滿。兩個 group 都關閉 specular、translucency 與 shadow，外觀維持原圖（深色漸層、白箭頭、右下綠點）。
  - `Scripts/create-app-icon.sh` 除了 icns，還以 `xcrun actool Resources/AppIcon.icon --compile … --app-icon AppIcon --platform macosx --target-device mac --minimum-deployment-target 13.0` 編出 `Resources/Assets.car`（需 Xcode 26+；本機 actool 27.0 實際執行成功）。
  - `Scripts/package-app.sh` 的 Info.plist 加上 `CFBundleIconName=AppIcon`，並把 `Assets.car` 複製進 bundle；`CFBundleIconFile=AppIcon` 與 `AppIcon.icns` 保留作為 fallback，簽章流程不變。
  - 驗證：`swift build -c release && ./Scripts/package-app.sh`（未設定 SIGNING_IDENTITY）成功，bundle 內有 `Assets.car` 與 `AppIcon.icns`，`plutil -extract CFBundleIconName` 得到 `AppIcon`。`lsregister -f` 後再用 `NSWorkspace.icon(forFile:)` 輸出圖示：修正前是深色圖示縮在淺灰色 squircle 底板中，修正後是系統遮罩的滿版深色 squircle，白箭頭與右下綠點完整，沒有灰框。macOS 13–15 沒有實機可測。
