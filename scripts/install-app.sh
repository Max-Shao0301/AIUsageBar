#!/bin/zsh

set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DERIVED_DATA_PATH="$PROJECT_DIR/.build/DerivedData"
CONFIGURATION="Release"
APP_NAME="AIUsageBar.app"
BUILT_APP="$DERIVED_DATA_PATH/Build/Products/$CONFIGURATION/$APP_NAME"
APP_PATH="/Applications/$APP_NAME"
BACKUP_SUFFIX="$(date +%Y%m%d-%H%M%S)"
BACKUP_PATH="/Applications/AIUsageBar.previous.$BACKUP_SUFFIX.app"

echo "==> Build signed $CONFIGURATION app"
xcodebuild \
  -project "$PROJECT_DIR/AIUsageBar.xcodeproj" \
  -scheme "AIUsageBar" \
  -configuration "$CONFIGURATION" \
  -sdk macosx \
  -derivedDataPath "$DERIVED_DATA_PATH" \
  -allowProvisioningUpdates \
  build

if [[ ! -d "$BUILT_APP" ]]; then
  echo "找不到 build 產物: $BUILT_APP"
  exit 1
fi

echo "==> Verify built app signature"
codesign --verify --deep --strict --verbose=2 "$BUILT_APP"

echo "==> Stop running AIUsageBar"
pkill -x AIUsageBar 2>/dev/null || true
sleep 1

if [[ -d "$APP_PATH" ]]; then
  echo "==> Backup current app to $BACKUP_PATH"
  mv "$APP_PATH" "$BACKUP_PATH"
fi

echo "==> Install app to /Applications"
ditto "$BUILT_APP" "$APP_PATH"

echo "==> Verify installed app signature"
codesign --verify --deep --strict --verbose=2 "$APP_PATH"

if [[ -x "$PROJECT_DIR/scripts/fix-widget.sh" ]]; then
  echo "==> Repair widget registration"
  "$PROJECT_DIR/scripts/fix-widget.sh"
fi

echo "==> Launch installed app"
open -a "$APP_PATH"

echo "完成：已重新安裝 $APP_PATH"
