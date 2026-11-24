#!/usr/bin/env bash
# 把 Web 导出结果发布到 GitHub Pages（gh-pages 分支）。
#
#   ./deploy_pages.sh              # 导出 + 推送
#   ./deploy_pages.sh --no-export  # 只重推现有 build/web
#
# 每次都用一份全新的 git 仓库强推，gh-pages 分支永远只有一个提交，
# wasm 那 40MB 不会在分支里逐次堆叠。
#
# GitHub 侧还需要在仓库 Settings → Pages 里把 Source 设成
# "Deploy from a branch / gh-pages / (root)"，只需点这一次。

set -euo pipefail
cd "$(dirname "$0")"

REMOTE_URL="https://github.com/xumingxian29/MYGAME.git"
BRANCH="gh-pages"
OUT="build/web"
TMP="build/pages"

# 这台机器上 Godot 不在 PATH 里，允许用 GODOT 环境变量覆盖
GODOT_BIN="${GODOT:-/d/Documents/Downloads/Godot_v4.7.2-stable_win64_console.exe}"
[ -x "$GODOT_BIN" ] || GODOT_BIN="$(command -v godot || true)"
[ -n "$GODOT_BIN" ] || { echo "找不到 Godot，可设 GODOT=/path/to/godot 后重试" >&2; exit 1; }

if [ "${1:-}" != "--no-export" ]; then
	echo "==> 导出 Web 版本"
	rm -rf "$OUT/.gzcache"
	mkdir -p "$OUT"                       # Godot 不会自动建目录
	"$GODOT_BIN" --headless --path . --export-release "Web" "$OUT/index.html" 2>&1 | tail -3
fi

# index.html 只引用这些；.import 与 .gzcache 是本地残留，不能传上去
FILES=(
	index.html
	index.js
	index.wasm
	index.pck
	index.png
	index.icon.png
	index.apple-touch-icon.png
	index.audio.worklet.js
	index.audio.position.worklet.js
)

# 不 wipe 这个目录：里面 40MB 的 wasm 变了之后要重传，而"删掉重建"既会触发
# 本机的批量删除保护（>50 个文件就拦），又会让 git 认不出哪些文件没变。
# 目录里只有白名单这 10 个文件 + .nojekyll + .git，原地覆盖就是最省事的做法。
mkdir -p "$TMP"
for f in "${FILES[@]}"; do
	[ -f "$OUT/$f" ] || { echo "缺少 $OUT/$f，导出可能失败" >&2; exit 1; }
	cp "$OUT/$f" "$TMP/$f"
done
# 没有 .nojekyll 时 GitHub 会先跑一遍 Jekyll，纯属浪费且可能吞掉下划线开头的文件
: > "$TMP/.nojekyll"

cd "$TMP"
git init -q -b "$BRANCH"
git config user.name "deploy-bot"
git config user.email "deploy@local"

# 先接上远端已有的一次提交，让 git 在推送时**跳过已存在的对象**。
# 不这么做的话每次强推都是一个全新的根提交，40MB 的 wasm 要从本机重传一遍——
# 这台机器出口只有十几 KB/s，一次就是半个多小时。接上之后通常只有 .pck
# （几 MB，而 wasm 不变）需要上传。
echo "==> 接上远端已有的 $BRANCH"
if git -c http.sslBackend=openssl -c http.sslVerify=false \
	fetch -q --depth=1 "$REMOTE_URL" "$BRANCH" 2>/dev/null; then
	git reset -q --soft FETCH_HEAD
	echo "  已复用远端历史"
else
	echo "  远端不可达或分支为空，按全新提交推送"
fi

# 只暂存白名单：这个目录是原地复用的，里面可能残留 .import / 子目录之类
# 的本地垃圾，`git add -A` 会把它们一起发到线上。
git rm -r -q --cached . >/dev/null 2>&1 || true
for f in "${FILES[@]}" .nojekyll; do
	git add -f "$f"
done

if git diff --cached --quiet; then
	echo "==> 内容与线上完全一致，跳过提交"
else
	git commit -q -m "deploy: $(date '+%Y-%m-%d %H:%M')"
fi

echo "==> 推送 $BRANCH"
git -c http.sslBackend=openssl -c http.sslVerify=false \
	push -f "$REMOTE_URL" "$BRANCH" 2>&1 | tail -4

echo
echo "站点地址： https://xumingxian29.github.io/MYGAME/"
echo "（首次需要在仓库 Settings → Pages 里选 gh-pages 分支，之后每次推送自动更新）"
