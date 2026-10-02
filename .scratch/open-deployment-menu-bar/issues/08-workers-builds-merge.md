# 08: Workers Builds 合併與權限不足降級

**What to build:** Workers 列加入 build 狀態。透過 Workers Builds API 取得 build（以 script 的 `tag` 查詢，每批最多 20 個），依 version 與 deployment 合併成一列，一次 Git push 只出現一列。沒有 build 的部署（wrangler、rollback、promotion）維持 05 的 Ready + 來源標籤。非 production 分支的 build 沒有對應部署，顯示為 Preview 列。

環境判斷：build 產生的版本已被部署為 Production，否則為 Preview；建置中尚未部署時，依該 build 的觸發設定判斷。這是根據文件的推論，需以官方 API 文件確認。

| `status` / `build_outcome` | App 狀態 |
|---|---|
| queued | Queued |
| initializing、running | Building |
| stopped + success | Ready |
| stopped + fail、terminated | Error |
| stopped + cancelled | Canceled |
| stopped + skipped | Skipped |

權限不足：Builds API 回 401 或 403（account token，或缺 Workers CI Read）時，Pages 與 Workers deployments 照常顯示，Workers 列沒有 build 狀態，menu bar 加 ⚠（07），選單說明需要 user token 與 Workers CI Read 權限。

驗證方式：提供的 token 是 account token，Builds API 會回 401 `Invalid token`，用它實測降級路徑。完整的 Builds 路徑用依官方 API 文件整理的模擬回應做單元測試。

**Blocked by:** 05 Cloudflare 第一條完整路徑：Workers deployments、07 單一平台失敗時加 ⚠

**Status:** ready-for-agent

- [x] 用現有 token 實測：Workers 列照常顯示，menu bar 有 ⚠，選單說明缺少的權限
- [x] 單元測試（模擬回應）：build 與部署依 version 合併為一列；沒有 build 的部署保留；preview build 顯示為 Preview；上表每一列
- [x] 模擬回應的欄位來源（官方文件頁面）寫在測試旁的註解

## 完成說明

**官方文件確認的事實**
- Build 物件沒有 version 欄位，唯一能把 build 對到 Worker 版本的是 `GET /accounts/{account_id}/builds/builds?version_ids=`（[Get builds by Worker version](https://developers.cloudflare.com/api/resources/workers_builds/methods/get_builds_by_version/)，每次最多 20 個）。回應是 `result.builds` 這個 map；文件範例的 key 是 `"foo"`，沒有明講 key 是什麼，程式依查詢參數推定 key 為 version ID（推論，尚未用 user token 實際驗證）。
- `GET .../builds/builds/latest?external_script_ids=`（[Get latest builds by script IDs](https://developers.cloudflare.com/api/resources/workers_builds/methods/get_latest_builds/)，最多 20 個）回傳每個 script 最新一筆 build，同樣是 map。程式同時採用 map 的 key 與 build 的 `trigger.external_script_id`，判斷哪些 script 已連接 Workers Builds。
- `GET .../builds/workers/{external_script_id}/builds`（[List builds for a Worker](https://developers.cloudflare.com/api/resources/workers_builds/subresources/builds/methods/list/)）支援 `page`、`per_page`。Build 欄位包括 `status`（queued／initializing／running／stopped）、`build_outcome`（success／fail／skipped／cancelled／terminated）、`created_on`、`running_on`、`stopped_on`、`build_trigger_metadata.branch`／`commit_message`／`deploy_command`，以及 `trigger.branch_includes`／`deploy_command`。
- [Builds API reference](https://developers.cloudflare.com/workers/ci-cd/builds/api-reference/)：Builds API 需要 user token，account-owned token 會回「Invalid token」；script 的 `tag` 就是 `external_script_id`；每個 Worker 最多兩個 trigger：production branch 一個，其他分支（preview）一個。權限名稱依 [API token permissions](https://developers.cloudflare.com/fundamentals/api/reference/permissions/) 為 **Workers CI Read**。
- [Builds](https://developers.cloudflare.com/workers/ci-cd/builds/)、[Build branches](https://developers.cloudflare.com/workers/ci-cd/builds/build-branches/)、[Configuration](https://developers.cloudflare.com/workers/ci-cd/builds/configuration/)：production branch 跑 deploy command（預設 `npx wrangler deploy`）並建立 deployment；非 production 分支跑 Preview command（預設 `npx wrangler preview`，或改成 `npx wrangler versions upload`），只建立 Preview 或 version，不會部署。
- 文件沒有提供 build 詳細頁的 dashboard 網址格式（只說網址最後一段是 build UUID），所以 build 列點擊後開啟 Worker 頁面（與 05 相同的 `…/workers/services/view/{script}/production`）。

**環境判斷規則（依文件修正後）**
- build 產生的版本已部署（對到 deployment）→ Production，該列沿用 deployment 的 id 與流量百分比。
- 沒對到 deployment 的 build（建置中、失敗、取消、略過，或 preview 分支）→ 依這次 build 的 deploy command 判斷：`build_trigger_metadata.deploy_command`（沒有時用 `trigger.deploy_command`）含 `wrangler deploy` 為 Production，其餘（`wrangler preview`、`wrangler versions upload`、自訂指令）為 Preview。這樣失敗的 production build 也會顯示為 Production，比票上「否則為 Preview」準確。
- 合併規則：每個 build 只合併到「最早」rollout 它版本的 deployment；rollback（以及隱藏的 secret 部署）不參與合併，所以 rollback 到某個 build 的版本時，仍是獨立的「rollback」列。
- 合併列與 build 列：狀態依上表；時間以 build 的 `created_on` 排序，建置時間是 `running_on` 到 `stopped_on`（Ready／Error／Canceled 才有結束時間）；分支與 commit 訊息取自 `build_trigger_metadata`，沒有 commit 訊息時改用 deployment 的 `workers/message`；不顯示來源標籤。

**每次完整更新的請求數（每個 account）**：script 清單 1＋每個 script 的 deployments N＋`builds/latest` ⌈N/20⌉。只有已連接 Workers Builds 的 B 個 script 才再加 B 個 build 清單請求（`per_page` = 筆數上限，最多 25）與 ⌈V/20⌉ 個 version 查詢（V = 這些 script 的 deployment 版本數）。`builds/latest` 與 deployments 平行送出，build 清單與 version 查詢也平行送出。測試帳號 6 個 script：1＋6＋1 = 8 個 Workers 請求（`builds/latest` 回 401 後就停止），與 05 相比只多 1 個。

**權限不足降級**：Builds 任一請求失敗時（build 清單之外；build 清單沿用「部分失敗略過」），Workers deployments 照常轉換，不帶 build 狀態，`CloudflareSnapshot.issue` 設為 `PlatformIssue`。401／403 的訊息是「Workers build status needs a user API token with Workers CI Read」，其他錯誤是「Workers build status unavailable: …」。`refreshCloudflare()` 把它放進 `PlatformStatus(deployments:issue:)`，沿用 07 的「資料＋⚠」與選單 banner。

**修改的檔案**：`CloudflareService.swift`（script DTO 加 `tag`、build DTO、取得與合併流程、狀態與環境對應、`collect` 改為泛型）、`StatusItemController.swift`（`refreshCloudflare()` 成功分支帶入 `snapshot.issue`），新增 `Tests/.../CloudflareWorkersBuildsTests.swift`。

**驗證**
- `swift build` 成功；`swift test` 共 55 個測試全部通過。新增 `CloudflareWorkersBuildsTests` 6 個（模擬回應依上述 API 文件的 200／401 範例，頁面網址寫在測試檔註解）：依 version 合併為一列（含建置時間與 commit）；沒有 build 的 wrangler 部署保留 Ready＋來源，rollback 到已建置版本仍是獨立列；`versions upload`／`wrangler preview` 的 build 為 Preview、建置中的 `wrangler deploy` build 為 Production；狀態表每一列；以 URLProtocol stub 讓 `builds/latest` 回 401（12006 Invalid token）時 deployments 保留且 issue 為權限訊息；完整路徑以 script tag 查 latest、以 version 查 build 並合併。
- 實機 smoke：dev binary 用 Apple Development 身分加 `-i open-deployment-menu-bar` 簽章，沒有出現 Keychain 提示；啟動前用 `defaults export` 把舊 domain 與 dev domain 備份到 600 權限的暫存檔，結束後 `defaults import` 還原（舊 domain 兩個 key 都在、dev domain 的 `cloudflare.limitByCount` 回到 5），備份檔已刪除。全程沒有送出任何按鍵，只對自己 PID 的狀態列項目做 AX press／cancel，並用 `screencapture` 截圖。使用現有的 account-owned token：
  - menu bar 顯示 `☁ ✓ QA- 1s ⚠`；選單第一列 banner 是「Cloudflare: Workers build status needs a user API token with Workers CI Read」，下面是 Pages 列（qa-odmb-pages）與 Vercel 列。
  - 為了讓 Workers 列擠進清單，暫時把 dev domain 的 `cloudflare.limitByCount` 改成 20 後重新啟動：選單同時出現 Pages、Vercel 與 Workers 列（例如「voiceink-hant — Workers • wrangler • Ready • 13:52」、「siren-head-game — Workers • wrangler • Ready • 13:44」），Workers 列沒有 build 狀態。
  - 截圖：`/tmp/odmb08/shots/bar.png`（menu bar）、`bar20.png`、`menu20-crop.png`（選單）。截圖時畫面上另有系統的「OSGKeyboard quit unexpectedly」對話框，與本 app 無關，沒有操作它。
- 未實測：完整 Builds 路徑（需要具 Workers CI Read 的 user token 與已連接 Git 的 Worker），只由模擬回應的單元測試涵蓋；`version_ids` 回應的 key 是 version ID 這點也因此未經實際驗證。
