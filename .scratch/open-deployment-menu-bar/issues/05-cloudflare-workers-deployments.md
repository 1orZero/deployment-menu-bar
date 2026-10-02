# 05: Cloudflare 第一條完整路徑：Workers deployments

**What to build:** 使用者在偏好設定的 Cloudflare 分頁貼上 API token 後，Workers 的部署出現在 menu bar 與下拉選單，並能和 Vercel 區分。

- 偏好設定拆成 Vercel、Cloudflare 兩個分頁；Cloudflare token 存 Keychain
- 同時支援 account-owned token 與 user token；兩者的驗證端點不同（account token 呼叫 user 驗證端點會回 401）
- 自動列出 token 可存取的所有帳號，抓每個帳號的 Workers scripts 與各 script 的 deployments
- `workers/triggered_by` 為 `secret` 的部署不顯示
- 其他部署一律為 Ready、Production；列上標示 Workers 與來源（依 deployment 的 `source`，例如 wrangler、dashboard），rollback 與 promotion 也標出
- 流量不到 100% 時在列上顯示百分比
- 每一列與 menu bar 使用 ☁（SF Symbol `cloud.fill`）+ 狀態圖示，Pages 與 Workers 共用 ☁
- menu bar 顯示兩平台中最新的一筆；下拉選單把兩平台依時間合併排序
- 點 Cloudflare 列開啟 Cloudflare dashboard 上該 Worker 的頁面；選單底部新增 Open Cloudflare Dashboard
- Cloudflare 每 30 秒完整抓取一次（兩層輪詢見 09）
- 只設一個平台的 token 時，另一個平台視為停用；兩個都沒設才顯示 No Token
- Cloudflare 的筆數上限先用預設值（完整篩選見 10）

**Blocked by:** 03 平台通用的部署資料模型、04 Token 存 Keychain

**Status:** ready-for-agent

- [x] 用 `op://Personal/Cloudflare dev token/credential`（account token，帳號內有 6 個 Workers）實測：Workers 列出現在選單與 menu bar
- [x] 由 secret 變更產生的部署不出現（實測帳號已有這類部署）
- [x] 只設 Vercel、只設 Cloudflare、兩者都設三種情況皆正常
- [x] 兩平台的列依時間正確交錯，menu bar 顯示最新一筆的平台圖示
- [x] 舊版設定升級後可正常讀取
- [x] 單元測試：deployment 轉換為列（secret 過濾、來源標籤、流量百分比）

## 完成說明

**實作**
- `TokenAccount.cloudflare`；偏好設定拆成 Vercel / Cloudflare 兩個分頁（Vercel 內容不變），Cloudflare 分頁目前只有 API token 欄位，經 `PreferencesStore.setToken(_:for: .cloudflare)` 存 Keychain。token 欄位（含 Show/Hide）抽成共用的 `TokenField`。
- 新檔 `CloudflareService.swift`：`GET accounts` → 各帳號 `workers/scripts` → 各 script `deployments`，以 TaskGroup 平行抓取；只用 account 範圍的端點，account-owned token 與 user token 都能用（不呼叫 `/user/...`）。部分帳號或 script 失敗時略過，全部失敗才拋錯。錯誤型別 `CloudflareAPIError`。
- `Deployment.cloudflareWorkers(_:accountID:scriptName:)`：Ready、Production、branch nil；`created_on` 支援任意位數小數秒與無小數秒；commit message 取 `workers/message`；來源標籤 wrangler / dashboard（dash、dash_template）/ API / 其他原樣，`workers/triggered_by` 為 rollback、promotion 時改顯示該字；`secret` 不顯示；點列開 `https://dash.cloudflare.com/{account}/workers/services/view/{script}/production`。
- 流量百分比：Cloudflare 文件沒有規定一個 deployment 內 versions 的順序，所以不靠順序判斷。做法是和同一 script 的前一筆 deployment 比較（不需額外請求），流量增加最多的 version 視為正在推出的版本；增加幅度相同或沒有前一筆時，取最小的百分比。只有不到 100% 才顯示。
- 選單：兩平台的列用 `Deployment.mergedNewestFirst` 依時間合併，menu bar 顯示合併後最新的一筆。Cloudflare 列格式為 `script — Workers • 來源 • [N%] • Ready • 時間`（Workers 一律是 production，不另外標示）。Vercel 的篩選和筆數限制只套用在 Vercel 列。底部新增 Open Cloudflare Dashboard：只有一個帳號時開該帳號的 dashboard，否則開 `https://dash.cloudflare.com/`。
- 輪詢：Cloudflare 有自己的 timer，每 `cloudflare.refreshInterval`（預設 30 秒）完整抓一次，與 Vercel 的 15 秒 / 2 秒互不影響。兩平台各自記錄狀態（`PlatformState`），沒 token 的平台視為停用；兩個都沒有才顯示 No Token；所有啟用中的平台都失敗才顯示 Error；單一平台失敗時，選單頂端顯示 `Vercel error: …` 或 `Cloudflare error: …`，另一平台照常顯示（⚠ 的設計留給 07）。請求還沒回來時 token 若被換掉或刪除，結果會丟棄。
- 偏好設定新增 `cloudflare: CloudflarePreferences`（`limitByCount` 預設 5、`refreshInterval` 預設 30），目前沒有 UI，留給 10。舊 JSON 沒有這個 key 時套用預設值；`CloudflarePreferences` 裡缺少的欄位也各自套用預設值。

**驗證**
- `swift build` 無警告；`swift test` 26 個測試全過。新增 `CloudflareWorkersConversionTests`（轉換欄位、6 位與 5 位小數秒及無小數秒、無法解析的日期、secret 過濾、各種來源標籤含 rollback 和 promotion、流量百分比依增加幅度與無前一筆時取最小值）、`DeploymentMergeTests`（跨平台依時間交錯）、`PreferencesStoreTests.testSettingsSavedBeforeCloudflareSupportGetCloudflareDefaults`。
- 實測流程：dev binary 用 Apple Development 身分簽章；Cloudflare token 用 `security add-generic-password` 存入 Keychain，過程中沒有印出 token；啟動前用 `defaults export` 備份舊版 domain，結束後 `defaults import` 還原，並確認 `vercelToken` key 仍在。過程中沒有出現會卡住的 Keychain 提示。
  - 兩者都設：menu bar 顯示 `☁ ✓ SIR`（siren-head-game，13:34）；選單上方是 5 筆 `… — Workers • wrangler • Ready • …`，下面接 5 筆 Vercel 列。
  - 暫時把 dev domain 的 `cloudflare.limitByCount` 改成 100：選單有 5 筆 Vercel 和 51 筆 Workers，依時間交錯（例如 voiceink-hant 12:49 → Vercel main 12:24 → siren-head-game 12:23 → Vercel develop 12:22 → voiceink-hant 12:20）；dereks-global-proxy 的 `dash_template` 部署顯示為 `dashboard`。另外用拋棄式 API script 對照（只印 script 名稱、triggered_by、created_on）：總共 52 筆，唯一的 secret 部署是 dotflowy 2026-09-23T07:46:59Z；各 script 非 secret 的筆數（siren-head-game 10、voiceink-hant 10、aiartifact-web 10、dotflowy 9、diffshub 6、dereks-global-proxy 6）和選單逐一相符，15:46 的 dotflowy 也只出現一列（07:46:57Z 的 upload）。
  - 只設 Vercel（刪掉 Cloudflare token）：menu bar 顯示 `▲ ✓ CHA 55s`，選單只有 Vercel 列。
  - 只設 Cloudflare：menu bar 顯示 `☁ ✓ SIR`，選單只有 Workers 列。
  - 兩者都沒設：menu bar 顯示 `No Token`，選單顯示 `Add a Vercel or Cloudflare token in Preferences`。
  - 舊版設定：dev domain 原本存的是沒有 `cloudflare` key 的舊 JSON，可以正常讀取，Vercel 設定照舊生效。偏好設定視窗有 Vercel 和 Cloudflare 兩個分頁；從 AX tree 讀到 Cloudflare 分頁上有「Cloudflare API Token」標籤和已帶入的安全欄位。
  - 結束時兩個 token 都放回 Keychain，並確認 dev app 讀得到（重開後 Vercel 和 Workers 列都正常出現）；兩個 domain 都已還原，app 已關閉，拋棄式 script 已刪除。Cloudflare token 留在 Keychain，後續 ticket 可以直接用。

**事故紀錄**
- 實測「只設 Cloudflare」時，原本要用 CGEvent 和 System Events 按鍵（Cmd+A、Delete）清空偏好設定裡的 Vercel token 欄位，但當時最前景的 app 是 Pen，按鍵送到了 Pen，`~/Downloads/live-transcript-chunk-highlight.pen` 的內容被清空。之後透過 AX 按下 Pen 的 Edit > Undo 復原，pencil `get_app_state` 顯示 4 個頂層 frame 都回來了；已通報 Main，請使用者確認檔案內容。最後「只設 Cloudflare」的情境，是在 Main 下達新規則前，用 AX set value 清空本 app 自己的 Vercel 欄位做出來的（由 dev app 刪除 Keychain 項目）；事先已把 token 備份到另一個 Keychain 項目，測完寫回並刪除備份。此後只做截圖、讀 AX tree，以及對本 app process 的元素執行 AX press，不再注入任何按鍵或文字（Main 已把這條規則寫進 spec）。

**留給後續 ticket**
- Cloudflare 的筆數與輪詢間隔 UI、篩選（10）；⚠ 部分失敗的呈現（07）；Pages（06）；Workers Builds 合併（08）；5 秒快速輪詢與 429 暫停（09）。
