# 03: 平台通用的部署資料模型

**What to build:** 預先重構，讓之後加入 Cloudflare 只需新增資料來源。選單與 menu bar 改用一份不綁定平台的部署資料：平台（Vercel，或 Cloudflare 的 Pages／Workers）、專案名稱、狀態、建立／開始建置／完成時間、分支、環境（Production／Preview）、commit 訊息、點擊開啟的網址、來源標籤、流量百分比。Vercel 的 API 回應先轉成這份資料，再進入篩選、排序、menu bar 與選單。

使用者看得到的改變只有兩項：menu bar 標題與每一列在狀態圖示前多了單色 ▲ 平台圖示（SF Symbol `triangle.fill`）；沒有部署時標題只顯示圖示，不再顯示「VRC」。其餘 Vercel 行為不變。

**Blocked by:** 01 改名為 Open Deployment Menu Bar

**Status:** ready-for-agent

- [x] Vercel 的列表、篩選、筆數上限、經過時間、tooltip、點擊開啟 inspector 與改版前一致
- [x] menu bar 標題與每一列顯示「▲ + 狀態圖示」
- [x] 沒有部署時標題只有圖示
- [x] 單元測試涵蓋 Vercel 回應的轉換（狀態、時間、分支、環境、點擊網址）

## 完成說明

- 資料模型（`Models.swift`）：新增平台通用的 `Deployment`（`id`、`platform: Platform`（`vercel`／`cloudflarePages`／`cloudflareWorkers`）、`projectName`、`state: State`（queued／building／ready／error／canceled／unknown）、`createdAt`、`buildStartedAt?`、`finishedAt?`、`branch?`、`environment: Environment?`（production／preview／`custom(String)`）、`commitMessage?`、`openURL?`、`sourceLabel?`、`trafficPercentage?`，以及 `buildStartDate` = `buildStartedAt ?? createdAt`）。原本的 Vercel DTO 改名為 `VercelDeployment`／`VercelDeploymentsResponse`，只負責解碼；`Deployment(vercel:)` 負責轉換（毫秒→`Date`、分支取 `gitSource.ref` 否則 `meta.githubCommitRef`、空字串視為無分支、`target` 轉環境、點擊網址優先 `inspectorUrl` 否則補 `https://` 的 `url`）。Skipped 狀態留給 06。
- `DeploymentService` 解碼後立即轉成 `Deployment`，去重排序改用 `id`／`createdAt`；`StatusItemController` 的篩選、排序、筆數／時數上限、經過時間、tooltip、點擊開啟全部改讀通用欄位，邏輯不變。
- 圖示：`icon(for: Deployment)` 用 drawing handler 把平台 SF Symbol（Vercel `triangle.fill`，Cloudflare 預留 `cloud.fill`）以 `labelColor` 著色後，與原本彩色狀態圖示合成單一 `NSImage`，status button 與每個選單列共用；彩色狀態圖示維持非 template。
- 沒有部署時標題為空字串、只顯示 `circle` 圖示；啟動時的初始 "VRC" 改為直接呼叫 `updateStatusButton()`。
- 自訂環境：Vercel `target` 不是 production／preview 時（例如 `staging` 或 custom environment）存成 `Environment.custom(原字串)`，選單列照舊顯示 capitalized 名稱（例如「Staging」），Production／Preview 篩選也照舊不影響這類部署。
- 驗證：`swift build` 成功；`swift test` 共 12 個測試全數通過（新增 `VercelDeploymentConversionTests` 8 個：完整轉換、所有狀態對應、缺少時間戳的 fallback、分支 fallback 與空值、環境（含 `staging` → `.custom("staging")`）、點擊網址 fallback 與保留既有 scheme）。
- 實機 smoke：執行 `.build/debug/open-deployment-menu-bar`（此 domain 已從舊 bundle ID 帶入 token），`screencapture -x -R1028,0,700,30` 拍到 menu bar 顯示「▲ ✓ CHA 55s」，與同時執行的舊版 App「✓ CHA 55s」數值一致；點開選單每列為「▲ ✓ 專案 (分支) — Production • Ready 55s • 12:24」等，深色 menu bar 上 ▲ 為白色、淺色選單內為黑色。另外暫時把此 domain 的分支篩選設成不存在的分支（之後已還原）重新啟動，menu bar 只顯示圓形圖示、沒有文字。結束後已 kill 程序。
