#!/bin/bash
#
# 复现 AltServer（macOS 26 / Intel）自编译产物
#
# 用法：
#   ./build.sh /path/to/AltStore-classic
#
# 前提：
#   - Xcode 26.6（最后一个支持 Intel 的版本）
#   - 源码为 AltStore classic 分支 codeload zip 解压后的目录，
#     且 Dependencies/ 下各子模块（AltSign / idevice / libimobiledevice / ...）已就位
#
set -euo pipefail

SRC="${1:-$PWD/AltStore-classic}"
HERE="$(cd "$(dirname "$0")" && pwd)"
DERIVED="${DERIVED:-/tmp/altstore-build}"

if [[ ! -d "$SRC" ]]; then
  echo "✗ 源码目录不存在: $SRC" >&2
  exit 1
fi

echo "==> 1/4 应用源码补丁（anisette 版本门槛 27 → 13）"
if git -C "$SRC" rev-parse --git-dir >/dev/null 2>&1; then
  git -C "$SRC" apply --whitespace=nowarn "$HERE/patches/0001-anisette-remote-on-macos13.patch" \
    || echo "   (已应用过，跳过)"
else
  patch -d "$SRC" -p1 --forward < "$HERE/patches/0001-anisette-remote-on-macos13.patch" \
    || echo "   (已应用过，跳过)"
fi

echo "==> 2/4 覆盖 AltSign / 依赖源码修复层"
# 这些文件无法给出干净的 unified diff（对应上游 commit 未随 classic zip 提供），
# 直接整文件覆盖；每处改动都在文件内以 "PATCHED" 注释标明原因。
rsync -a "$HERE/files/" "$SRC/"

echo "==> 3/4 检查 Xcode"
xcodebuild -version

echo "==> 4/4 编译 AltServer (x86_64, adhoc)"
cd "$SRC"
xcodebuild \
  -workspace AltStore.xcworkspace \
  -scheme AltServer \
  -configuration Release \
  -destination 'platform=macOS' \
  -derivedDataPath "$DERIVED" \
  CODE_SIGN_IDENTITY=- \
  CODE_SIGNING_ALLOWED=YES \
  ARCHS=x86_64 \
  build 2>&1 | tee /tmp/altstore-build.log | tail -60

APP="$DERIVED/Build/Products/Release/AltServer.app"
if [[ -d "$APP" ]]; then
  echo
  echo "✓ 产物: $APP"
  lipo -archs "$APP/Contents/MacOS/AltServer"
  du -sh "$APP"
  echo
  echo "装到 /Applications（官方版留备份）:"
  echo "  mv /Applications/AltServer.app /Applications/AltServer-official.app"
  echo "  cp -R \"$APP\" /Applications/AltServer.app"
  echo
  echo "注意：运行前关掉 Clash/全局代理 —— anisette provisioning 走 WSS，MITM 会掐断 TLS。"
else
  echo "✗ 没找到产物，看 /tmp/altstore-build.log" >&2
  exit 1
fi
