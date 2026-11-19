#!/bin/bash
# 捕词 · 构建脚本
# 用法:
#   ./build.sh            编译 + 打包到 ./dist/捕词.app（通用二进制 arm64 + x86_64）
#   ./build.sh --install  额外安装到 ~/Applications
#   ./build.sh --run      打包后直接启动
#   ARCHS=arm64 ./build.sh  只编译当前架构（调试用，快一些）
#   SIGN_ID="证书名" ./build.sh  用指定证书签名（默认 ad-hoc）
#   说明：自签名证书在 TCC 里不被承认，辅助功能列表加不进去，所以默认走 ad-hoc。
#   ad-hoc 的签名值随二进制变化，重新编译后需要在系统设置里重勾一次授权。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"

APP_NAME="捕词"
BUNDLE="dist/${APP_NAME}.app"
CONFIG="release"
ARCHS="${ARCHS:-arm64 x86_64}"
SIGN_ID="${SIGN_ID:-}"

ARCH_FLAGS=()
for a in $ARCHS; do
  ARCH_FLAGS+=(--arch "$a")
done

echo "==> 编译 (${CONFIG}, ${ARCHS})"
swift build -c "$CONFIG" "${ARCH_FLAGS[@]}"

BIN_PATH="$(swift build -c "$CONFIG" "${ARCH_FLAGS[@]}" --show-bin-path)/Catchword"
if [ ! -f "$BIN_PATH" ]; then
  echo "!! 找不到可执行文件: $BIN_PATH" >&2
  exit 1
fi

echo "==> 组装 App Bundle"
rm -rf "$BUNDLE"
mkdir -p "$BUNDLE/Contents/MacOS" "$BUNDLE/Contents/Resources"
cp "$BIN_PATH" "$BUNDLE/Contents/MacOS/Catchword"
cp Resources/Info.plist "$BUNDLE/Contents/Info.plist"
if [ -f Resources/AppIcon.icns ]; then
  cp Resources/AppIcon.icns "$BUNDLE/Contents/Resources/AppIcon.icns"
  /usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string AppIcon" "$BUNDLE/Contents/Info.plist" 2>/dev/null || true
fi

echo "==> 签名"
# 默认走 ad-hoc。自签名证书虽然能让签名值固定，但 TCC 不认这种证书 ——
# 辅助功能列表里根本加不进去，反而更糟。要用：SIGN_ID="证书名" ./build.sh
if [ -n "$SIGN_ID" ] && security find-identity -p codesigning 2>/dev/null | grep -q "$SIGN_ID"; then
  codesign --force --deep --sign "$SIGN_ID" --timestamp=none "$BUNDLE" >/dev/null 2>&1 || \
    codesign --force --deep --sign "$SIGN_ID" "$BUNDLE"
  echo "    身份: ${SIGN_ID}"
else
  codesign --force --deep --sign - --timestamp=none "$BUNDLE" >/dev/null 2>&1 || \
    codesign --force --deep --sign - "$BUNDLE"
  echo "    身份: ad-hoc（签名值随二进制变化，重新编译后需在系统设置里重勾一次授权）"
fi

# 记下签名值，安装时用来判断授权条目是不是已经过期
CDHASH="$(codesign -dv --verbose=4 "$BUNDLE" 2>&1 | awk -F= '/^CDHash=/{print $2}')"

echo "==> 校验"
lipo -archs "$BUNDLE/Contents/MacOS/Catchword" | sed 's/^/    架构: /'
otool -l "$BUNDLE/Contents/MacOS/Catchword" | awk '/minos/{print "    最低系统: "$2; exit}'
if otool -L "$BUNDLE/Contents/MacOS/Catchword" | grep -qi "Translation.framework.*weak"; then
  echo "    Translation.framework: 弱链接（macOS 12 上不会因缺库启动失败）"
fi

echo "==> 完成: $BUNDLE"
du -sh "$BUNDLE"

if [[ "${1:-}" == "--install" || "${1:-}" == "--run" ]]; then
  mkdir -p "$HOME/Applications"
  rm -rf "$HOME/Applications/${APP_NAME}.app"
  cp -R "$BUNDLE" "$HOME/Applications/${APP_NAME}.app"
  # 重新签名，避免拷贝破坏签名
  if [ -n "$SIGN_ID" ] && security find-identity -p codesigning 2>/dev/null | grep -q "$SIGN_ID"; then
    codesign --force --deep --sign "$SIGN_ID" "$HOME/Applications/${APP_NAME}.app" 2>/dev/null || true
  else
    codesign --force --deep --sign - "$HOME/Applications/${APP_NAME}.app" 2>/dev/null || true
  fi
  echo "==> 已安装到 ~/Applications/${APP_NAME}.app"

  # ad-hoc 重签后签名值会变，系统里留着的旧授权条目就成了幽灵 —— 列表里可能好几个「捕词」，
  # 勾哪个都不对。清掉它们，用户点「去授权」才能干净地把当前这个包装进列表。
  if [ -n "$CDHASH" ] && [ "$CDHASH" != "$(cat dist/.signed-cdhash 2>/dev/null || true)" ]; then
    tccutil reset Accessibility com.fw.catchword >/dev/null 2>&1 || true
    printf '%s' "$CDHASH" > dist/.signed-cdhash
    echo "    签名值已变化 → 已清理旧的辅助功能授权记录，需要重新勾选一次"
  fi
fi

if [[ "${1:-}" == "--run" ]]; then
  pkill -x Catchword 2>/dev/null || true
  sleep 0.3
  open "$HOME/Applications/${APP_NAME}.app"
  echo "==> 已启动"
fi
