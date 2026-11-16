#!/bin/bash
# 捕词 · 构建脚本
# 用法:
#   ./build.sh            编译 + 打包到 ./dist/捕词.app（通用二进制 arm64 + x86_64）
#   ./build.sh --install  额外安装到 ~/Applications
#   ./build.sh --run      打包后直接启动
#   ARCHS=arm64 ./build.sh  只编译当前架构（调试用，快一些）
#   SIGN_ID="证书名" ./build.sh  指定签名身份（默认用自签名证书，找不到才退回 ad-hoc）
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"

APP_NAME="捕词"
BUNDLE="dist/${APP_NAME}.app"
CONFIG="release"
ARCHS="${ARCHS:-arm64 x86_64}"
SIGN_ID="${SIGN_ID:-Catchword Self Signed}"

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
# 用固定的签名身份，TCC 授权（辅助功能）按证书绑定，重编译不用重新勾选。
# 证书不存在时退回 ad-hoc —— 但那样每次重编译都会掉授权。
if security find-identity -p codesigning 2>/dev/null | grep -q "$SIGN_ID"; then
  codesign --force --deep --sign "$SIGN_ID" --timestamp=none "$BUNDLE" >/dev/null 2>&1 || \
    codesign --force --deep --sign "$SIGN_ID" "$BUNDLE"
  echo "    身份: ${SIGN_ID}（重编译不会掉辅助功能授权）"
else
  codesign --force --deep --sign - --timestamp=none "$BUNDLE" >/dev/null 2>&1 || \
    codesign --force --deep --sign - "$BUNDLE"
  echo "    身份: ad-hoc（找不到「${SIGN_ID}」，每重编译一次需重新勾选辅助功能）"
fi

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
  if security find-identity -p codesigning 2>/dev/null | grep -q "$SIGN_ID"; then
    codesign --force --deep --sign "$SIGN_ID" "$HOME/Applications/${APP_NAME}.app" 2>/dev/null || true
  else
    codesign --force --deep --sign - "$HOME/Applications/${APP_NAME}.app" 2>/dev/null || true
  fi
  echo "==> 已安装到 ~/Applications/${APP_NAME}.app"
fi

if [[ "${1:-}" == "--run" ]]; then
  pkill -x Catchword 2>/dev/null || true
  sleep 0.3
  open "$HOME/Applications/${APP_NAME}.app"
  echo "==> 已启动"
fi
