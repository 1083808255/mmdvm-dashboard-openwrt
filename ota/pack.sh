#!/bin/sh
# 打包仪表盘 OTA 更新包（在构建机或 Linux 上运行）
# 用法：
#   ./ota/pack.sh                 # 版本号取 dashboard/VERSION
#   ./ota/pack.sh V0.666 "修复某某问题"
# 产物：
#   ota/dist/dashboard-<版本>.tar.gz
#   ota/dist/dashboard.json       # 设备检查更新时读取的清单
#   ota/dist/dashboard.json.gh    # GitHub 备用源清单
set -eu

ROOT=$(cd "$(dirname "$0")/.." && pwd)
VER=$(printf '%s' "${1:-$(cat "$ROOT/dashboard/VERSION")}" | tr -d '\r\n' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
NOTES=${2:-"仪表盘更新 $VER"}
# 更新包下载地址前缀（默认走 Gitee，GitHub 保留为备用源）
BASE=${OTA_BASE_URL:-https://gitee.com/xyinmaster/dashboard-ota/raw/main}
GH_BASE=${OTA_GH_BASE_URL:-https://ghproxy.net/https://raw.githubusercontent.com/1083808255/dashboard-ota/main}
OUT="$ROOT/ota/dist"
STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT

die() { echo "错误：$*" >&2; exit 1; }
json_escape() {
  printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e ':a' -e 'N' -e '$!ba' -e 's/\n/\\n/g'
}

# 版本与路径安全校验：版本号会进入 tar 文件名和 JSON，不能带路径分隔符/引号
case "$VER" in
  ''|*[!A-Za-z0-9._-]*) die "版本号不合法：$VER（只允许字母、数字、点、下划线、连字符）" ;;
esac
case "$BASE$GH_BASE" in
  *'"'*|*'\'*) die "更新源地址含有非法字符" ;;
esac

# 双源必须一致，否则发版后设备与包内代码会漂移
cmp -s "$ROOT/dashboard/index.html" "$ROOT/firmware-build/packages/mmdvm-dashboard/files/www-dash/app.html" \
  || die "dashboard/index.html 与包内 app.html 不一致"
cmp -s "$ROOT/openwrt/api.uc" "$ROOT/firmware-build/packages/mmdvm-dashboard/files/www-dash/api/api.uc" \
  || die "openwrt/api.uc 与包内 api/api.uc 不一致"
cmp -s "$ROOT/dashboard/VERSION" "$ROOT/firmware-build/packages/mmdvm-dashboard/files/www-dash/VERSION" \
  || die "dashboard/VERSION 与包内 VERSION 不一致"

# 同一版本已经发布时拒绝覆盖，避免旧设备因 otaNewer() 判断同版本而不升级
if [ -f "$OUT/dashboard.json" ] && grep -q "\"version\": \"$VER\"" "$OUT/dashboard.json"; then
  die "版本 $VER 已存在于 ota/dist/dashboard.json，请递增版本后再打包"
fi

mkdir -p "$STAGE/api" "$OUT"
cp "$ROOT/dashboard/index.html" "$STAGE/app.html"
cp "$ROOT/dashboard/loader.html" "$STAGE/index.html"
cp "$ROOT/openwrt/api.uc" "$STAGE/api/api.uc"
printf '%s\n' "$VER" > "$STAGE/VERSION"

TAR="$OUT/dashboard-$VER.tar.gz"
tar -czf "$TAR" -C "$STAGE" app.html index.html api/api.uc VERSION
SHA=$(sha256sum "$TAR" | awk '{print $1}')
SIZE=$(wc -c < "$TAR" | tr -d ' ')

# 打包后自检：tar 内源码必须与当前源码逐字节一致
rm -rf "$STAGE/check"
mkdir -p "$STAGE/check"
tar -xzf "$TAR" -C "$STAGE/check"
cmp -s "$STAGE/check/app.html" "$ROOT/dashboard/index.html" || die "包内 app.html 与源码不一致"
cmp -s "$STAGE/check/api/api.uc" "$ROOT/openwrt/api.uc" || die "包内 api.uc 与源码不一致"
cmp -s "$STAGE/check/VERSION" "$ROOT/dashboard/VERSION" || die "包内 VERSION 与源码不一致"

J_VER=$(json_escape "$VER")
J_NOTES=$(json_escape "$NOTES")
J_SHA=$(json_escape "$SHA")
J_URL=$(json_escape "$BASE/dashboard-$VER.tar.gz")
J_GH_URL=$(json_escape "$GH_BASE/dashboard-$VER.tar.gz")

write_manifest() {
  _out=$1
  _url=$2
  cat > "$_out" <<EOF
{
  "version": "$J_VER",
  "url": "$_url",
  "sha256": "$J_SHA",
  "size": $SIZE,
  "notes": "$J_NOTES",
  "endpoints": ["auth","basic","calibration","configs","fw","lastheard","lhclear","live","livecfg","log","luci","ota","page","ports","services","status","system","tg","wifi","xlxhosts"]
}
EOF
}

write_manifest "$OUT/dashboard.json" "$J_URL"
write_manifest "$OUT/dashboard.json.gh" "$J_GH_URL"

echo "已生成：$TAR"
echo "已生成：$OUT/dashboard.json"
echo "已生成：$OUT/dashboard.json.gh"
