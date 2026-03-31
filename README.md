# AIUsageBar 專案說明

## 專案目標

- 這是一個 macOS Menu Bar App，用來整合顯示 Claude 與 Codex 的用量資訊。
- 主介面是上方狀態列圖示 + Popover 視窗。
- 另外提供 Widget（桌面小工具）顯示精簡用量。

## 專案結構

```
AIUsageBar/
├─ AIUsageBar.xcodeproj
├─ AIUsageBar/                      # 主 App
│  ├─ AIUsageBarApp.swift           # SwiftUI App 入口
│  ├─ AppDelegate.swift             # App 啟動流程
│  ├─ Controllers/
│  │  └─ StatusBarController.swift  # 狀態列 icon / 點擊事件 / 右鍵選單
│  ├─ ViewModels/
│  │  └─ UsageViewModel.swift       # 資料抓取協調、狀態管理、定時更新
│  ├─ Views/
│  │  ├─ PopoverView.swift          # 主 Popover UI
│  │  └─ UsageProgressRow.swift     # 進度列元件
│  ├─ Services/
│  │  ├─ ClaudeService.swift        # Claude 用量 API + Cookie fallback
│  │  ├─ CodexUsageService.swift    # Codex OAuth + 本機 Cache fallback
│  │  ├─ ChromeCookieService.swift  # 讀取 Claude session cookie
│  │  ├─ KeychainService.swift      # 讀取/更新 Claude OAuth credentials
│  │  └─ WidgetSnapshotStore.swift  # 將用量快照寫入 App Group
│  ├─ Models/
│  │  ├─ UsageData.swift            # Claude 用量資料模型
│  │  ├─ CodexUsageData.swift       # Codex 用量資料模型
│  │  └─ ClaudeCredentials.swift    # OAuth 憑證模型
│  └─ Assets.xcassets
├─ AIUsageWidget/                   # Widget Extension
│  ├─ AIUsageWidgetBundle.swift     # WidgetBundle 入口
│  ├─ AIUsageWidget.swift           # TimelineProvider + Widget UI
│  └─ AIUsageWidget.entitlements
└─ AIUsageWidget-Info.plist         # Widget extension Info.plist
```

## 主程式執行流程

1. `AIUsageBarApp` 啟動，委派給 `AppDelegate`。
2. `AppDelegate` 設定 `.accessory` 模式（不顯示 Dock），建立 `StatusBarController`。
3. `StatusBarController` 建立狀態列 icon 與 Popover，並綁定 `UsageViewModel`。
4. 左鍵點擊開啟 Popover 時會觸發 `viewModel.refresh()`。
5. `UsageViewModel` 並行抓取 Claude 與 Codex：
    - `async let fetchClaudeResult()`
    - `async let fetchCodexResult()`
6. 成功資料更新畫面；若任一來源失敗則保留既有資料並顯示錯誤訊息。
7. 成功後寫入 Widget snapshot，並通知 Widget 重新載入 timeline。
8. 背景每 5 分鐘自動刷新一次。

## Claude 用量流程

1. 優先走 Claude OAuth（從 Keychain 取 token）。
2. 若 token 過期，先 refresh token。
3. 呼叫 `https://api.anthropic.com/api/oauth/usage`。
4. 若 OAuth 失敗（401/403/429/其他），降級使用 Cookie 策略。
5. Cookie 策略：
    - 從瀏覽器 cookie 取 `sessionKey`
    - 呼叫 `/api/organizations` 取得 orgId
    - 呼叫 `/api/organizations/{orgId}/usage` 取得用量

## Codex 用量流程

1. 優先走 OAuth：讀 `~/.codex/auth.json`。
2. 若 access token 接近過期，refresh token。
3. 呼叫 `https://chatgpt.com/backend-api/wham/usage`。
4. 若 OAuth 失敗，降級讀本機 Cache：
    - 掃描 `~/Library/Application Support/Codex/Cache/Cache_Data`
    - 尋找 wham usage marker
    - 嘗試 Brotli 解壓並 decode `CodexUsageData`

## Widget 流程

1. `UsageViewModel.persistWidgetSnapshot()` 組出 `WidgetUsageSnapshot`。
2. `WidgetSnapshotStore.save()` 寫入 App Group：
    - `~/Library/Group Containers/group.max.shao.AIUsageBar/usage_snapshot.json`
3. 呼叫 `WidgetCenter.shared.reloadTimelines(ofKind: "AIUsageWidget")`。
4. Widget `TimelineProvider` 每 5 分鐘讀一次 snapshot 並更新畫面。

## UI 組成

- 狀態列 icon：`brain.head.profile`（單一 icon，不顯示百分比文字）。
- Popover：
    - Header（標題 + 手動刷新）
    - Claude 區塊（Current Session / Weekly / 可選 Sonnet）
    - Codex 區塊（Current Session / Weekly）
    - Footer（上次更新時間 + 結束）
- Widget：
    - Small：Claude/Codex 5H 簡版
    - Medium：Claude/Codex 並排顯示 Current Session + Weekly

## 安裝方式
- Install:
   -解壓縮後將AIUsageBar.app 移至applications 
   -打開APP會看到 "無法打開，因為無法驗證開法者" 
   -至 系統設定 → 隱私權與安全性 往下會看到AIUsageAPP → 仍要開啟


