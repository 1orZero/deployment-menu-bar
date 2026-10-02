# 12: 文件與版本 0.3.0

**What to build:** README 與 docs 網站改為介紹 Open Deployment Menu Bar（Vercel + Cloudflare）。

- 下載與 clone 連結指向 `1orZero/deployment-menu-bar`，並註明 fork 自 `andrewk17/vercel-deployment-menu-bar`
- 網域維持 `vercel-deployment-menu-bar.vercel.app`
- 版本統一為 0.3.0（app 的版本資訊、docs 網站的結構化資料）
- 新增 Cloudflare 設定步驟：token 需要 Account Settings Read、Pages Read、Workers Scripts Read；要看 Workers build 狀態，必須用 user token 並加上 Workers CI Read；說明 rate limit 與輪詢間隔的關係
- 修正 README 已過時的 Vercel 設定說明（現在是勾選器，不是文字欄位；menu bar 圖示也已不同）
- 免責聲明擴充為與 Vercel、Cloudflare 皆無隸屬關係
- 重拍截圖，畫面同時有 ▲ 與 ☁ 的列

English 文件依 `humanizer` 潤飾一次。

**Blocked by:** 01–11 全部

**Status:** ready-for-agent

- [x] README 與 docs 不再以 Vercel 作為 app 名稱
- [x] 所有下載與原始碼連結指向 fork，並註明 fork 來源
- [x] 各處版本號一致為 0.3.0
- [x] 截圖同時顯示 ▲ 與 ☁ 的列
- [x] Cloudflare 權限說明與 08 的降級行為一致

## 完成說明

- `README.md` 全面改寫：app 名稱改為 Open Deployment Menu Bar（Vercel + Cloudflare Pages/Workers），下載與 clone 連結指向 `1orZero/deployment-menu-bar`，並註明 fork 自 `andrewk17/vercel-deployment-menu-bar`。內容包含功能、安裝、打包（`SIGNING_IDENTITY` 未設定時 ad-hoc 簽章並略過公證；`Scripts/create-app-icon.sh` 需 Xcode 26+ 才能產生 `Assets.car`）、Vercel 設定（改為勾選器說明；menu bar 顯示 ▲／☁ 加狀態圖示）、Cloudflare 權限與 08 的降級行為（缺 Workers CI Read 或用 account-owned token 時 Workers 列無 build 狀態並顯示 ⚠，訊息與 `CloudflareService` 字串一致）、General 分頁的 Menu Layout、輪詢間隔（Vercel 15s／2s；Cloudflare 30s／5s，下限 10s／2s）、1200 次／5 分鐘的 rate limit 與 429 暫停（無 `Retry-After` 時 60 秒）、Keychain 與自動遷移、FAQ、免責聲明（與 Vercel Inc.、Cloudflare, Inc. 皆無隸屬關係）。唯一保留的舊名稱出現在「從原版 Vercel Deployment Menu Bar 遷移設定」的歷史說明。
- `docs/index.html`：標題、meta description／keywords、JSON-LD（name、softwareVersion 0.3.0、downloadUrl 指向 fork releases、screenshot）、hero、features、新增 FAQ 區塊、footer 免責聲明。網域維持 `vercel-deployment-menu-bar.vercel.app`；`sitemap.xml`、`robots.txt` 只含網域，未修改。
- `Scripts/package-app.sh`：`CFBundleShortVersionString` 0.3.0、`CFBundleVersion` 3。
- 內容逐項對照原始碼（`PreferencesWindow.swift` 的欄位文字與預設值、`CloudflareService.swift` 的權限訊息、`TokenStore.swift` 的 Keychain service）與票 01–11 的完成說明；英文依 `humanizer` 潤飾一次。
- 截圖：使用整合 QA 拍攝的真實畫面（使用者同意公開真實專案名稱），放在 repo 根目錄與 `docs/img/` 的 `open-deployment-menu-bar-macos.png`，畫面含 ☁ Workers／Pages 列、▲ Vercel 列與 Workers CI Read 橫幅。舊圖 `vercel-menu-bar-deployment-status-macos.png`（根目錄與 `docs/img/`）已刪除。
