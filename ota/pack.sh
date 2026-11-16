#!/bin/sh
# 打包仪表盘 OTA 更新包（在构建机或 Linux 上运行）
# 用法：
#   ./ota/pack.sh                 # 版本号取 dashboard/VERSION
#   ./ota/pack.sh 20261116-02 "修复某某问题"
# 产物：
#   ota/dist/dashboard-<版本>.tar.gz
#   ota/dist/dashboard.json       # 设备检查更新时读取的清单
set -eu

ROOT=$(cd "$(dirname "$0")/.." && pwd)
VER=${1:-$(cat "$ROOT/dashboard/VERSION")}
NOTES=${2:-"仪表盘更新 $VER"}
# 更新包下载地址前缀（默认走 Gitee，GitHub 保留为备用源）
BASE=${OTA_BASE_URL:-https://gitee.com/xyinmaster/dashboard-ota/raw/main}
OUT="$ROOT/ota/dist"
STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT

mkdir -p "$STAGE/api" "$OUT"
cp "$ROOT/dashboard/index.html" "$STAGE/app.html"
cp "$ROOT/dashboard/loader.html" "$STAGE/index.html"
cp "$ROOT/openwrt/api.uc" "$STAGE/api/api.uc"
printf '%s\n' "$VER" > "$STAGE/VERSION"

TAR="$OUT/dashboard-$VER.tar.gz"
tar -czf "$TAR" -C "$STAGE" app.html index.html api/api.uc VERSION
SHA=$(sha256sum "$TAR" | awk '{print $1}')
SIZE=$(wc -c < "$TAR" | tr -d ' ')

cat > "$OUT/dashboard.json" <<EOF
{
  "version": "$VER",
  "url": "$BASE/dashboard-$VER.tar.gz",
  "sha256": "$SHA",
  "size": $SIZE,
  "notes": "$NOTES",
  "endpoints": ["basic","calibration","configs","lastheard","lhclear","live","log","ota","page","ports","services","status","system","tg","xlxhosts"]
}
EOF

echo "已生成：$TAR"
echo "已生成：$OUT/dashboard.json"
