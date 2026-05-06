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
│  │  ├─ ClaudeService.swift        # Claude 用量 API（OAuth）
│  │  ├─ CodexUsageService.swift    # Codex 用量 API（OAuth）
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

1. 從 Keychain 取 OAuth token（優先讀 AIUsageBar 自有快取，首次讀取 Claude Code CLI item 並存入快取）。
2. 若 token 過期，先 refresh token。
3. 呼叫 `https://api.anthropic.com/api/oauth/usage`。
4. 若 API 回 401/403，自動清除 Keychain 快取，下次重新從 CLI 取得最新 token。

## Codex 用量流程

1. 讀取 `~/.codex/auth.json` 取得 OAuth token。
2. 若 access token 接近過期，refresh token。
3. 呼叫 `https://chatgpt.com/backend-api/wham/usage`。

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
   - 解壓縮後將 AIUsageBar.app 移至 Applications
   - 打開 APP 會看到「無法打開，因為無法驗證開發者」
   - 至 系統設定 → 隱私權與安全性 往下會看到 AIUsageBar APP → 仍要開啟
   - 首次啟動時會出現 Keychain 授權視窗，輸入一次密碼後點「永遠允許」即可
