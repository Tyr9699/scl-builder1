#!/bin/bash
# ============================================================
# SCLAlertView 成品 .dylib 构建脚本（macOS + Xcode + SwiftPM）
# 直接产出可注入/可加载的 Mach-O 动态库，客户拿到即用。
#
# 产物：
#   output/iphoneos/libSCLAlertView.dylib   （真机 arm64）
#   output/simulator/libSCLAlertView.dylib  （模拟器）
# dylib 内固化客户域名/AppID/密钥；被加载时 constructor 自动弹窗。
#
# 用法：
#   ./build_dylib.sh "客户名" "配置URL" "激活URL" "app_id" "密钥" 300
# ============================================================
set -euo pipefail

CUSTOMER="${1:?缺少客户名}"
CONFIG_URL="${2:?缺少配置接口地址}"
ACTIVATE_URL="${3:-}"
APP_ID="${4:?缺少 app_id}"
SECRET="${5:?缺少 HMAC 密钥}"
POLL="${6:-300}"

HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="$HERE/SCLAlertView"
CONFIG_FILE="$SRC/BackendControl/SCLCustomerConfig.swift"
OUT="$HERE/output"

echo "==> 客户: $CUSTOMER / $APP_ID"
echo "==> 配置接口: $CONFIG_URL"

command -v xcodebuild >/dev/null || { echo "!! 需要 macOS + Xcode"; exit 2; }
command -v swift     >/dev/null || { echo "!! 需要 swift"; exit 2; }
command -v python3   >/dev/null || { echo "!! 需要 python3"; exit 2; }

# ---------- 1) 固化客户配置 ----------
python3 - "$CONFIG_FILE" "$CONFIG_URL" "$ACTIVATE_URL" "$APP_ID" "$SECRET" "$POLL" <<'PY'
import sys
path, cfg, act, appid, secret, poll = sys.argv[1:7]
s = open(path, encoding='utf-8').read()
for k, v in {
    '__SCL_CONFIG_URL__': cfg,
    '__SCL_ACTIVATE_URL__': act,
    '__SCL_APP_ID__': appid,
    '__SCL_SECRET__': secret,
    '__SCL_POLL__': poll,
}.items():
    s = s.replace(k, v)
open(path, 'w', encoding='utf-8').write(s)
print('==> 客户配置已固化')
PY

# 用 dylib 专用清单
cp "$HERE/Package-dylib.swift" "$HERE/Package.swift"

# ---------- 2) 清理 ----------
rm -rf "$OUT"
mkdir -p "$OUT/iphoneos" "$OUT/simulator"

# ---------- 3) 编译真机 dylib ----------
echo "==> 编译真机 arm64 dylib ..."
swift build -c release \
  --triple arm64-apple-ios13.0 \
  --scratch-path "$HERE/.build-ios"

# ---------- 4) 编译模拟器 dylib ----------
echo "==> 编译模拟器 dylib ..."
swift build -c release \
  --triple arm64-apple-ios13.0-simulator \
  --scratch-path "$HERE/.build-sim"

# ---------- 5) 取出 dylib ----------
IOS_DYLIB=$(find "$HERE/.build-ios" -name 'libSCLAlertView.dylib' -o -name 'SCLAlertView.dylib' | head -1)
SIM_DYLIB=$(find "$HERE/.build-sim" -name 'libSCLAlertView.dylib' -o -name 'SCLAlertView.dylib' | head -1)

[ -n "$IOS_DYLIB" ] || { echo "!! 未找到真机 dylib"; find "$HERE/.build-ios" -name '*.dylib'; exit 3; }
[ -n "$SIM_DYLIB" ] || { echo "!! 未找到模拟器 dylib"; find "$HERE/.build-sim" -name '*.dylib'; exit 3; }

cp "$IOS_DYLIB" "$OUT/iphoneos/SCLAlertView.dylib"
cp "$SIM_DYLIB" "$OUT/simulator/SCLAlertView.dylib"

# ---------- 6) ad-hoc 签名 ----------
echo "==> ad-hoc 签名 ..."
codesign -f -s - "$OUT/iphoneos/SCLAlertView.dylib" 2>/dev/null || true
codesign -f -s - "$OUT/simulator/SCLAlertView.dylib" 2>/dev/null || true

echo "==> Mach-O 校验："
file "$OUT/iphoneos/SCLAlertView.dylib" "$OUT/simulator/SCLAlertView.dylib"

# ---------- 7) 说明 + 打包 ----------
cat > "$OUT/README.txt" <<EOF
SCLAlertView 成品动态库 (dylib)
================================
客户: $CUSTOMER
App ID: $APP_ID
生成时间: $(date '+%Y-%m-%d %H:%M:%S')

文件：
  iphoneos/SCLAlertView.dylib     真机 arm64
  simulator/SCLAlertView.dylib    模拟器

域名/AppID/密钥已固化进二进制。dylib 被加载时 constructor 自动连接后台并弹窗，
客户无需写任何代码。

使用方式：
  真机（重签名/注入）：把 dylib 放入 App 的 Frameworks 目录，
    用 insert_dylib / optool 添加 LC_LOAD_DYLIB：
      insert_dylib @executable_path/Frameworks/SCLAlertView.dylib <App二进制> --all-yes --weak
    然后 codesign --force --sign <证书> 重签整个 App。
  模拟器调试：DYLD_INSERT_LIBRARIES=/path/to/SCLAlertView.dylib <App> 启动。
  Frida：Module.load('/path/to/SCLAlertView.dylib') 后自动触发。

配置接口: $CONFIG_URL
激活接口: $ACTIVATE_URL
EOF

cat > "$OUT/config.json" <<EOF
{
  "customer": "$CUSTOMER",
  "app_id": "$APP_ID",
  "config_url": "$CONFIG_URL",
  "activate_url": "$ACTIVATE_URL"
}
EOF

PKG="$HERE/SCLAlertView_${CUSTOMER}_${APP_ID}_dylib.zip"
rm -f "$PKG"
(cd "$OUT" && zip -rq "$PKG" . 2>/dev/null || zip -rq "$(basename "$PKG")" .)
echo "==> 完成: $PKG"
ls -lh "$PKG"
