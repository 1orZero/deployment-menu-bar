# 10: Cloudflare 範圍與篩選

**What to build:** Cloudflare 分頁補齊一整套獨立於 Vercel 的範圍與篩選，只影響 Cloudflare 的列：

- 帳號：全部可存取的帳號，或勾選指定帳號
- 專案：全部，或勾選指定專案；Pages 專案與 Worker 列在同一清單並標示類型
- 分支（逗號分隔）；設定後，沒有分支資訊的列（wrangler、rollback、promotion 部署）不顯示
- Production／Preview
- 狀態：Ready、Building、Error、Queued、Canceled、Skipped
- 筆數上限，或只顯示最近 X 小時

**Blocked by:** 06 Cloudflare Pages deployments、08 Workers Builds 合併與權限不足降級

**Status:** ready-for-agent

- [x] 每個設定變更後選單立即更新
- [x] 設定分支篩選 `main` 後，wrangler 部署的列消失
- [x] 指定帳號或專案後，不再對未選的帳號與專案發出請求
- [x] Vercel 的篩選不受 Cloudflare 設定影響，反之亦然
- [x] 單元測試：Cloudflare 篩選規則（含沒有分支的列、Skipped）

## 完成說明

- 設定：`CloudflarePreferences` 新增 `accountIDs`（空＝全部帳號）、`projects: [CloudflareProjectScope]`（kind pages/workers＋accountID＋name，空＝全部）、`gitBranches`、Production／Preview、六個狀態開關（含 `showSkipped`）、`limitByHours`；`limitByCount` 維持 Int（0＝不限筆數，筆數優先於小時，與 Vercel 相同）。解碼改為「先套預設值、有鍵才覆寫」，舊 JSON 解成全顯示。
- 篩選：純函式 `CloudflarePreferences.filter(_:now:)`（CloudflareFilter.swift），只套在 Cloudflare 列；分支有設定時沒有分支的列不顯示。Vercel 的 `filterDeployments` 未變動。
- 範圍：`CloudflareService.fetchDeployments(token:preferences:)` 內處理：有選帳號時不呼叫 `accounts`，只查選取帳號；有選專案時只查有選專案的帳號，沒有選 Worker 的帳號完全不查 Workers，有選 Pages 時直接查該專案的 deployments（不列專案清單）。
- 偏好視窗：Cloudflare 分頁新增 Accounts／Projects（同一清單，標示 Pages／Workers，多帳號時加帳號名）、Filters、Limits；狀態放在新檔 `CloudflareFiltersModel`，選項由 `CloudflareService.fetchScopeOptions(token:)` 取得，Cloudflare token 變更（500 ms debounce）與 Refresh 按鈕會重新查詢。抽出 `CheckboxListBox`，Vercel 與 Cloudflare 的勾選清單共用。
- 測試：`CloudflareFilterTests`（7 個：分支篩選隱藏無分支列、無分支篩選時保留、環境開關、狀態開關含 Skipped、筆數優先於小時、只用小時、舊 JSON 解碼為預設）。`swift build`、`swift test` 71 個測試全過。
- 實機驗證（簽章 dev binary，legacy 與 dev domain 先 `defaults export` 備份、結束後 `defaults import` 還原；設定以寫 dev domain JSON 與對本程式 Preferences 視窗的 AX press 變更，無鍵盤輸入；暫時的請求 log 已移除）：
  - 不限筆數：Cloudflare 列含 5 筆 qa-odmb-pages 與約 50 筆 `Workers • wrangler` 列。
  - 分支 `main`：只剩 2 筆 `qa-odmb-pages (main)`，wrangler／dashboard 的 Workers 列全部消失；Vercel 列（含 develop、jack/… 等非 main 分支）不變。
  - 在 Preferences 勾選只有 `qa-odmb-pages`：存檔後立即重抓，之後兩輪請求只有 `GET accounts` 與 `GET accounts/…/pages/projects/qa-odmb-pages/deployments`，不再有 `workers/scripts`、Workers deployments 或 builds 請求；Workers build 權限 ⚠ 也隨之消失。
- 修正：抓取筆數在篩選之前就被截斷。之前 Pages deployments 與 Workers build 清單只請求 `per_page=min(筆數上限,25)`，之後才套用篩選。所以最新幾筆若都被篩掉（例如隱藏 Preview），較舊但符合條件的列就不會出現；不限筆數時也只會抓到 25 筆，小時範圍可能不完整。
  - 從 `filter(_:now:)` 抽出純判斷 `CloudflarePreferences.matches(_:)`，涵蓋狀態、環境與分支，不含筆數和小時上限；另外抽出 `hoursCutoff(now:)`。`filter` 改為呼叫這兩個函式，行為不變。
  - `CloudflareService.fetchPaged`：以 `page=N&per_page=25` 逐頁請求，把每頁轉成列並計算符合 `matches` 的筆數。符合下列任一條件就停止：
    - 符合的筆數達到 `limitByCount`
    - 小時模式下，該頁最舊的一列已超出時間範圍
    - 該頁不滿 25 筆
    - 已請求 4 頁（每個清單每次完整抓取最多 100 筆）
  - 兩種上限都沒設時，一直抓到清單結束或 4 頁為止。`result_info.total_pages` 不在現有解碼裡，所以沒有使用。
  - 4 頁的上限保留，用來保護每 5 分鐘 1200 個請求的額度；收到 429 時，使用者的 dashboard 和 wrangler 也會被擋 5 分鐘。不過被上限截斷的結果不會當成完整結果顯示：抓滿 4 頁（第 4 頁也是 25 筆），但筆數上限還沒達到、小時範圍也還沒超出時，該清單算是截斷。這時 snapshot 的 issue 會列出被截斷的清單，畫面上是資料加 ⚠，沿用 07 的機制：`Partial results: stopped after 100 deployments for a, b, c +N more`（名稱排序後最多列 3 個）。如果同時有其他 issue（例如 Workers CI Read 權限），兩段以 ` · ` 合併成同一則 Cloudflare banner，例如 `Workers build status needs a user API token with Workers CI Read · Partial results: stopped after 100 deployments for site`。第 4 頁剛好是清單最後一頁時，也會被當成截斷。
  - Pages 只顯示 Production 或只顯示 Preview 時，請求會加上官方文件列出的 `env=production`／`env=preview`，由伺服器端篩選。兩者都隱藏時，完全不發 Pages 請求（包括專案清單）。
  - Pages 每個專案的 deployments、每個已連接 Workers Builds 的 script 的 build 清單都改用 `fetchPaged`；Workers deployments 不變。build 的列要等到和 deployment 合併後才產生，所以篩選判斷套用在 build「未合併時」的列（`Deployment.cloudflareWorkersBuildRow`，環境由 deploy command 判斷）。
- 測試：新增 `CloudflarePagingTests` 10 個，使用 URLProtocol stub，依 path 與 `page` 回應，並記錄每個請求：
  - 第 1 頁有 5 筆 Preview 加 1 筆 Production，只發 1 個請求，Production 列會出現
  - 第 1 頁 25 筆 Preview、第 2 頁 1 筆 Production，請求 page 1、2，Production 列會出現
  - 無篩選且第 1 頁就有 25 筆，只發 1 個請求
  - 小時模式在超出時間範圍的那一頁之後停止，只請求 page 1、2
  - 每頁都是 25 筆不符合分支篩選的列：剛好請求 4 頁，100 列照常回傳，並出現 `Partial results…site` issue
  - 第 4 頁才達到筆數上限：請求 4 頁，沒有 issue
  - 只顯示 Production 時帶 `env=production`；兩者都顯示時不帶 `env`；兩者都隱藏時不發 deployments 請求
  - `builds/latest` 回 401，同時 Pages 被截斷：只有一則 issue，內容是兩段以 ` · ` 合併
  - 截斷名稱列 3 個後接 `+N more`
  - Workers build 清單：第 1 頁 25 筆 Preview build、第 2 頁 1 筆 `wrangler deploy` build，請求 page 1、2，該 build 列會出現
  - `swift build`、`swift test` 共 81 個測試全部通過。
- 實機驗證（在加入截斷提示與 `env` 參數之前執行；之後的變更只由單元測試驗證）：
  - 準備：dev binary 以 Apple Development 身分加 `-i open-deployment-menu-bar` 簽章，沒有出現 Keychain 提示。啟動前用 `defaults export` 把 legacy 與 dev domain 備份到 600 權限的暫存檔，結束後 `defaults import` 還原；legacy 的 `vercelToken` 仍在且不為空。全程沒有送出按鍵，只對本程式 PID 的狀態列項目做 AX press／cancel。
  - 請求數：用暫時的 debug log 計算，驗證後已移除。設定為預設值（筆數 5、無篩選），三輪完整抓取每輪都是 11 個請求，與修正前相同；`qa-odmb-pages` deployments 每輪只有 1 個 `page=1&per_page=25`。
  - 畫面：menu bar 顯示 `☁ ✓ VOI ⚠`；選單中 `qa-odmb-pages (qa-t09) — Pages • Preview • Ready` 列照常出現，Vercel 列也正常。
