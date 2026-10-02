# 04: Token 存 Keychain

**What to build:** Token 不再以明文存在 UserDefaults。Vercel token 改存 Keychain，依平台區分項目（Cloudflare token 在 05 使用同一機制）。升級時把既有 Vercel token 從 UserDefaults 的偏好設定搬入 Keychain；確認 Keychain 寫入成功後，才從新、舊兩個 bundle ID（`com.1orzero.open-deployment-menu-bar` 與 `com.andrew.vercel-deployment-menu-bar`）的 UserDefaults 清除 token。寫入失敗時保留原值，下次啟動重試。偏好設定的 token 欄位直接讀寫 Keychain。

**Blocked by:** 01 改名為 Open Deployment Menu Bar

**Status:** ready-for-agent

- [x] 升級後 Vercel token 仍有效，menu bar 照常抓資料
- [x] 新、舊兩個 bundle ID 的 preferences plist 都不再含 token（01 從舊 domain 複製設定後，舊 domain 仍留有明文 token）
- [x] Keychain 寫入失敗時（以可注入的失敗 Keychain 做單元測試），兩個 domain 的 token 原值都保留
- [x] 清空 token 欄位會刪除 Keychain 項目，menu bar 顯示 No Token
- [x] ad-hoc 簽章下重新 build 後，記錄 Keychain 是否跳出授權提示，寫進完成說明

## 完成說明

**設計**
- 新檔 `TokenStore.swift`：`TokenAccount`（目前只有 `vercel`，05 加 `cloudflare`）、`TokenStore` protocol（`token(for:)`／`setToken(_:for:)`／`deleteToken(for:)`）、`KeychainTokenStore`（generic password，service 固定為 `com.1orzero.open-deployment-menu-bar`，account 為平台名稱；未打包的 dev binary 沒有 bundle ID，所以不從 bundle 推導）。寫入先 `SecItemUpdate`，找不到再 `SecItemAdd`；刪除不存在的項目視為成功。
- `Preferences` 移除 `vercelToken`／`hasToken`。舊 JSON 仍含 `vercelToken` 也能解碼（Codable 忽略多餘 key）。
- `PreferencesStore` 注入 `TokenStore`，提供 `token(for:)`（記憶體快取，輪詢不必每次讀 Keychain）與 `setToken(_:for:)`（trim 後寫入；空字串則刪除；成功後送出 didChange 通知）。
- 遷移（啟動時、從舊 domain 複製設定之後）：在新 domain 或舊 domain 的 JSON 找 `vercelToken`，優先用新 domain 的非空值；Keychain 已有 token 就不覆寫。只有寫入成功（或 Keychain 本來就有）才用 JSONSerialization 從兩個 domain 的 JSON 拿掉 `vercelToken`，其他 key（含舊 domain 獨有的）原樣保留。寫入失敗則兩邊都不動，下次啟動重試；這段期間存其他設定時也會保留新 domain 的明文 token。
- `DeploymentService.fetchAllDeployments(preferences:token:)` 改由呼叫端傳 token；`StatusItemController` 在主執行緒讀 `PreferencesStore.shared.token(for: .vercel)`，nil 就顯示 No Token。移除不再使用的 `APIError.missingToken`。
- 偏好設定的 token 欄位初值來自 Keychain，每次變更直接呼叫 `store.setToken`（清空即刪除）；寫入失敗時欄位下方顯示「Couldn’t save token: …」。

**測試**（`PreferencesStoreTests`，注入 UserDefaults suite 與 in-memory／failing store）：遷移成功清掉兩個 domain 的 token 並保留其他設定（含舊 domain 獨有 key）、只有舊 domain 有 token 時也會遷移、寫入失敗時兩個 domain 的資料 byte 不變且之後存設定仍保留明文 token、Keychain 已有 token 不覆寫但仍清掉明文、清空 token 會刪除。`swift build`、`swift test`（17 tests）通過。

**實機 smoke**（先 `defaults export` 備份舊 domain 到 600 權限的暫存檔，結束後 `defaults import` 還原並刪除備份；只檢查 key 是否存在，不印出值）
1. 啟動前：Keychain 無項目（exit 44）；舊 domain 與 dev domain（`open-deployment-menu-bar`）都有非空 `vercelToken`。
2. 啟動 `.build/debug/open-deployment-menu-bar` 後：`security find-generic-password -s com.1orzero.open-deployment-menu-bar -a vercel` exit 0；兩個 domain `tokenKey=False`，其餘 13 個 key 仍在；menu bar 截圖出現新 item「▲ ✓ CHA 55s」，與舊 app 顯示同一筆部署，代表用 Keychain token 照常抓資料。
3. 用 `security delete-generic-password` 刪除 Keychain 項目後啟動：menu bar 顯示 `key.slash` 圖示＋「No Token」。（欄位清空 → `store.setToken("")` → 刪除項目這段由單元測試涵蓋，沒有在 GUI 實際點偏好設定視窗。）
4. 還原舊 domain（只有舊 domain 有 token、dev domain 已有設定）後啟動：再次從舊 domain 遷入 Keychain，兩個 domain 都清掉 token，menu bar 照常顯示部署。
5. 最後還原舊 domain：`tokenKey=True tokenNonEmpty=True`，備份檔已刪除，舊 app 持續執行。dev domain 保持已遷移狀態，Keychain 保留 dev 用的 Vercel token 項目。

**ad-hoc 重新 build 後的授權提示**：會跳出。暫時加一個檔案讓 binary 真的改變後重新 build（cdhash `b008ae…` → `3da2cd…`，只 `touch` 不會改 cdhash），重新啟動時出現 `SecurityAgent` process，dev app 的 menu bar item 在提示期間完全沒出現（`SecItemCopyMatching` 在主執行緒等待授權）。全螢幕截圖拍不到對話框（系統安全視窗不會被 screencapture 拍下）。約 10–20 秒後 SecurityAgent 結束、item 開始顯示部署；之後 `security dump-keychain -a` 顯示項目的 trusted applications 與 partition_id 已同時列入兩個 cdhash，代表有人在提示上選了「Always Allow」（不是我點的）。結論：ad-hoc 簽章的每個新 build 第一次讀 token 都會跳 Keychain 授權提示，期間 menu bar 卡住；改回原始碼後 cdhash 回到 `b008ae…`（已在 ACL 內）。
