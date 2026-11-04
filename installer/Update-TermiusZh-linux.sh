#!/bin/sh
# Linux Termius 汉化脚本（自动匹配已安装版本）。
#
# 用法：
#   bash Update-TermiusZh-linux.sh                   自动定位并汉化（默认 localize 包）
#   bash Update-TermiusZh-linux.sh --check           只检查，不改动文件
#   bash Update-TermiusZh-linux.sh --trial           用「汉化 + 试用」包
#   bash Update-TermiusZh-linux.sh --skip            用「汉化 + 跳过登录」包
#   bash Update-TermiusZh-linux.sh --package ltk     用简写指定组合包（trial + skip）
#   bash Update-TermiusZh-linux.sh --version X.Y.Z   指定版本，默认取已装版本
#   bash Update-TermiusZh-linux.sh --dir PATH        指定安装目录
#   bash Update-TermiusZh-linux.sh --beta            操作 Termius Beta
#
# 参数：
#   --check            只检查版本、链接与熔丝状态，不改动任何文件
#   --trial            汉化包类型：trial，汉化 + 试用（去掉 Upgrade now 等按钮）
#   --skip             汉化包类型：skip，汉化 + 跳过登录（离线可用）
#                      不带 --trial / --skip / --package 时使用 localize，即仅汉化
#   --package <简写>   用 l/t/k 简写指定组合包，优先级高于 --trial / --skip，
#                      也覆盖配置文件里的 package。例如 ltk 表示 trial + skip。
#   --version <x.y.z>  指定版本，默认取本机已安装 Termius 的版本号。
#                      仅在自动识别失败，或想装与当前不同版本的包时才需要。
#   --dir <路径>       指定安装目录，默认 /opt/Termius（Beta 为 /opt/Termius Beta）
#   --beta             操作 Termius Beta
#
# 只下载与本机版本号严格对应的包；该版本未发布时直接报错，不会退到相近版本。
# 只用系统自带工具：sh、curl、grep、dd、sha256sum、ps、mktemp。
# 会替换 app.asar 并关闭 asar 完整性熔丝；不创建备份、不自动回滚。

set -eu


REPO="ArcSurge/Termius-Pro-zh_CN"

# Electron fuse wire format: sentinel, version byte, count byte, then one state
# byte per fuse. Index 4 is EnableEmbeddedAsarIntegrityValidation:
# 0x31 ('1') = enabled, 0x30 ('0') = disabled.
FUSE_SENTINEL="dL7pKGdnNz796PbbjQWNKmHXBZaB9tsX"
FUSE_INDEX=4

CHECK_ONLY=0
BETA=0
# 包类型只有一个来源：CLI_PACKAGE（命令行简写）或 CONF_PACKAGE（配置）。
# --trial / --skip 只是把 -trial / -skip 换算成简写 t / k，不再单独维护状态。
INSTALL_DIR=""
FORCE_VERSION=""
PKG_NAME="termius-app"

CONF_PACKAGE=""
CONF_BETA=""
CONF_INSTALL_DIR=""
CONF_FILE=""

# 读取配置文件里 key = value 形式的行，忽略注释与空行。
conf_get() {
key=$1
[ -n "$CONF_FILE" ] || return 0
sed -n "s/^[[:space:]]*$key[[:space:]]*=[[:space:]]*//p" "$CONF_FILE" 2>/dev/null \
| sed 's/[[:space:]]*$//' | sed 's/[[:space:]]*#.*$//' | head -n 1
}

DOWNLOAD=""
CACHE_FILE=""
sums_expected=""
CLI_PACKAGE=""
CLI_PACKAGE_SRC=""
INTERRUPTED=0
NEED_SUDO=0
ASAR_WRITTEN=0
EXE_WRITTEN=0

say() {
printf '%s\n' "$*"
}

die() {
printf '错误：%s\n' "$1" >&2
exit 1
}

# 字节数 -> "12.3 MB"。只用 shell 整数运算，不依赖 awk 的浮点格式化。
mb_text() {
mb_bytes=${1:-}
case "$mb_bytes" in
''|*[!0-9]*) printf '未知大小'; return 0 ;;
esac
mb_tenths=$(( (mb_bytes * 10 + 524288) / 1048576 ))
printf '%s.%s MB' "$((mb_tenths / 10))" "$((mb_tenths % 10))"
}


say "Termius 汉化脚本"
say ""
# 中断后不再等回车，否则第二次 Ctrl+C 会卡在等待输入上。
ask() {
[ "${INTERRUPTED:-0}" -eq 0 ] || return 0
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
if [ "$rc" -ne 0 ]; then
if [ "$INTERRUPTED" -eq 1 ]; then
if [ -n "$DOWNLOAD" ] && [ -s "$DOWNLOAD" ] && [ -z "$sums_expected" ]; then
  printf '提示：已手动中断（Ctrl+C）。该版本没有官方校验值，重新运行会从头下载。\n' >&2
elif [ -n "$DOWNLOAD" ] && [ -s "$DOWNLOAD" ]; then
  partial_size=$(wc -c < "$DOWNLOAD" | tr -d ' ')
  printf '提示：已手动中断（Ctrl+C）。下载片段（%s）已保留，重新运行可续传。\n' "$(mb_text "$partial_size")" >&2
else
  printf '提示：已手动中断（Ctrl+C）。\n' >&2
fi
elif [ "$ASAR_WRITTEN" -eq 1 ] || [ "$EXE_WRITTEN" -eq 1 ]; then
printf '汉化未完成（退出码 %s）：Termius 文件已被改动。\n' "$rc" >&2
printf '没有备份也无法自动回滚；如 Termius 无法启动，请用官方安装包重新安装。\n' >&2
else
printf '汉化未完成（退出码 %s）：Termius 文件未被修改。\n' "$rc" >&2
fi
ask
fi
exit "$rc"
}
trap cleanup EXIT
trap on_interrupt INT TERM HUP
need_cmd() {
command -v "$1" >/dev/null 2>&1 || die "缺少必需命令：$1"
}

as_root() {
if [ "$NEED_SUDO" -eq 1 ]; then
sudo "$@"
else
"$@"
fi
}

# ---- arguments -------------------------------------------------------------

while [ $# -gt 0 ]; do
case "$1" in
--check|--check-only|-c|--dry-run) CHECK_ONLY=1 ;;
--trial) CLI_PACKAGE="t"; CLI_PACKAGE_SRC="--trial" ;;
--skip) CLI_PACKAGE="k"; CLI_PACKAGE_SRC="--skip" ;;
--package) shift; [ $# -gt 0 ] || die "--package 需要一个简写（l / t / k 组合）"; CLI_PACKAGE=$1; CLI_PACKAGE_SRC="--package $1" ;;
--package=*) CLI_PACKAGE=${1#--package=}; CLI_PACKAGE_SRC="--package ${1#--package=}" ;;
-p) shift; [ $# -gt 0 ] || die "-p 需要一个简写（l / t / k 组合）"; CLI_PACKAGE=$1; CLI_PACKAGE_SRC="-p $1" ;;
-p=*) CLI_PACKAGE=${1#-p=}; CLI_PACKAGE_SRC="-p ${1#-p=}" ;;
--beta|-b) BETA=1; PKG_NAME="termius-beta"; EXE_NAME="termius-beta" ;;
--version) shift; [ $# -gt 0 ] || die "--version 需要一个版本号"; FORCE_VERSION=$1 ;;
--version=*) FORCE_VERSION=${1#--version=} ;;
--dir) shift; [ $# -gt 0 ] || die "--dir 需要一个路径"; INSTALL_DIR=$1 ;;
--dir=*) INSTALL_DIR=${1#--dir=} ;;
-h|--help) sed -n '2,28p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
-*) die "未知参数：$1" ;;
*) [ -z "$INSTALL_DIR" ] || die "多余参数：$1"; INSTALL_DIR=$1 ;;
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
CONF_INSTALL_DIR=$(conf_get install_dir)
fi

case "${CONF_BETA:-}" in
yes|YES|Yes|true|TRUE|1|on|ON) BETA=1; PKG_NAME="termius-beta"; EXE_NAME="termius-beta" ;;
esac

if [ "$BETA" -eq 1 ]; then
BETA_SUFFIX="-beta"
else
BETA_SUFFIX=""
fi

# 命令行 --dir 优先，其次配置文件 install_dir。
if [ -z "$INSTALL_DIR" ] && [ -n "$CONF_INSTALL_DIR" ]; then
INSTALL_DIR="$CONF_INSTALL_DIR"
fi

# 命令行 --package 最优先：它给出完整的 l/t/k 组合，能表达 --trial / --skip
# 单独做不到的 trial + skip。给了它就等价于读到一个配置 package。
ORIG_CONF_PACKAGE=$CONF_PACKAGE
if [ -n "$CLI_PACKAGE" ]; then
CONF_PACKAGE="$CLI_PACKAGE"
fi

# ---- locate the installation ----------------------------------------------

EXE_NAME="${EXE_NAME:-termius-app}"
PKG_NAME="${PKG_NAME:-termius-app}"
APP_LABEL="$( [ "$BETA" -eq 1 ] && printf 'Termius Beta' || printf 'Termius' )"


say "正在定位 $APP_LABEL…"
if [ -z "$INSTALL_DIR" ]; then
if [ "$BETA" -eq 1 ]; then
candidate="/opt/Termius Beta"
else
candidate="/opt/Termius"
fi
if [ -f "$candidate/resources/app.asar" ]; then
INSTALL_DIR=$candidate
fi
fi
[ -n "$INSTALL_DIR" ] || die "未找到 ${APP_LABEL}。请确认已安装，或用 --dir 指定安装目录。"

INSTALL_DIR=$(cd "$INSTALL_DIR" 2>/dev/null && pwd) || die "安装目录不存在：$INSTALL_DIR"

# 路径名与 beta 设置必须一致；装错版本会导致 Termius 打不开。
case "$INSTALL_DIR" in
*"/Termius Beta")
if [ "$BETA" -ne 1 ]; then
die "安装路径指向 Beta 版（${INSTALL_DIR}），但配置/参数没有启用 Beta。请在配置里设 beta = yes 或用 --beta。"
fi
;;
*"/Termius")
if [ "$BETA" -eq 1 ]; then
die "安装路径指向正式版（${INSTALL_DIR}），但配置/参数启用了 Beta。请改用 Beta 的路径，或关掉 beta 配置。"
fi
;;
esac

ASAR="$INSTALL_DIR/resources/app.asar"
EXE="$INSTALL_DIR/$EXE_NAME"
[ -f "$ASAR" ] || die "找不到 app.asar：$ASAR"
[ -f "$EXE" ] || die "找不到主程序：$EXE"

# ---- installed version -----------------------------------------------------

version="${FORCE_VERSION:-}"

# The package database is authoritative and cannot drift from /opt.
if [ -z "$version" ] && command -v dpkg-query >/dev/null 2>&1; then
version=$(dpkg-query -W -f='${Version}' "$PKG_NAME" 2>/dev/null | sed 's/^[0-9]*://' | sed 's/[-+~].*$//' || true)
fi
if [ -z "$version" ] && command -v rpm >/dev/null 2>&1; then
version=$(rpm -q --qf '%{VERSION}' "$PKG_NAME" 2>/dev/null | sed 's/[-+~].*$//' || true)
fi

# Last resort: the binary banner, which looks like "10.2.1" or "Termius 10.2.1".
if [ -z "$version" ]; then
banner=$("$EXE" --version 2>/dev/null | head -n 1 || true)
version=$(printf '%s' "$banner" | grep -Eo '([0-9]+\.){2}[0-9]+' | head -n 1 || true)
fi

case "$version" in
[0-9]*.[0-9]*.[0-9]*) ;;
*) die "无法识别 Termius 版本（${version:-读取失败}），请用 --version 手动指定。" ;;
esac

tag="v$version$BETA_SUFFIX"

# 包类型只有一个来源：CLI_PACKAGE（--package / --trial / --skip 归一化后的简写）
# 或 CONF_PACKAGE（配置文件）。CLI_PACKAGE 优先，两者择一后走同一套拼名逻辑。
if [ -n "$CLI_PACKAGE" ]; then
asset_source="$CLI_PACKAGE"
else
asset_source="$CONF_PACKAGE"
fi

if [ -n "$asset_source" ]; then
case "$asset_source" in
*.asar)
# 完整文件名：原样使用，但要校验平台与 Beta 后缀。
case "$asset_source" in
  app-linux*) ;;
  app-windows*|app-macos*)
    die "package 是其它平台的包（${asset_source}），Linux 应使用 app-linux 开头的文件名。" ;;
esac
case "$asset_source" in
  *-beta.asar)
    [ "$BETA" -eq 1 ] || die "package 是 Beta 版文件名（${asset_source}），但未启用 Beta。请在配置里设 beta = yes 或用 --beta，或改用正式版文件名。"
    ;;
  *)
    [ "$BETA" -ne 1 ] || die "package 是正式版文件名（${asset_source}），但已启用 Beta。Beta 版文件名应以 -beta.asar 结尾，例如 app-linux-localize-beta.asar。"
    ;;
esac
asset="$asset_source"
;;
*)
# 简写沿用上游 lang.py 的参数名：l=汉化，t=试用，k=跳过登录，可自由组合。
# 上游拼名规则是 app-<平台>-<按组合顺序的功能>.asar，且默认组合（l / lk / lt）
# 都以 localize 开头：localize-trial、localize-skip。因此这里忽略 l 的书写顺序，
# 统一拼成 localize[-trial][-skip]，与线上资产名一致。
case "$asset_source" in
  *[!ltk]*)
    die "package 简写只能用 l / t / k 字母组合（l=汉化，t=试用，k=跳过登录），当前为：$asset_source" ;;
esac
suffix="-localize"
case "$asset_source" in
  *t*) suffix="$suffix-trial" ;;
esac
case "$asset_source" in
  *k*) suffix="$suffix-skip" ;;
esac
asset="app-linux$suffix${BETA_SUFFIX}.asar"
;;
esac
else
asset="app-linux-localize${BETA_SUFFIX}.asar"
fi
asset_url="https://github.com/$REPO/releases/download/$tag/$asset"

# 覆盖关系提示：命令行给了简写就忽略配置，命名不同才提示，避免每次运行都刷一行。
if [ -n "$CLI_PACKAGE" ] && [ -n "$ORIG_CONF_PACKAGE" ] && [ "$CLI_PACKAGE" != "$ORIG_CONF_PACKAGE" ]; then
say "提示：命令行 ${CLI_PACKAGE_SRC:---package $CLI_PACKAGE} 优先，配置里的 package = $ORIG_CONF_PACKAGE 已被忽略。"
fi

say "正在获取汉化包校验信息…"
# 优先 SHA256SUMS 文件；旧 release 没有，回退解析 release 资产页的 sha256 徽标。
# 发布流程按构建机命名校验文件，Linux 包对应的是 SHA256SUMS-ubuntu.txt；
# 也兼容 SHA256SUMS-linux.txt，以防发布流程以后改名。
sums_expected=""
for sums_name in SHA256SUMS-ubuntu.txt SHA256SUMS-linux.txt; do
sums_txt=$(curl -sfL --retry 2 --connect-timeout 20 --max-time 60 \
"https://github.com/$REPO/releases/download/$tag/$sums_name" 2>/dev/null || true)
[ -n "$sums_txt" ] || continue
sums_expected=$(printf '%s\n' "$sums_txt" | sed 's/ \*/  /; s/[[:space:]]*$//' \
| grep "  $asset\$" | head -n 1 | cut -d ' ' -f 1 || true)
[ -z "$sums_expected" ] || break
done
if [ -z "$sums_expected" ]; then
sums_page=$(curl -sfL --retry 2 --connect-timeout 20 --max-time 60 \
"https://github.com/$REPO/releases/expanded_assets/$tag" 2>/dev/null || true)
if [ -n "$sums_page" ]; then
# 每个资产一行再匹配；用 awk 断行，sed 替换串里的 \n 不是所有实现都支持。
sums_expected=$(printf '%s' "$sums_page" | tr '\n' ' ' | awk '{ gsub(/<clipboard-copy/, "\n&"); print }' \
| sed -n 's/.*digest for \([^"]*\.asar\)".*value="sha256:\([0-9a-f]\{64\}\)".*/\2  \1/p' \
| grep "  $asset\$" | head -n 1 | cut -d ' ' -f 1 || true)
fi
fi
# 只接受 64 位小写十六进制；错误页或格式变化一律当作没有校验值。
case "$sums_expected" in
*[!0-9a-f]*) sums_expected="" ;;
esac
[ "${#sums_expected}" -eq 64 ] || sums_expected=""

# ---- helpers ---------------------------------------------------------------

# Read one unsigned decimal byte with dd and shell built-ins.
byte_at() {
raw=$(dd if="$1" bs=1 skip="$2" count=1 iflag=skip_bytes 2>/dev/null; printf x) || return 1
raw=${raw%x}
[ -n "$raw" ] || { printf '0\n'; return 0; }
value=1
while [ "$value" -le 255 ]; do
octal=$(printf '%03o' "$value")
candidate=$(printf '%b' "\\$octal"; printf x)
candidate=${candidate%x}
if [ "$raw" = "$candidate" ]; then
printf '%s\n' "$value"
return 0
fi
value=$((value + 1))
done
return 1
}

# Locate the asar integrity fuse byte inside the executable.
# Prints "<offset> <state code>"; the offset is 0-based.
# Returns 1 when there is no fuse table, 2 when it is ambiguous, 3 for an
# unsupported layout and 4 for an unexpected state byte.
find_fuse() {
exe=$1
size=$(wc -c < "$exe" 2>/dev/null | tr -d ' ')
case "$size" in
''|*[!0-9]*) return 1 ;;
esac
[ "$size" -gt 0 ] || return 1

needle_len=${#FUSE_SENTINEL}
[ "$size" -gt "$((needle_len + 2 + FUSE_INDEX))" ] || return 3

# Stream-scan the executable for the sentinel; -aobF reports byte offsets.
matches=$(LC_ALL=C grep -aobF -- "$FUSE_SENTINEL" "$exe" 2>/dev/null) || {
grep_rc=$?
[ "$grep_rc" -eq 1 ] && return 1
return 3
}
case "$matches" in
*'
'*) return 2 ;;
esac
hit_at=${matches%%:*}
case "$hit_at" in
''|*[!0-9]*) return 3 ;;
esac


table=$((hit_at + needle_len))
[ "$(byte_at "$exe" "$table")" = "1" ] || return 3
count=$(byte_at "$exe" "$((table + 1))")
case "$count" in
''|*[!0-9]*) return 3 ;;
esac
[ "$count" -gt "$FUSE_INDEX" ] || return 3

fuse_at=$((table + 2 + FUSE_INDEX))
state=$(byte_at "$exe" "$fuse_at")
case "$state" in
49|48|114) printf '%d %d\n' "$fuse_at" "$state" ;;
*) return 4 ;;
esac
}

# 任何 Termius 进程在跑（包括另一个安装）都不安全，因为应用可能正在读这些文件。
termius_running() {
ps -A -o comm= 2>/dev/null | grep -Eqi '^termius(-app|-beta)?$'
}

is_running() {
if termius_running; then
die "请先完全退出 $APP_LABEL 再运行。"
fi
}

sha256() {
sha256sum -- "$1" 2>/dev/null | cut -d' ' -f1
}

# ---- preflight -------------------------------------------------------------

say "正在检查 $APP_LABEL 是否运行…"
need_cmd curl
need_cmd sha256sum
need_cmd ps

is_running

if fuse_line=$(find_fuse "$EXE"); then
:
else
rc=$?
case "$rc" in
1) die "主程序中没有 Electron 熔丝表，拒绝修改。" ;;
2) die "主程序中有多个 Electron 熔丝表，拒绝修改。" ;;
3) die "Electron 熔丝表布局不受支持，拒绝修改。" ;;
*) die "asar 完整性熔丝状态异常，拒绝修改。" ;;
esac
fi
fuse_at=$(printf '%s' "$fuse_line" | cut -d' ' -f1)
fuse_state=$(printf '%s' "$fuse_line" | cut -d' ' -f2)

# 本机已装文件与官方包一致时跳过下载。
skip_download=0
if [ -n "$sums_expected" ]; then
local_hash=$(sha256 "$ASAR" 2>/dev/null || true)
if [ -n "$local_hash" ] && [ "$local_hash" = "$sums_expected" ]; then
skip_download=1
fi
fi

say "安装目录 : $INSTALL_DIR"
if [ -n "$FORCE_VERSION" ]; then
say "指定版本 : $version"
else
say "本机版本 : $version"
fi
say "目标版本 : $APP_LABEL"
say "汉化包   : $asset_url"
if [ "$skip_download" -eq 1 ]; then
say "本机文件 : 与官方包一致，跳过下载"
fi
say "完整性熔丝: $([ "$fuse_state" = 49 ] && echo 开启 || echo 已关闭)"

say "正在检查汉化包可用性…"
if [ "$CHECK_ONLY" -eq 1 ]; then
code=$(curl -sSL -o /dev/null -w '%{http_code}' -I --max-time 30 "$asset_url" || true)
case "$code" in
200)
if [ "$skip_download" -eq 1 ]; then say "汉化包状态: 可用（本机已是该包）"; else say "汉化包状态: 可用"; fi ;;
404) say "汉化包状态: 该版本暂无 $asset" ;;
*) say "汉化包状态: 未知（HTTP ${code}）" ;;
esac
say "仅检查：未改动任何文件。去掉 --check 才会真正写入。"
exit 0
fi

# ---- download --------------------------------------------------------------

# 下载临时文件名 = 发布标签 + 官方 hash 前 8 位 + 资产名。
# curl --continue-at 续传只发 Range、不带 If-Range：维护者在同一标签下重传同名资产后，
# 服务器照样返回 206，旧 .part 的前半段会和新包的后半段拼成一个长度正确、
# 内容错误的文件。hash 进文件名后，重传会换一个文件名，旧片段不会再被续传。
# 取不到官方 hash 时文件名不带 hash，且不续传（见下面的下载分支）。
cache_dir=${TMPDIR:-/tmp}
cache_dir=${cache_dir%/}
hash_tag=""
[ -z "$sums_expected" ] || hash_tag="-$(printf '%s' "$sums_expected" | cut -c 1-8)"
CACHE_FILE="$cache_dir/termius-zh-$tag$hash_tag-$asset"

# 成功后清理同一渠道的旧缓存与片段：旧版本、旧命名格式、被重传替换掉的 hash。
# 正式版与 Beta 分开清理（Beta 文件名含 -beta- 或 -beta.），两者可能交替运行。
# 只删当前用户自己的文件：/tmp 是多用户共享的，以 root 运行时不能碰别人的文件。
remove_stale_cache() {
keep=${1##*/}
for f in "$cache_dir"/termius-zh-*; do
[ -f "$f" ] && [ -O "$f" ] || continue
name=${f##*/}
[ "$name" != "$keep" ] || continue
case "$name" in
*-beta-*|*-beta.*) is_beta=1 ;;
*) is_beta=0 ;;
esac
[ "$is_beta" -eq "$BETA" ] || continue
rm -f -- "$f" 2>/dev/null || true
done
return 0
}

if [ "$skip_download" -eq 1 ]; then
asset_hash=$sums_expected
else
DOWNLOAD="$CACHE_FILE.part"
asset_hash=""
# /tmp 多用户共享，文件名可预测：别人预先放好的同名文件或符号链接，
# 不能当作缓存或续传片段（没有官方校验值时会被原样装进 Termius）。
for f in "$CACHE_FILE" "$DOWNLOAD"; do
if [ -d "$f" ]; then
# 被目录占用：不是缓存，rm -f 删不掉，不处理会在后面直接失败退出。
rm -rf -- "$f" 2>/dev/null || die "临时路径被目录占用，且无法删除：$f"
elif [ -L "$f" ] || { [ -e "$f" ] && [ ! -O "$f" ]; }; then
rm -f -- "$f" 2>/dev/null || die "临时文件不属于当前用户，且无法删除：$f"
fi
done
# 缓存在共享的 /tmp 里可能被损坏或替换：取到官方校验值时必须重新比对。
if [ -s "$CACHE_FILE" ]; then
cache_hash=$(sha256 "$CACHE_FILE")
if [ -n "$sums_expected" ] && [ "$cache_hash" != "$sums_expected" ]; then
say "已缓存的汉化包与官方校验值不一致，删除后重新下载。"
rm -f -- "$CACHE_FILE"
elif [ -n "$cache_hash" ]; then
asset_hash=$cache_hash
DOWNLOAD=""
say "使用已缓存的汉化包，无需下载。"
fi
fi
if [ -z "$asset_hash" ]; then
# 取文件总大小，用于提示和续传前的长度检查（HEAD 取不到时为 0，不影响下载）。
total_bytes=$(curl -sSL -I --max-time 30 "$asset_url" 2>/dev/null \
| grep -i '^[[:space:]]*content-length:' | tail -n 1 | tr -d '\r' | awk '{print $2}' || true)
case "$total_bytes" in
''|*[!0-9]*) total_bytes=0 ;;
esac

partial_size=0
[ ! -s "$DOWNLOAD" ] || partial_size=$(wc -c < "$DOWNLOAD" | tr -d ' ')
if [ "$partial_size" -gt 0 ] && [ -z "$sums_expected" ]; then
# 没有官方校验值就发现不了拼接出的坏文件，宁可从头下载。
say "该版本没有官方校验值，不续传，重新下载。"
rm -f -- "$DOWNLOAD"
partial_size=0
elif [ "$partial_size" -gt 0 ] && [ "$total_bytes" -gt 0 ] && [ "$partial_size" -gt "$total_bytes" ]; then
say "未完成的下载比完整文件还大，删除后重新下载。"
rm -f -- "$DOWNLOAD"
partial_size=0
fi

if [ "$partial_size" -gt 0 ] && [ "$partial_size" -eq "$total_bytes" ]; then
# 上次已下完但没来得及转为缓存：不再调用 curl，直接进入校验。
say "发现已下载完整的文件，直接校验。"
else
if [ "$partial_size" -gt 0 ]; then
say "发现未完成的下载（$(mb_text "$partial_size")），将从断点续传…"
fi
if [ "$total_bytes" -gt 0 ]; then
total_mb=$(( (total_bytes + 524287) / 1048576 ))
say "正在下载汉化包…（共 ${total_mb} MB）"
else
say "正在下载汉化包…"
fi
if [ -n "$sums_expected" ]; then
retry_hint="未完成部分已保留，可重试续传。"
else
retry_hint="请重试。"
fi
curl -fL --retry 3 --continue-at - --connect-timeout 20 \
--speed-time 60 --speed-limit 1024 --progress-bar \
-o "$DOWNLOAD" "$asset_url" \
|| die "下载失败：该版本可能尚无对应汉化包，或网络不可用。$retry_hint"
fi

[ -s "$DOWNLOAD" ] || { rm -f "$DOWNLOAD"; die "下载文件为空。"; }
size=$(wc -c < "$DOWNLOAD" | tr -d ' ')
if [ "$size" -le 1048576 ]; then
rm -f "$DOWNLOAD"
die "下载文件异常小（$size 字节），可能是错误页面。"
fi
asset_hash=$(sha256 "$DOWNLOAD")
[ -n "$asset_hash" ] || die "无法计算下载文件的校验值；文件已保留，可重试。"
if [ -n "$sums_expected" ] && [ "$asset_hash" != "$sums_expected" ]; then
rm -f "$DOWNLOAD"
die "下载文件与官方校验值不一致，已删除损坏缓存，请重试下载。"
fi
mv -f -- "$DOWNLOAD" "$CACHE_FILE"
DOWNLOAD=""
fi
fi

# 本机 app.asar 已经与目标包一致时不再写文件。
same_asar=0
if [ "$(sha256 "$ASAR" 2>/dev/null || true)" = "$asset_hash" ]; then
same_asar=1
fi
if [ "$same_asar" -eq 1 ] && [ "$fuse_state" != "49" ]; then
say "本机 app.asar 已是该汉化包，无需改动。"
remove_stale_cache "$CACHE_FILE"
exit 0
fi

say "正在替换 app.asar…"
# ---- write -----------------------------------------------------------------

if [ ! -w "$ASAR" ] || [ ! -w "$EXE" ] || [ ! -w "$INSTALL_DIR/resources" ]; then
NEED_SUDO=1
command -v sudo >/dev/null 2>&1 || die "$INSTALL_DIR 不可写，请用 root 身份运行后重试。"
sudo -n true 2>/dev/null || sudo -v || die "未获得管理员权限。"
fi

is_running

staged_asar="$INSTALL_DIR/resources/.app.asar.staged"
staged_exe="$INSTALL_DIR/.$(basename -- "$EXE").staged"

# Stage next to the destination for a single atomic rename.
pkg_source=""
[ -n "$DOWNLOAD" ] && [ -s "$DOWNLOAD" ] && pkg_source="$DOWNLOAD"
[ -n "$pkg_source" ] || pkg_source="$CACHE_FILE"
as_root rm -f "$staged_asar" "$staged_exe" || die "无法清理上次的暂存文件。"
if [ "$skip_download" -ne 1 ]; then
as_root cp -- "$pkg_source" "$staged_asar" || die "无法写入暂存文件。"
as_root chmod 644 "$staged_asar" || true
fi

if [ "$fuse_state" = 49 ]; then
as_root cp -- "$EXE" "$staged_exe" || die "无法暂存主程序。"
is_running
printf '0' | as_root dd of="$staged_exe" bs=1 seek="$fuse_at" count=1 conv=notrunc status=none \
|| die "无法关闭 asar 完整性熔丝。"
if [ "$(byte_at "$staged_exe" "$fuse_at")" != 48 ]; then
die "关闭 asar 完整性熔丝未生效。"
fi
fi

is_running

# 先关熔丝再换 app.asar，避免"新 asar + 旧校验"的中间态。
if [ -f "$staged_exe" ]; then
as_root mv -f -- "$staged_exe" "$EXE" || die "无法替换主程序。"
EXE_WRITTEN=1
fi
if [ "$skip_download" -ne 1 ]; then
as_root mv -f -- "$staged_asar" "$ASAR" || die "无法替换 app.asar。"
ASAR_WRITTEN=1
fi

is_running

if [ "$(sha256 "$ASAR")" != "$asset_hash" ]; then
die "写入后校验 app.asar 失败。"
fi
if [ "$(byte_at "$EXE" "$fuse_at")" = 49 ]; then
die "写入后校验熔丝失败，asar 完整性仍是开启状态。"
fi

[ -z "$DOWNLOAD" ] || rm -f -- "$DOWNLOAD"
remove_stale_cache "$CACHE_FILE"
say "汉化完成，可以重新打开 ${APP_LABEL}。"
say "未保留备份，也无法自动回滚；如需还原请用官方安装包重装。"
