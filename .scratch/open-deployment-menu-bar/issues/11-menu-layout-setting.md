# 11: 選單版面設定

**What to build:** 偏好設定新增 General 分頁，分頁順序為 General、Vercel、Cloudflare。General 提供「選單版面」：依時間排序（預設）或依平台分區。

- 依時間排序：維持 05 與 07 的行為
- 依平台分區：Vercel 與 Cloudflare 各一區，區內依時間排序；各區自己顯示 token 未設定、錯誤提示與 Open Dashboard 項目
- menu bar 一律顯示兩平台中最新的一筆，不受版面設定影響

**Blocked by:** 07 單一平台失敗時加 ⚠

**Status:** ready-for-agent

- [x] 新安裝與升級的使用者預設為依時間排序
- [x] 切換版面後選單立即改變
- [x] 分區版面下，某平台失敗時錯誤只顯示在該平台的區內
- [x] 只設一個平台時，分區版面只顯示該平台的區

## 完成說明

**設計**
- `Models.swift`：新增 `MenuLayout`（`byTime`／`byPlatform`）與 `GeneralPreferences { menuLayout }`（預設 `.byTime`），放在 `Preferences.general`。沒有 `general` key 的舊設定、或是無法辨識的值，都會退回 `.byTime`。
- 新檔 `MenuComposition.swift`：純函式 `MenuComposition(layout:vercel:cloudflare:)`，產出 `entries: [MenuEntry]`（notice／banner／header／deployment／dashboard／separator）與 `footerDashboards`。
  - 沒有任何啟用平台：兩種版面都沿用原本的 No Token 提示，footer 保留兩個 Dashboard 項目。
  - 依時間排序：與 05、07 相同，每個失敗平台一列置頂 banner（「平台: 訊息」），接著兩平台合併、由新到舊排列；Dashboard 項目留在 footer（Refresh Now 與 Preferences… 之間）。
  - 依平台分區：只為啟用的平台建立區塊，順序是 Vercel、Cloudflare。每區依序是停用的平台名稱標題、該平台的 banner（只有訊息）、該平台由新到舊的列（沒有列也沒有錯誤時顯示「No deployments found」），最後是自己的「Open … Dashboard」。各區之間用分隔線隔開；footer 只有 Last updated、Refresh Now、Preferences…、Quit。
- `StatusItemController`：`buildMenu()` 改成把 `MenuComposition` 轉成 `NSMenuItem`（`menuItem(for:)`、`dashboardItem(for:)`），並移除 `displayedDeployments`。收到偏好設定變更通知時會先立刻 `buildMenu()` 再重新抓取資料，所以版面一切換就生效。menu bar 按鈕仍由 `StatusButtonState` 決定，不受版面影響。
- `PreferencesWindow.swift`：分頁依序為 General、Vercel、Cloudflare。General 只有一個「Menu Layout」選單（By Time／By Platform，沒有說明文字）。`@Published` 會在屬性實際改變前發出新值，所以版面設定直接存發出的值。

**測試**
- `swift build` 成功；`swift test` 共 49 個測試全過。
- 新增 `MenuCompositionTests`（5 個）：依時間排序（banner 置頂、合併排序、Dashboard 在 footer）、依平台分區（各區標題、列、Dashboard）、分區時失敗只出現在該平台區內、只有一個平台啟用時只顯示該區、沒有任何 token 時兩種版面都顯示 No Token。
- `PreferencesStoreTests`：舊設定（沒有 `cloudflare`／`general`）解碼為 `.byTime`；無法辨識的 `menuLayout` 值退回 `.byTime`。

**實機 smoke**（dev binary 用 Apple Development 身分加上 `-i open-deployment-menu-bar` 簽章；啟動前用 `defaults export` 把舊 domain 與 dev domain 備份到 600 權限的暫存檔，結束後 `defaults import` 還原；沒有送出任何按鍵，只對自己 PID 的 AX 元素做 press／cancel，並用 `screencapture` 截圖）
1. dev domain 原本的設定沒有 `general` key（升級情境）。啟動後選單是依時間排序：Pages 列與 Vercel 列依時間交錯，footer 有兩個 Dashboard 項目。
2. 透過 AX 按下選單中的 Preferences…，畫面顯示 General／Vercel／Cloudflare 三個分頁，「Menu Layout」為 By Time。用 AX 把選單切到 By Platform 後，dev domain 存成 `{"menuLayout":"byPlatform"}`；不重新啟動，再打開選單就已經是「Vercel」區（5 列＋Open Vercel Dashboard）與「Cloudflare」區（qa-odmb-pages 的 5 列＋Open Cloudflare Dashboard）。menu bar 仍顯示 `QA- 1s`，沒有改變。
3. 用拋棄式 Swift helper（同一身分與 identifier 簽章）把 Keychain 的 `cloudflare` 項目備份成 `cloudflare-backup11`，寫入無效值後重新啟動（版面設定維持 By Platform）。menu bar 顯示 `CHA 2m 4s ⚠`。Vercel 區照常顯示；Cloudflare 區只有 banner「Cloudflare API error (400): Invalid request headers (6003)」與 Open Cloudflare Dashboard，選單頂端沒有任何 banner。
4. 收尾：結束 dev app；helper 確認 `cloudflare` 項目與備份相同後刪除備份項目；舊 domain 已還原（`vercelToken` 存在），dev domain 也還原（沒有 `general` key）；helper 與備份檔都已刪除。截圖存在 `/tmp/odmb11-shots/`（`bytime.png`、`prefs-general.png`、`prefs-byplatform.png`、`byplatform.png`、`byplatform-cf-fail.png`）。
- 附帶發現（不在本票範圍，未修）：既有的 `observeAutoSave` 在 `@Published` 發出值時呼叫 `persistPreferences()`，但這時屬性還沒更新，所以存進去的是舊值。版面設定一開始用同樣寫法，實測也存到舊值，因此改成獨立的 sink；其他欄位可能有同樣問題。
