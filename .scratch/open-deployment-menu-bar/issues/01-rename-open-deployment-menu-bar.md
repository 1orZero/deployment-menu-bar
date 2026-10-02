# 01: 改名為 Open Deployment Menu Bar

**What to build:** App 改以「Open Deployment Menu Bar」出現在 Finder、選單（例如 Quit 項目）、偏好設定視窗標題與打包產物。Bundle ID 改為 `com.1orzero.open-deployment-menu-bar`；SwiftPM package、執行檔 target、測試 target 與模組名稱改為 `open-deployment-menu-bar` 系列。打包腳本的簽章身分改讀環境變數 `SIGNING_IDENTITY`，未設定時用 ad-hoc 簽章並略過公證。既有使用者升級後，設定（含 Vercel token、團隊、專案、篩選）自動從舊 bundle ID `com.andrew.vercel-deployment-menu-bar` 的 UserDefaults 搬入，不必重新設定。

這張票會移動所有原始檔，必須最先完成，避免與其他票衝突。README 與 docs 網站不在範圍內（見 12）。

**Blocked by:** None (can start immediately)

**Status:** ready-for-agent

- [x] `swift build` 與 `swift test` 通過，測試以新模組名稱匯入
- [x] 打包產物的名稱、CFBundleName、CFBundleDisplayName 為 Open Deployment Menu Bar，bundle ID 為 `com.1orzero.open-deployment-menu-bar`
- [x] 未設 `SIGNING_IDENTITY` 時打包成功（ad-hoc 簽章、略過公證）；有設定時使用該身分簽章
- [x] 舊 bundle ID 有設定而新 bundle ID 沒有時，首次啟動後沿用舊設定；新 bundle ID 已有設定時不覆蓋
- [x] 程式內不再出現舊 app 名稱（Vercel Deployment Menu Bar、Vercel Status Preferences）；Vercel 平台專屬文字（例如 Vercel token 欄位）保留

## 完成說明

- `Package.swift`：package、執行檔 target 改為 `open-deployment-menu-bar`，測試 target 改為 `open-deployment-menu-barTests`；`Sources/`、`Tests/` 目錄以 `git mv` 改名，測試改用 `@testable import open_deployment_menu_bar`。
- 使用者可見名稱：選單 Quit 項目為「Quit Open Deployment Menu Bar」，偏好設定視窗標題為「Open Deployment Menu Bar Preferences」。Vercel 平台專屬文字（Vercel token 欄位、Open Vercel Dashboard 等）保留。
- 設定搬移：`PreferencesStore` 改為可注入 `UserDefaults`（目前網域與舊網域 `com.andrew.vercel-deployment-menu-bar`）。目前網域沒有 `vercelStatusPreferences` 而舊網域有時，複製到目前網域；目前網域已有設定時不覆蓋。舊網域不刪除、不修改（token 清理由 04 處理）。儲存 key 維持 `vercelStatusPreferences`。
- 新增 `PreferencesStoreTests`：涵蓋「新網域為空時複製舊設定（且舊網域保持不變）」與「新網域已有設定時不覆蓋」。
- 打包腳本：產物名稱、執行檔路徑、bundle ID 已更新；簽章身分讀 `SIGNING_IDENTITY`，未設定時以 `-` ad-hoc 簽章並略過公證（`package-app.sh` 與 `notarize-app.sh` 皆會檢查）。圖示路徑不變。

驗證：
- `swift build`：Build complete；`swift test`：Executed 4 tests, with 0 failures。
- `swift build -c release && ./Scripts/package-app.sh`（未設 `SIGNING_IDENTITY`）：輸出「SIGNING_IDENTITY not set: signing ad-hoc」「Notarization skipped: app is ad-hoc signed」，產出 `build/Open Deployment Menu Bar.app`。
- `plutil -p`：CFBundleDisplayName / CFBundleName = "Open Deployment Menu Bar"，CFBundleExecutable = "open-deployment-menu-bar"，CFBundleIdentifier = "com.1orzero.open-deployment-menu-bar"。
- `codesign -dv`：Identifier=com.1orzero.open-deployment-menu-bar、flags=0x2(adhoc)、Signature=adhoc。
- `SIGNING_IDENTITY="Bogus Identity XYZ" ./Scripts/package-app.sh`：輸出「Signing app with identity: Bogus Identity XYZ」後由 codesign 回報 no identity found，確認會使用指定身分。
- grep `Sources`、`Scripts`、`Tests`：不再出現「Vercel Deployment Menu Bar」「Vercel Status Preferences」；唯一的 `vercel-deployment-menu-bar` 字串是搬移用的舊網域常數。
