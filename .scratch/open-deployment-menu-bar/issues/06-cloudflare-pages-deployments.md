# 06: Cloudflare Pages deployments

**What to build:** Cloudflare 加入 Pages。抓每個帳號的 Pages 專案與各專案的部署，列上標示 Pages、分支、Production／Preview（取自 `environment`），tooltip 顯示 commit 訊息，點擊開啟 Cloudflare dashboard 上的該次部署頁面。

新增 Skipped 狀態（灰色 SF Symbol `forward.end.circle.fill`），只有 Cloudflare 會產生。狀態依 `latest_stage` 對應：

| `latest_stage` | App 狀態 |
|---|---|
| queued，或 status 為 idle | Queued |
| status 為 active（initialize、clone_repo、build、deploy） | Building |
| deploy 階段 success | Ready |
| failure | Error |
| canceled | Canceled |
| skipped（或 `is_skipped`） | Skipped |

實測帳號目前沒有 Pages 專案。實作時在該帳號建立 `qa-` 前綴的 Pages 專案並保留，至少要有一筆 production 部署、一筆 preview 部署和一筆失敗部署。若 token 沒有 Pages 寫入權限，請使用者協助建立。

**Blocked by:** 05 Cloudflare 第一條完整路徑：Workers deployments

**Status:** ready-for-agent

- [x] `qa-` Pages 專案的部署出現在選單，狀態、分支、環境正確
- [x] 建置中的部署顯示 Building 與經過時間，完成後轉為 Ready
- [x] 單元測試涵蓋上表每一列
- [x] 完成說明記錄 `qa-` 專案名稱，專案保留不刪

## 完成說明

- **測試專案**：`qa-odmb-pages`（production branch `main`），保留不刪。部署全部用 `wrangler pages deploy` 直接上傳：
  - production：`main`（兩筆，第二筆是重新部署）
  - preview：`qa-preview`
  - 失敗部署：`qa-failure`。`wrangler.toml` 設 `compatibility_date = "2099-01-01"`，Cloudflare 在伺服器端拒絕發布 Function，產生一筆 `latest_stage` 為 deploy／failure 的部署。語法錯誤或缺少 import 的 `_worker.js` 會在 wrangler 本機檢查就失敗，不會產生部署。
  - 同一分支另有一筆成功的 preview 部署
- **實作**
  - `CloudflareService.fetchDeployments(token:limit:)` 在同一次 Cloudflare 更新中，對每個帳號平行抓 Workers 與 Pages：`pages/projects`，以及每個專案的 `deployments?per_page=min(limit, 25)`（Pages API 每次最多 25 筆）。沿用「略過失敗元素、全部失敗才丟錯」的模式，所以 Pages 失敗不會讓 Workers 的列消失，反之亦然。這點已用 stub URLSession 的一次性測試確認，確認後已刪除該測試。
  - `Deployment(pages:accountID:projectName:)`：
    - 狀態依上表對應，未知 status 為 Unknown；非 deploy 階段的 success 視為 Building，因為下一階段尚未開始
    - `buildStartedAt` 取 build 階段的 `started_on`
    - 完成、失敗、取消時，`finishedAt` 取 `latest_stage.ended_on`
    - 分支與 commit 訊息取自 `deployment_trigger.metadata`，環境取自 `environment`
    - 點擊開啟 `dash.cloudflare.com/{account}/pages/view/{project}/{id}`
  - 新增 `Deployment.State.skipped`，圖示為灰色 `forward.end.circle.fill`，選單文字為 Skipped。Vercel 的篩選維持五個開關。
- **驗證**
  - `swift build`、`swift test` 通過，共 43 個測試，其中 `CloudflarePagesConversionTests` 9 個：涵蓋表格每一列、`is_skipped` 優先、環境／分支／commit 擷取、由階段推得的時間長度。
  - 實機執行：dev binary 以 Apple Development 身分簽章，執行前備份 legacy domain、結束後還原，全程未送出任何按鍵。選單列顯示「☁ ✓ QA- 1s」。以 AX press 我們自己的狀態列項目打開選單，出現以下列：
    - `qa-odmb-pages (main) — Pages • Production • Ready 1s`
    - `(qa-failure) — Pages • Preview • Error`
    - `(qa-preview) — Pages • Preview • Ready 1s`
- **未能實機驗證**
  - 直接上傳的部署沒有 build 階段，build 為 idle。以 0.3 秒間隔輪詢 API，只觀察到約 1 秒的 queued／active，app 顯示為 Queued，接著就是 deploy／success。active 階段要 Git 連動的建置才會出現，目前的 token 無法觸發，所以 Building 與經過時間只由單元測試涵蓋。
  - Skipped 狀態同樣只由單元測試涵蓋。
  - 選單 tooltip 未透過 AX 讀到。tooltip 沿用既有的 `commitToolTip`，commit 訊息擷取由單元測試涵蓋。
