#!/bin/bash
# ============================================================
# SCLAlertView 动态库构建脚本（macOS + Xcode）
# 宝塔后台「生成动态库」时下载本 sdk_src 包后执行。
#
# 用法：
#   ./build_dynamic_lib.sh "客户名" \
#     "https://域名/api/config.php?app_id=app_xxx" \
#     "https://域名/api/activate.php" "app_xxx" "密钥" 300
#
# 产物：output/SCLAlertView_<客户名>_<app_id>.zip
#   内含 SCLAlertView.xcframework（真机+模拟器动态库）+ README + config.json
# ============================================================
set -euo pipefail

CUSTOMER="${1:?缺少客户名}"
CONFIG_URL="${2:?缺少配置接口地址}"
ACTIVATE_URL="${3:-}"
APP_ID="${4:?缺少 app_id}"
SECRET="${5:?缺少 HMAC 密钥}"
POLL="${6:-300}"

HERE="$(cd "$(dirname "$0")" && pwd)"
CONFIG_FILE="$HERE/SCLAlertView/BackendControl/SCLCustomerConfig.swift"
OUT="$HERE/output"
BUILD="$HERE/.build"

echo "==> 客户: $CUSTOMER / $APP_ID"
echo "==> 配置接口: $CONFIG_URL"

command -v xcodebuild >/dev/null || { echo "!! 需要 macOS + Xcode（xcodebuild 不存在）"; exit 2; }
command -v python3   >/dev/null || { echo "!! 需要 python3"; exit 2; }

# ---------- 1) 固化客户配置（替换占位符） ----------
python3 - "$CONFIG_FILE" "$CONFIG_URL" "$ACTIVATE_URL" "$APP_ID" "$SECRET" "$POLL" <<'PY'
import sys
path, cfg, act, appid, secret, poll = sys.argv[1:7]
with open(path, 'r', encoding='utf-8') as f:
    s = f.read()
for k, v in {
    '__SCL_CONFIG_URL__': cfg,
    '__SCL_ACTIVATE_URL__': act,
    '__SCL_APP_ID__': appid,
    '__SCL_SECRET__': secret,
    '__SCL_POLL__': poll,
}.items():
    s = s.replace(k, v)
with open(path, 'w', encoding='utf-8') as f:
    f.write(s)
print('==> 占位符已替换为该客户专属配置')
PY

# ---------- 2) 生成 Xcode 工程 ----------
python3 "$HERE/make_xcodeproj.py"

# ---------- 3) 清理旧产物 ----------
rm -rf "$OUT" "$BUILD"
mkdir -p "$OUT"

# ---------- 4) 归档真机 ----------
echo "==> 归档 iphoneos ..."
xcodebuild -project "$HERE/SCLAlertView.xcodeproj" -scheme SCLAlertView \
  -configuration Release -destination 'generic/platform=iOS' \
  -archivePath "$BUILD/ios.xcarchive" \
  BUILD_LIBRARY_FOR_DISTRIBUTION=YES SKIP_INSTALL=NO \
  CODE_SIGNING_ALLOWED=NO archive

# ---------- 5) 归档模拟器 ----------
echo "==> 归档 iphonesimulator ..."
xcodebuild -project "$HERE/SCLAlertView.xcodeproj" -scheme SCLAlertView \
  -configuration Release -destination 'generic/platform=iOS Simulator' \
  -archivePath "$BUILD/sim.xcarchive" \
  BUILD_LIBRARY_FOR_DISTRIBUTION=YES SKIP_INSTALL=NO \
  CODE_SIGNING_ALLOWED=NO archive

# ---------- 6) 合并 XCFramework ----------
echo "==> 生成 XCFramework ..."
xcodebuild -create-xcframework \
  -framework "$BUILD/ios.xcarchive/Products/Library/Frameworks/SCLAlertView.framework" \
  -framework "$BUILD/sim.xcarchive/Products/Library/Frameworks/SCLAlertView.framework" \
  -output "$OUT/SCLAlertView.xcframework"

# ---------- 7) 说明文件 ----------
cat > "$OUT/README.txt" <<EOF
SCLAlertView 客户专属动态库
============================
客户: $CUSTOMER
App ID: $APP_ID
生成时间: $(date '+%Y-%m-%d %H:%M:%S')

本 XCFramework 已固化该客户的域名 / AppID / 密钥，客户无需配置域名。

接入方法：
  1. 将 SCLAlertView.xcframework 拖入 Xcode 工程，Embed & Sign。
  2. AppDelegate 中：
       import SCLAlertView
       SCLBackendController.shared.autoConfigureFromBundle()
       SCLBackendController.shared.bootstrap(on: self.window)
  3. 完成。后台改配置，客户端轮询自动生效。

配置接口: $CONFIG_URL
激活接口: $ACTIVATE_URL
EOF

cat > "$OUT/config.json" <<EOF
{
  "customer": "$CUSTOMER",
  "app_id": "$APP_ID",
  "config_url": "$CONFIG_URL",
  "activate_url": "$ACTIVATE_URL",
  "poll_interval": $POLL
}
EOF

# ---------- 8) 打包 ----------
PKG_NAME="SCLAlertView_${CUSTOMER}_${APP_ID}.zip"
(cd "$OUT" && zip -rq "$PKG_NAME" SCLAlertView.xcframework README.txt config.json)
echo "==> 完成: $OUT/$PKG_NAME"
ls -lh "$OUT/$PKG_NAME"
