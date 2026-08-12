#!/bin/zsh

set -euo pipefail

APP_PATH="/Applications/AIUsageBar.app"
PLUGIN_PATH="$APP_PATH/Contents/PlugIns/AIUsageWidget.appex"
WIDGET_BUNDLE_ID="max.shao.AIUsageBar.AIUsageWidget"
XCODE_ROOT="$HOME/Library/Developer/Xcode"
PROJECT_BUILD_ROOT="$(cd "$(dirname "$0")/.." && pwd)/.build"

if [[ ! -d "$APP_PATH" ]]; then
  echo "找不到 App: $APP_PATH"
  exit 1
fi

if [[ ! -d "$PLUGIN_PATH" ]]; then
  echo "找不到 Widget: $PLUGIN_PATH"
  exit 1
fi

echo "==> 目前 AIUsageWidget 註冊狀態"
pluginkit -m -A -D -v -p com.apple.widgetkit-extension | rg "$WIDGET_BUNDLE_ID|AIUsageBar|AIUsageWidget" || true

echo "==> 移除正式版 Widget 註冊"
pluginkit -r "$PLUGIN_PATH" || true

if [[ -d "$XCODE_ROOT" ]]; then
  echo "==> 移除 Xcode 暫存/封存殘留 Widget 註冊"
  find "$XCODE_ROOT" -path "*/AIUsageWidget.appex" -print0 2>/dev/null | while IFS= read -r -d '' stale_plugin; do
    pluginkit -r "$stale_plugin" || true
  done
fi

if [[ -d "$PROJECT_BUILD_ROOT" ]]; then
  echo "==> 移除專案本地 build 殘留 Widget 註冊"
  find "$PROJECT_BUILD_ROOT" -path "*/AIUsageWidget.appex" -print0 2>/dev/null | while IFS= read -r -d '' stale_plugin; do
    pluginkit -r "$stale_plugin" || true
  done
fi

echo "==> 重新註冊正式版 Widget"
pluginkit -a "$PLUGIN_PATH"

echo "==> 重啟 WidgetKit 相關服務"
killall pkd 2>/dev/null || true
killall chronod 2>/dev/null || true
killall widgetkitd 2>/dev/null || true
killall NotificationCenter 2>/dev/null || true

sleep 2

echo "==> 驗證修復結果"
pluginkit -m -A -D -v -p com.apple.widgetkit-extension | rg "$WIDGET_BUNDLE_ID|AIUsageBar|AIUsageWidget" || true

echo "==> 重開 AIUsageBar"
open "$APP_PATH" || true

echo "完成。現在可到『編輯小工具』搜尋 AI Usage。"
