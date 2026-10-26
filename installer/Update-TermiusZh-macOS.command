#!/bin/bash
# macOS Termius 汉化脚本（自动匹配已安装版本）。
#
# 用法：
#   bash Update-TermiusZh-macOS.command                  自动定位并汉化（默认 localize 包）
#   bash Update-TermiusZh-macOS.command --check          只检查，不改动文件
#   bash Update-TermiusZh-macOS.command --trial          用「汉化 + 试用」包
#   bash Update-TermiusZh-macOS.command --skip           用「汉化 + 跳过登录」包
#   bash Update-TermiusZh-macOS.command --version X.Y.Z  指定版本，默认取已装版本
#   bash Update-TermiusZh-macOS.command --app PATH       指定 .app 路径
#
# 参数：
#   --check            只检查版本、链接与熔丝状态，不改动任何文件
#   --trial            汉化包类型：trial，汉化 + 试用（去掉 Upgrade now 等按钮）
#   --skip             汉化包类型：skip，汉化 + 跳过登录（离线可用）
#                      不带 --trial / --skip 时使用 localize，即仅汉化
#   --version <x.y.z>  指定版本，默认取本机 Termius 的 CFBundleShortVersionString。
#                      仅在自动识别失败，或想装与当前不同版本的包时才需要。
#   --app <路径>       指定 .app 位置，默认 /Applications/Termius.app，
#                      不存在时回退到 ~/Applications/Termius.app
#
# 也可直接双击运行（.command 会在终端中打开）。
# 只下载与本机版本号严格对应的包；该版本未发布时直接报错，不会退到相近版本。
# 只用 macOS 自带工具：bash、curl、codesign、PlistBuddy、plutil、shasum、od。
# 会替换 app.asar、更新 plist 里的 asar hash 并重新签名；不创建备份、不自动回滚。

set -euo pipefail

REPO="ArcSurge/Termius-Pro-zh_CN"

FLAVOR="localize"
FLAVOR_SUFFIX=""
BETA=0
BETA_SUFFIX=""
CHECK_ONLY=0
APP_PATH=""
FORCE_VERSION=""
DOWNLOAD=""
CACHE_FILE=""
TMP_DIR=""
STAGED_PATH=""
NEED_SUDO=0
ASAR_WRITTEN=0


# 配置文件与本脚本同目录；不存在时全部使用内置默认值。
CONF_FILE=""

conf_get() {
key=$1
[ -n "$CONF_FILE" ] || return 0
sed -n "s/^[[:space:]]*$key[[:space:]]*=[[:space:]]*//p" "$CONF_FILE" 2>/dev/null \
| sed 's/[[:space:]]*$//' | sed 's/[[:space:]]*#.*$//' | head -n 1
}

say() { printf '%s\n' "$*"; }
die() { printf '错误：%s\n' "$*" >&2; exit 1; }


say "Termius 汉化脚本"
say ""
usage() {
sed -n '2,26p' "$0" | sed 's/^# \{0,1\}//'
}


pause_if_interactive() {
# 管道/自动化调用时不阻塞。
if [ -t 0 ] && [ -t 1 ]; then
printf '\n按回车键关闭此窗口…'
read -r _ || true
fi
}
on_interrupt() {
INTERRUPTED=1
exit 130
}

cleanup() {
rc=$?
trap - EXIT INT TERM HUP
if [ -n "$STAGED_PATH" ] && [ -e "$STAGED_PATH" ]; then
run_write "$RM" -f "$STAGED_PATH" 2>/dev/null || true
fi
if [ -n "$TMP_DIR" ] && [ -d "$TMP_DIR" ]; then
"$RM" -rf "$TMP_DIR" 2>/dev/null || true
fi
if [ "$rc" -ne 0 ]; then
if [ "$INTERRUPTED" -eq 1 ]; then
 if [ -n "$DOWNLOAD" ] && [ -s "$DOWNLOAD" ]; then
   partial_size=$("$STAT" -f%z "$DOWNLOAD" 2>/dev/null || echo 0)
   printf '提示：已手动中断（Ctrl+C）。下载片段（%s MB）已保留，重新运行可续传。\n' "$(awk "BEGIN{printf \"%.1f\", $partial_size / 1048576}")" >&2
 else
   printf '提示：已手动中断（Ctrl+C）。\n' >&2
 fi
elif [ "$ASAR_WRITTEN" -eq 1 ]; then
 printf '汉化未完成（退出码 %s）：app.asar 已被替换。\n' "$rc" >&2
 printf '没有备份也无法自动回滚；如 Termius 无法启动，请用官方安装包重新安装。\n' >&2
else
 printf '汉化未完成（退出码 %s）：应用文件未被修改。\n' "$rc" >&2
fi
pause_if_interactive
fi
exit "$rc"
}
INTERRUPTED=0
trap cleanup EXIT
trap on_interrupt INT TERM HUP

run_write() {
if [ "$NEED_SUDO" -eq 1 ]; then
"$SUDO" "$@"
else
"$@"
fi
}

# ---- 参数 ----------------------------------------------------------------

while [ $# -gt 0 ]; do
case "$1" in
--check|-c|--dry-run) CHECK_ONLY=1 ;;
--trial) FLAVOR="trial"; FLAVOR_SUFFIX="-trial" ;;
--skip) FLAVOR="skip"; FLAVOR_SUFFIX="-skip" ;;
--beta|-b) BETA=1 ;;
--version) shift; [ $# -gt 0 ] || die "--version 需要一个版本号"; FORCE_VERSION=$1 ;;
--version=*) FORCE_VERSION=${1#--version=} ;;
--app) shift; [ $# -gt 0 ] || die "--app 需要一个路径"; APP_PATH=$1 ;;
--app=*) APP_PATH=${1#--app=} ;;
-h|--help) usage; exit 0 ;;
-*) die "未知参数：$1" ;;
*) [ -z "$APP_PATH" ] || die "多余参数：$1"; APP_PATH=$1 ;;
esac
shift
done
say "正在读取配置…"

# ---- 读取配置 ------------------------------------------------------------

self_dir=$(cd "$(dirname "$0")" 2>/dev/null && pwd)
if [ -n "$self_dir" ] && [ -f "$self_dir/TermiusZh.conf" ]; then
CONF_FILE="$self_dir/TermiusZh.conf"
CONF_PACKAGE=$(conf_get package)
CONF_BETA=$(conf_get beta)
CONF_APP_PATH=$(conf_get install_dir)
fi

case "${CONF_BETA:-}" in
yes|YES|Yes|true|TRUE|1|on|ON) BETA=1 ;;
esac

if [ "$BETA" -eq 1 ]; then
BETA_SUFFIX="-beta"
APP_NAME="Termius Beta"
else
BETA_SUFFIX=""
APP_NAME="Termius"
fi

say "正在定位 $APP_NAME.app…"
# ---- 定位 .app -----------------------------------------------------------

# 命令行 --app 优先，其次配置文件 install_dir。
if [ -z "$APP_PATH" ] && [ -n "${CONF_APP_PATH:-}" ]; then
APP_PATH="$CONF_APP_PATH"
fi
if [ -z "$APP_PATH" ]; then
for candidate in "/Applications/$APP_NAME.app" "$HOME/Applications/$APP_NAME.app"; do
if [ -f "$candidate/Contents/Resources/app.asar" ]; then
 APP_PATH=$candidate
 break
fi
done
fi
[ -n "$APP_PATH" ] || die "未找到 $APP_NAME.app。请确认已安装，或用 --app 指定路径。"
[ -d "$APP_PATH" ] || die "应用路径不存在：$APP_PATH"

# 路径名与 beta 设置必须一致；装错版本会导致 Termius 打不开。
case "$APP_PATH" in
*"/Termius Beta.app")
if [ "$BETA" -ne 1 ]; then
 die "应用路径指向 Beta 版（${APP_PATH}），但配置/参数没有启用 Beta。请在配置里设 beta = yes 或用 --beta。"
fi
;;
*"/Termius.app")
if [ "$BETA" -eq 1 ]; then
 die "应用路径指向正式版（${APP_PATH}），但配置/参数启用了 Beta。请改用 Beta 的路径，或关掉 beta 配置。"
fi
;;
esac

ASAR="$APP_PATH/Contents/Resources/app.asar"
INFO_PLIST="$APP_PATH/Contents/Info.plist"
[ -f "$ASAR" ] || die "找不到 app.asar：$ASAR"
[ -f "$INFO_PLIST" ] || die "找不到 Info.plist：$INFO_PLIST"

# ---- 版本与状态 ----------------------------------------------------------

# 测试可覆盖工具路径；真实运行时是系统绝对路径。
PLISTBUDDY=${PLISTBUDDY:-/usr/libexec/PlistBuddy}
PGREP=${PGREP:-/usr/bin/pgrep}
CURL=${CURL:-/usr/bin/curl}
CODESIGN=${CODESIGN:-/usr/bin/codesign}
PLUTIL=${PLUTIL:-/usr/bin/plutil}
OD=${OD:-/usr/bin/od}
SHASUM=${SHASUM:-/usr/bin/shasum}
STAT=${STAT:-/usr/bin/stat}
MKTEMP=${MKTEMP:-/usr/bin/mktemp}
CP=${CP:-/bin/cp}
MV=${MV:-/bin/mv}
CHMOD=${CHMOD:-/bin/chmod}
RM=${RM:-/bin/rm}
DD=${DD:-/bin/dd}
CUT=${CUT:-/usr/bin/cut}
TR=${TR:-/usr/bin/tr}
SUDO=${SUDO:-/usr/bin/sudo}

say "正在检查 $APP_NAME 是否运行…"
# 不能在应用运行时改动它正在读取的文件。
if "$PGREP" -x "$APP_NAME" >/dev/null 2>&1; then
die "请先完全退出 $APP_NAME 再运行。"
fi

# 默认取本机 .app 的版本；用 --version 显式指定时以指定值为准。
if [ -n "$FORCE_VERSION" ]; then
version=$FORCE_VERSION
else
version=$("$PLISTBUDDY" -c 'Print :CFBundleShortVersionString' "$INFO_PLIST" 2>/dev/null || true)
fi

case "$version" in
[0-9]*.[0-9]*.[0-9]*) ;;
*) die "无法识别 Termius 版本（${version:-读取失败}），请用 --version 手动指定。" ;;
esac

if [ -z "$FLAVOR_SUFFIX" ] && [ -n "${CONF_PACKAGE:-}" ]; then
case "$CONF_PACKAGE" in
*.asar)
 # 完整文件名：原样使用，但要校验平台与 Beta 后缀。
 case "$CONF_PACKAGE" in
   app-macos*) ;;
   app-windows*|app-linux*)
     die "配置文件里的 package 是其它平台的包（${CONF_PACKAGE}），macOS 应使用 app-macos 开头的文件名。" ;;
 esac
 case "$CONF_PACKAGE" in
   *-beta.asar)
     [ "$BETA" -eq 1 ] || die "配置文件里的 package 是 Beta 版文件名（${CONF_PACKAGE}），但未启用 Beta。请在配置里设 beta = yes 或用 --beta，或改用正式版文件名。"
     ;;
   *)
     [ "$BETA" -ne 1 ] || die "配置文件里的 package 是正式版文件名（${CONF_PACKAGE}），但已启用 Beta。Beta 版文件名应以 -beta.asar 结尾，例如 app-macos-localize-beta.asar。"
     ;;
 esac
 asset_name="$CONF_PACKAGE"
 ;;
*)
 # 简写：l/t/s 字母组合，自动按平台和 Beta 拼全名。
 case "$CONF_PACKAGE" in
   *[!lts]*)
     die "配置文件里的 package 简写只能用 l / t / s 字母组合，当前为：$CONF_PACKAGE" ;;
 esac
 suffix=""
 case "$CONF_PACKAGE" in
   *l*) suffix="${suffix}-localize" ;;
 esac
 case "$CONF_PACKAGE" in
   *t*) suffix="${suffix}-trial" ;;
 esac
 case "$CONF_PACKAGE" in
   *s*) suffix="${suffix}-skip" ;;
 esac
 asset_name="app-macos${suffix}${BETA_SUFFIX}.asar"
 ;;
esac
else
asset_name="app-macos-localize${FLAVOR_SUFFIX}${BETA_SUFFIX}.asar"
fi
asset_url="https://github.com/$REPO/releases/download/v${version}${BETA_SUFFIX}/$asset_name"

say "正在获取汉化包校验信息…"
# 优先 SHA256SUMS 文件；旧 release 没有，回退解析 release 资产页的 sha256 徽标。
sums_expected=""
sums_txt=$("$CURL" -sfL --retry 2 --connect-timeout 20 --max-time 60 \
"https://github.com/$REPO/releases/download/v${version}${BETA_SUFFIX}/SHA256SUMS-macos.txt" 2>/dev/null || true)
if [ -n "$sums_txt" ]; then
sums_expected=$(printf '%s\n' "$sums_txt" | sed 's/ \*/  /; s/[[:space:]]*$//' \
| grep "  $asset_name\$" | head -n 1 | cut -d ' ' -f 1 || true)
case "$sums_expected" in
[0-9a-f]*) ;;
*) sums_expected="" ;;
esac
fi
if [ -z "$sums_expected" ]; then
sums_page=$("$CURL" -sfL --retry 2 --connect-timeout 20 --max-time 60 \
"https://github.com/$REPO/releases/expanded_assets/v${version}${BETA_SUFFIX}" 2>/dev/null || true)
if [ -n "$sums_page" ]; then
sums_expected=$(printf '%s' "$sums_page" | tr '\n' ' ' | sed 's/<clipboard-copy/\n&/g' \
| sed -n 's/.*digest for \([^"]*\.asar\)".*value="sha256:\([0-9a-f]\{64\}\)".*/\2  \1/p' \
| grep "  $asset_name\$" | head -n 1 | cut -d ' ' -f 1 || true)
fi
fi

say "应用路径 : $APP_PATH"
if [ -n "$FORCE_VERSION" ]; then
say "指定版本 : $version"
else
say "本机版本 : $version"
fi
say "目标版本 : $APP_NAME"
say "汉化包   : $asset_url"

# 本机已装文件与官方包一致时跳过下载。
skip_download=0
if [ -n "$sums_expected" ]; then
local_hash=$("$SHASUM" -a 256 "$ASAR" 2>/dev/null | "$CUT" -d ' ' -f 1)
if [ -n "$local_hash" ] && [ "$local_hash" = "$sums_expected" ]; then
skip_download=1
fi
fi
if [ "$skip_download" -eq 1 ]; then
say "本机文件 : 与官方包一致，跳过下载"
fi

say "正在检查汉化包可用性…"
if [ "$CHECK_ONLY" -eq 1 ]; then
code=$("$CURL" -sSL -o /dev/null -w '%{http_code}' -I --max-time 30 "$asset_url" || true)
case "$code" in
200)
 if [ "$skip_download" -eq 1 ]; then say "汉化包状态: 可用（本机已是该包）"; else say "汉化包状态: 可用"; fi ;;
404) say "汉化包状态: 该版本暂无 $asset_name" ;;
*) say "汉化包状态: 未知（HTTP ${code}）" ;;
esac
say "仅检查：未改动任何文件。去掉 --check 才会真正写入。"
exit 0
fi

if [ "$skip_download" -eq 1 ]; then
exit 0
fi

# ---- 下载 ----------------------------------------------------------------

# 先下载，确认这个版本确有对应汉化包，再申请管理员权限、动本地文件。
cache_key=$(printf '%s' "$asset_url" | "$SHASUM" -a 256 | "$CUT" -d ' ' -f 1)
CACHE_FILE="${TMPDIR:-/tmp}/termius-zh-$cache_key.asar"
DOWNLOAD="$CACHE_FILE.part"
TMP_DIR=$("$MKTEMP" -d "${TMPDIR:-/tmp}/termius-zh.XXXXXXXX") || die "无法创建临时目录。"
ENTITLEMENTS="$TMP_DIR/entitlements.plist"

asset_hash=""
if [ -s "$CACHE_FILE" ]; then
asset_hash=$("$SHASUM" -a 256 "$CACHE_FILE" 2>/dev/null | "$CUT" -d ' ' -f 1)
if [ -n "$asset_hash" ]; then
say "使用已缓存的汉化包，无需下载。"
fi
fi
if [ -z "$asset_hash" ]; then
if [ -s "$DOWNLOAD" ]; then
partial_size=$("$STAT" -f%z "$DOWNLOAD" 2>/dev/null || echo 0)
say "发现未完成的下载（$(awk "BEGIN{printf \"%.1f\", $partial_size / 1048576}") MB），将从断点续传…"
fi

total_bytes=$("$CURL" -sSL -I --max-time 30 "$asset_url" 2>/dev/null \
| grep -i '^[[:space:]]*content-length:' | tail -n 1 | tr -d '\r' | awk '{print $2}')
if [ -n "$total_bytes" ] && [ "$total_bytes" -gt 0 ] 2>/dev/null; then
total_mb=$(( (total_bytes + 524287) / 1048576 ))
say "正在下载汉化包…（共 ${total_mb} MB）"
else
say "正在下载汉化包…"
fi
"$CURL" --fail --location --retry 3 --continue-at - --connect-timeout 20 \
--speed-time 60 --speed-limit 1024 --progress-bar \
--output "$DOWNLOAD" "$asset_url" \
|| die "下载失败：该版本可能尚无 ${asset_name}，或网络不可用。未完成部分已保留，可重试续传。"

[ -s "$DOWNLOAD" ] || { "$RM" -f "$DOWNLOAD"; die "下载文件为空。"; }
size=$("$STAT" -f%z "$DOWNLOAD" 2>/dev/null || echo 0)
if [ "$size" -le 1048576 ]; then
"$RM" -f "$DOWNLOAD"
die "下载文件异常小（$size 字节），可能是错误页面。"
fi
asset_hash=$("$SHASUM" -a 256 "$DOWNLOAD" 2>/dev/null | "$CUT" -d ' ' -f 1)
if [ -n "$sums_expected" ] && [ "$asset_hash" != "$sums_expected" ]; then
"$RM" -f "$DOWNLOAD"
die "下载文件与官方校验值不一致，已删除损坏缓存，请重试下载。"
fi
"$MV" -f "$DOWNLOAD" "$CACHE_FILE"
DOWNLOAD=""
fi

# 下载内容与已装文件一致时不再写文件。
if [ "$("$SHASUM" -a 256 "$ASAR" 2>/dev/null | "$CUT" -d ' ' -f 1)" = "$asset_hash" ]; then
say "本机 app.asar 已是该汉化包，无需改动。"
exit 0
fi

# ---- 管理员权限 ----------------------------------------------------------

check_bundle_writable() {
bundle=$1
case "$bundle" in
*.app) info="$bundle/Contents/Info.plist" ;;
*.framework) info="$bundle/Versions/A/Resources/Info.plist" ;;
*) return 0 ;;
esac
if [ -f "$info" ] && [ ! -w "$info" ]; then NEED_SUDO=1; fi
if [ "${bundle##*.}" = "app" ] && [ -d "$bundle/Contents/Frameworks" ]; then
for child in "$bundle"/Contents/Frameworks/*; do
 [ -e "$child" ] || continue
 check_bundle_writable "$child"
done
fi
}

if [ ! -w "$ASAR" ] || [ ! -w "$APP_PATH/Contents/Resources" ]; then
NEED_SUDO=1
fi
check_bundle_writable "$APP_PATH"
if [ "$NEED_SUDO" -eq 1 ]; then
say "需要管理员权限，macOS 会提示输入密码。"
"$SUDO" -v || die "未获得管理员权限。"
fi

say "正在替换 app.asar…"
# ---- 替换 app.asar -------------------------------------------------------

# 保留原应用签名权限，供重新签名使用。
"$CODESIGN" --display --entitlements - --xml "$APP_PATH" > "$ENTITLEMENTS" 2>/dev/null \
|| die "无法读取应用签名权限。"
"$PLUTIL" -lint "$ENTITLEMENTS" >/dev/null || die "应用签名权限格式无效。"

# 上游 macOS 修复会移除与签名团队绑定的权限，ad-hoc 签名后才能通过校验。
"$PLISTBUDDY" -c 'Delete :com.apple.developer.team-identifier' "$ENTITLEMENTS" >/dev/null 2>&1 || true
"$PLISTBUDDY" -c 'Delete :keychain-access-groups' "$ENTITLEMENTS" >/dev/null 2>&1 || true

# 同卷暂存后单次 rename，避免出现半写入的 app.asar。
STAGED_PATH=$(run_write "$MKTEMP" "$APP_PATH/Contents/Resources/.app.asar.XXXXXXXX") \
|| die "无法在应用内创建暂存文件。"
run_write "$CP" "${DOWNLOAD:-$CACHE_FILE}" "$STAGED_PATH" || die "无法写入暂存文件。"
run_write "$CHMOD" 644 "$STAGED_PATH" || true
run_write "$MV" -f "$STAGED_PATH" "$ASAR" || die "无法替换 app.asar。"
STAGED_PATH=""
ASAR_WRITTEN=1

# ---- 更新 plist 中的 asar hash -------------------------------------------

# asar 头部前 16 字节之后是 header 长度与 JSON 头，Electron 对这段算 SHA256。
header_length=$("$OD" -An -j 12 -N4 -D "$ASAR" | "$TR" -d '[:space:]')
case "$header_length" in
''|*[!0-9]*) die "app.asar 文件头无效，无法更新 hash。" ;;
esac
[ "$header_length" -gt 0 ] || die "app.asar 文件头无效，无法更新 hash。"

asar_hash=$("$DD" bs=1 count="$header_length" skip=16 if="$ASAR" 2>/dev/null \
| "$SHASUM" -a 256 -b | "$CUT" -d ' ' -f 1)
case "$asar_hash" in
[0-9a-f]*) [ ${#asar_hash} -eq 64 ] || die "无法计算 app.asar hash。" ;;
*) die "无法计算 app.asar hash。" ;;
esac

plist_has() { "$PLISTBUDDY" -c "Print $1" "$2" >/dev/null 2>&1; }

update_hash() {
plist=$1
[ -f "$plist" ] || return 0
entry=':ElectronAsarIntegrity:Resources\/app.asar'
if ! plist_has ':ElectronAsarIntegrity' "$plist"; then
run_write "$PLISTBUDDY" -c 'Add :ElectronAsarIntegrity dict' "$plist" || die "无法写入 ${plist}。"
fi
if ! plist_has "$entry" "$plist"; then
run_write "$PLISTBUDDY" -c "Add $entry dict" "$plist" || die "无法写入 ${plist}。"
fi
if ! plist_has "$entry:algorithm" "$plist"; then
run_write "$PLISTBUDDY" -c "Add $entry:algorithm string SHA256" "$plist" || die "无法写入 ${plist}。"
fi
if plist_has "$entry:hash" "$plist"; then
run_write "$PLISTBUDDY" -c "Set $entry:hash $asar_hash" "$plist" || die "无法写入 ${plist}。"
else
run_write "$PLISTBUDDY" -c "Add $entry:hash string $asar_hash" "$plist" || die "无法写入 ${plist}。"
fi
}

update_bundle_hash() {
bundle=$1
case "$bundle" in
*.app) update_hash "$bundle/Contents/Info.plist" ;;
*.framework) update_hash "$bundle/Versions/A/Resources/Info.plist" ;;
*) return 0 ;;
esac
if [ "${bundle##*.}" = "app" ] && [ -d "$bundle/Contents/Frameworks" ]; then
for child in "$bundle"/Contents/Frameworks/*; do
 [ -e "$child" ] || continue
 update_bundle_hash "$child"
done
fi
}
update_bundle_hash "$APP_PATH"

# ---- 重新签名 ------------------------------------------------------------

say "正在重新签名应用…"
run_write "$CODESIGN" --force --sign - --deep --entitlements "$ENTITLEMENTS" "$APP_PATH" \
|| die "重新签名失败。"

say "汉化完成，可以重新打开 ${APP_NAME}。"
say "未保留备份，也无法自动回滚；如需还原请用官方安装包重装。"
