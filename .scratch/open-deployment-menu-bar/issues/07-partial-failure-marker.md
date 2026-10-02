# 07: 單一平台失敗時加 ⚠

**What to build:** 一個平台失敗（API 錯誤、token 無效）時，menu bar 照常顯示另一個平台的最新一筆，標題尾端加 ⚠；下拉選單上方說明是哪個平台、什麼錯誤。兩個平台都失敗時顯示 Error（沿用現行樣式）。只設一個平台的 token 不算失敗。失敗後仍持續輪詢，平台恢復後 ⚠ 自動消失（現行程式只在抓取成功後才排下一輪輪詢，需一併處理）。

08 的權限不足與 09 的 429 暫停都使用這個 ⚠。

**Blocked by:** 05 Cloudflare 第一條完整路徑：Workers deployments

**Status:** ready-for-agent

- [x] Cloudflare token 改成無效值：menu bar 顯示 Vercel 最新一筆 + ⚠，選單說明 Cloudflare 的錯誤
- [x] 兩個平台的 token 都無效：顯示 Error
- [x] 改回有效 token 後，下一輪輪詢 ⚠ 即消失，不需手動 Refresh
- [x] 單元測試：兩平台結果組合對應到 menu bar 狀態（正常、⚠、Error、No Token）

## 完成說明

**設計**
- 新檔 `StatusDecision.swift`：`PlatformIssue { message }`、`PlatformStatus { isEnabled, deployments, issue }`（取代 controller 內私有的 `PlatformState`，`error: Error?` 改成 `issue: PlatformIssue?`），以及純函式 `StatusButtonState(platforms:)` → `.noToken`／`.error`／`.empty(warning:)`／`.deployment(_, warning:)`。
  - 沒有任何啟用平台 → No Token；有 deployment 就顯示所有啟用平台中最新的一筆，任一啟用平台有 issue 就加 ⚠；沒有任何 deployment 時，所有啟用平台都有 issue 才是 Error，否則是空狀態（只有圖示，有 issue 時加 ⚠）。
  - 08（缺 Workers CI Read 但仍有資料）與 09（429 暫停）只要設定 `issue` 並保留 `deployments`，就會走同一個 ⚠ 與選單 banner，不需改結構。
- `StatusItemController`：`updateStatusButton()` 改為 switch `StatusButtonState`，⚠ 加在標題尾端；選單原本的「X error: …」列改成每個有問題的平台一列置頂 banner「Vercel: …」／「Cloudflare: …」（附 `exclamationmark.triangle.fill` 圖示），下面接分隔線。
- 失敗後持續輪詢：Vercel 失敗時也會用閒置間隔（15 秒）重排計時器（原本只有成功才排，失敗後就不再輪詢）；Cloudflare 每次 refresh 一開始就會重排重複計時器，失敗後本來就會繼續輪詢。
- `PreferencesStore.discardCachedToken(for:)`：平台失敗時清掉記憶體中的 token 快取，下一輪輪詢重新讀 Keychain。這樣在 app 外（例如 `security` CLI）換掉的 token，下一輪輪詢就會生效；正常情況下仍沿用快取，不會每輪都讀 Keychain。

**測試**
- `swift build` 成功；`swift test` 共 43 個測試全過。新增 `StatusButtonStateTests`（8 個）：正常（跨平台取最新）、單一平台失敗顯示另一平台並加 ⚠、兩平台都失敗顯示 Error、唯一啟用的平台失敗顯示 Error、沒有 token 顯示 No Token、只有一個平台停用不算失敗、健康平台沒有資料加上另一平台失敗時顯示空狀態加 ⚠、有 issue 但仍有資料時顯示資料加 ⚠。

**實機 smoke**（dev binary 用 Apple Development 身分簽章；啟動前用 `defaults export` 把舊 domain 備份到 600 權限的暫存檔，結束後 `defaults import` 還原；沒有送出任何按鍵，只讀自己 PID 的 AX 樹並用 `screencapture` 截圖）
- Token 備份與替換：寫了一個拋棄式 Swift helper，用相同身分簽章並帶 `-i open-deployment-menu-bar`，讓它符合 Keychain 項目的 designated requirement，存取時不會跳出提示。用它把 `vercel`／`cloudflare` 項目分別複製成暫存項目 `<account>-backup07`，寫入無效值 `invalid-token-qa07`，之後再從暫存項目還原。全程沒有印出任何 token。
1. 只有 Cloudflare 無效：menu bar 顯示 `▲ ✓ CHA 2m 4s ⚠`（有截圖）；選單第一列是「Cloudflare: Cloudflare API error (400): Invalid request headers (6003)」，下面是 Vercel 列。
2. 兩者都無效（重新啟動）：menu bar 顯示 `⚠ Error`（有截圖）；選單有兩列 banner：「Vercel: Vercel API error (403): …invalidToken…」和「Cloudflare: …(6003)」。
3. 不重新啟動、不按 Refresh Now，13:59:58 還原 Vercel token：14:00:04 輪詢後顯示 `CHA 2m 4s ⚠`，證明 Vercel 失敗後仍會繼續輪詢。14:00:35 還原 Cloudflare token：14:00:48 那一輪 ⚠ 消失，標題變成 `CHA 2m 4s`；選單沒有 banner，Vercel 與 Workers 列依時間交錯（voiceink-hant、siren-head-game…），「Last updated: 14:01」，表示 app 已讀到兩個真實 token。
4. 收尾：結束 dev app；helper 比對確認兩個 Keychain 項目與備份相同，然後刪除暫存項目（`security find-generic-password` 查詢暫存項目回傳 exit 44）；舊 domain 已還原，`vercelToken` 非空；helper、腳本與備份檔都已刪除。
