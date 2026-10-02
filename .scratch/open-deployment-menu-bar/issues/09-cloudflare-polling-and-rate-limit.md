# 09: Cloudflare 兩層輪詢與 429 退避

**What to build:** Cloudflare 的 API 上限是每位使用者每 5 分鐘 1200 次，超過會封鎖 5 分鐘，連 dashboard 與 wrangler 都受影響。Cloudflare 輪詢改為兩層：

- 依閒置間隔（預設 30 秒）完整抓取
- 有 Pages 部署或 Workers build 進行中時，依快速間隔（預設 5 秒）只重查進行中的項目
- 收到 429 時依 `retry-after` 暫停 Cloudflare 輪詢；暫停期間 menu bar 加 ⚠（07），選單顯示剩餘等待時間，結束後自動恢復

Cloudflare 分頁可設定兩個間隔。Vercel 輪詢不受影響（維持 15 秒與 2 秒）。

**Blocked by:** 06 Cloudflare Pages deployments、07 單一平台失敗時加 ⚠、08 Workers Builds 合併與權限不足降級

**Status:** ready-for-agent

- [x] 閒置時每輪完整抓取；有建置中項目時，快速輪詢每輪只發出少量請求（完成說明記錄實測的每輪請求數）
- [x] 在 `qa-` Pages 專案觸發一次部署，實測快速輪詢能看到 Building 轉為 Ready
- [x] 以模擬 429 回應測試：暫停到 `retry-after` 結束、顯示 ⚠ 與剩餘時間、之後恢復
- [x] 間隔設定變更後立即生效

## 完成說明

- **實作**
  - `CloudflarePreferences.fastRefreshInterval`，預設 5 秒，舊設定缺少此鍵時採用預設值。`refreshInterval` 維持 30 秒。下限為完整抓取 10 秒、快速輪詢 2 秒，排程時與設定頁存檔時都會套用。
  - 完整抓取的 `CloudflareSnapshot` 新增 `pendingItems`，列出 Queued 或 Building 的列，以及重查該列所需的請求：
    - Pages：`GET accounts/{id}/pages/projects/{name}/deployments/{id}`
    - Workers：`GET accounts/{id}/builds/builds/{build_uuid}`。build 已合併到 deployment 的列，也記錄 build UUID，由 `Deployment.cloudflareWorkersRows` 提供。
  - `CloudflareService.fetchPendingUpdates` 對每個項目只發一個請求。結果套回目前的列：Pages 整列換成新資料，Workers 只更新狀態與時間，其餘欄位維持完整抓取的內容。有項目完成時立即做一次完整抓取，補上合併後的狀態。
  - 新檔 `CloudflarePolling.swift`：純狀態 `CloudflarePolling`，負責列、待重查項目與 429 暫停，`plan(at:preferences:)` 決定下次完整抓取時間與是否啟用快速輪詢。快速輪詢只重查完整抓取在套用範圍與篩選後仍顯示的列。
  - 429：`CloudflareService.get` 解析 `Retry-After`，支援秒數與 HTTP date，缺少或無法解析時用 60 秒，並丟出 `CloudflareAPIError.rateLimited(until:)`。平行請求中任一個收到 429 就取消其餘請求並丟出，Workers Builds 的 429 也不會被當成權限不足。暫停期間保留上次的列，⚠ 訊息為 `Rate limited by Cloudflare — retrying in 42s`，每秒重建選單更新倒數。暫停期間不送任何 Cloudflare 請求，包括 Refresh Now 與設定變更觸發的重抓。完整抓取的 timer 改在暫停結束時觸發，恢復輪詢。
  - `StatusItemController`：完整抓取與快速輪詢各有一個 timer。快速輪詢的結果不會延後完整抓取；沒有進行中的列或暫停時，快速 timer 停止。Vercel 的 timer 不變。
  - Cloudflare 分頁新增「Refresh Intervals」區塊，含 Full Refresh Interval 與 In-Progress Interval 兩個欄位，沿用 `NumericTextField`。每次輸入都立即存檔；存檔觸發重抓，並依新間隔重排 timer。
- **測試**：`swift build`、`swift test` 通過，共 71 個測試。`CloudflarePollingTests` 9 個，涵蓋：
  - `Retry-After` 的秒數、HTTP date、過去時間、缺少與無法解析
  - 排程：有進行中的列時啟用快速輪詢；沒有時停用；篩選隱藏的列不重查；低於下限的間隔會調高；暫停時不跑快速輪詢，完整抓取延到暫停結束
  - 依 id 套用 Pages 與 Workers 的重查結果
  - URLProtocol stub：快速輪詢只發出進行中項目的請求；Pages 部署列表或 Workers Builds 回 429 時，暫停並保留列、顯示 ⚠ 與倒數，暫停結束後完整抓取成功即恢復；快速輪詢收到 429 時同樣暫停
- **實機執行**：dev binary 以 Apple Development 身分簽章。執行前備份 legacy 與 dev domain，結束後還原，legacy 的 token 鍵仍在。全程未送出任何按鍵。請求數用暫時的 debug log 計算，驗證後已移除。
  - 每輪請求數，測試帳號有 1 個帳號、6 個 Worker、1 個 Pages 專案：
    - 閒置的完整抓取每輪 11 個：accounts、workers/scripts、6 個 script deployments、builds/latest（這個 token 會收到 401）、pages/projects、`qa-odmb-pages` deployments。四輪實測都是 11 個。
    - 快速輪詢每輪 1 個，每個進行中項目一個請求。
  - 部署：用 `wrangler pages deploy` 對 `qa-odmb-pages` 的 `qa-t09` 分支做了 4 次 preview 部署，commit 訊息為 `qa-t09 fast tier smoke 1`～`4`，保留不刪。直接上傳的部署從建立到完成約 1.2 秒，前 3 次都落在兩次完整抓取之間，完整抓取沒看到進行中的狀態。第 4 次把部署時間對準完整抓取：
    - 14:35:55 完整抓取看到該列為 Queued，待重查 1 筆
    - 14:36:01 快速輪詢送出 1 個請求，到 `.../deployments/ae27d450-…`，該列變成 Ready
    - 14:36:01 隨即完整抓取一次
    - 直接上傳沒有 build 階段，`latest_stage` 從 queued 直接變成 deploy／success，所以實機沒看到 Building。
  - 429：用暫時的 hook 讓下一個 Cloudflare 請求模擬 `Retry-After: 40` 的 429，驗證後已移除。
    - menu bar 顯示 `QA- 1s ⚠`；選單頂端依序顯示 `Cloudflare: Rate limited by Cloudflare — retrying in 35s`、`26s`、`3s`。Cloudflare 列保留，Vercel 列照常更新。
    - 40 秒內沒有任何 Cloudflare 請求。
    - 14:37:11 暫停結束，完整抓取恢復，共 11 個請求；⚠ 改回原本的 Workers Builds 權限提示。
  - 間隔立即生效：GUI 安全規則不允許輸入文字，所以改用暫時的 hook 呼叫 `PreferencesStore.shared.update`。這和設定頁存檔走同一條路徑，驗證後已移除。設定 3／1 秒後依下限存成 10／2 秒，14:37:59 立即完整抓取一次，之後在 14:38:09、14:38:19、14:38:29 各抓一次，間隔從 30 秒變成 10 秒。
- **未能實機驗證**：Workers build 的快速重查。這個 token 呼叫 Builds API 會收到 401，所以 Workers 的部分只由單元測試涵蓋。
