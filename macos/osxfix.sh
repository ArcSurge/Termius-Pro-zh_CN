#!/bin/zsh

set -e;
set -o pipefail;

# 参数解析
BETA=false
while [[ $# -gt 0 ]]; do
	case $1 in
		-b|--beta)
			BETA=true
			shift
			;;
		*)
			shift
			;;
	esac
done

# 根据 BETA 标志设置应用路径
if [[ "$BETA" == true ]]; then
	TERMIUS_PATH="/Applications/Termius Beta.app"
else
	TERMIUS_PATH="/Applications/Termius.app"
fi

ASAR_PATH="$TERMIUS_PATH/Contents/Resources/app.asar"

if [[ ! -e $ASAR_PATH ]] {
	echo "Error: Termius app.asar file not found!"
	exit 1
}
# 转义路径并锚定命令行开头，避免误匹配其它副本。
RUN_PATTERN="^$(printf '%s' "$TERMIUS_PATH/Contents/MacOS/" | sed 's/[][\.^$*+()?{}|]/\\&/g')"

# pgrep 仅退出码 1 表示未运行；查询失败时停止。
require_not_running() {
	local rc=0
	pgrep -f "$RUN_PATTERN" >/dev/null 2>&1 || rc=$?
	case "$rc" in
		0) echo "请先完全退出 ${TERMIUS_PATH:t:r}，再运行本脚本。"; exit 1 ;;
		1) return 0 ;;
		*) echo "pgrep 查询失败（退出码 $rc），停止修改。"; exit 1 ;;
	esac
}

calc_hash() {
	local asar_path="$1"
	local head_len hash
	head_len=$(od -An -j 12 -N4 -D "$asar_path" 2>/dev/null | tr -d '[:space:]')
	# 头长度非法或为 0 说明 app.asar 不完整（下载中断最典型），此时不能写一个错的校验值。
	if [[ "$head_len" != <-> || "$head_len" -eq 0 ]]; then
		echo "Error: app.asar 文件头无效，可能下载不完整；请重新下载汉化包后重跑本脚本。" >&2
		return 1
	fi
	hash=$(dd bs=1 count=$head_len skip=16 if="$asar_path" 2>/dev/null | shasum -a256 -b | cut -d ' ' -f 1) || hash=""
	if [[ ${#hash} -ne 64 ]]; then
		echo "Error: 无法计算 app.asar 校验值；请重新下载汉化包后重跑本脚本。" >&2
		return 1
	fi
	print -r -- "$hash"
}

update_hash() {
	local bundle=$1
	local hash=$2
	local info_path
	if [[ "${bundle:e}" == "app" ]] {
		info_path="$bundle/Contents/Info.plist"
	} elif [[ "${bundle:e}" == "framework" ]] {
		info_path="$bundle/Versions/A/Resources/Info.plist"
	} else {
		return
	}
	[[ -f "$info_path" ]] || return
	exists() { /usr/libexec/PlistBuddy -c "Print $1" "$info_path" >/dev/null 2>&1 }
	plist_write() {
		/usr/libexec/PlistBuddy -c "$1" "$info_path" >/dev/null 2>&1 && return 0
		echo "Error: 无法写入 $info_path。请确认对应用有写权限，必要时用 sudo 运行本脚本。" >&2
		return 1
	}
	exists ":ElectronAsarIntegrity" || plist_write "Add :ElectronAsarIntegrity dict" || return 1
	exists ":ElectronAsarIntegrity:Resources\/app.asar" || plist_write "Add :ElectronAsarIntegrity:Resources\/app.asar dict" || return 1
	exists ":ElectronAsarIntegrity:Resources\/app.asar:algorithm" || plist_write "Add :ElectronAsarIntegrity:Resources\/app.asar:algorithm string SHA256" || return 1
	if exists ":ElectronAsarIntegrity:Resources\/app.asar:hash"; then
		plist_write "Set :ElectronAsarIntegrity:Resources\/app.asar:hash $hash" || return 1
	else
		plist_write "Add :ElectronAsarIntegrity:Resources\/app.asar:hash string $hash" || return 1
	fi
	echo "Edited: $info_path"
	if [[ "${bundle:e}" == "app" && -d "$bundle/Contents/Frameworks" ]] {
		for i ($bundle/Contents/Frameworks/*) {
			update_hash "$i" "$hash" || return 1
		}
	}
}

resign_app() {
	local app_path=$1
	local tempfile=$(mktemp)
	local rc=0
	if ! codesign --display --entitlements - --xml "$app_path" > "$tempfile"; then
		rm -f -- "$tempfile" 2>/dev/null || true
		echo "错误：无法读取应用签名权限，请用官方安装包重新安装后重跑本脚本。" >&2
		return 1
	fi
	# 带点的权限键不能直接用 plutil 的点分层键路径，改用 PlistBuddy 的 : 路径删除。
	if [[ $rc -eq 0 ]]; then
		/usr/libexec/PlistBuddy -c 'Delete :com.apple.developer.team-identifier' "$tempfile" >/dev/null 2>&1 || true
	fi
	if [[ $rc -eq 0 ]] && plutil -extract keychain-access-groups raw $tempfile >/dev/null 2>&1; then
		plutil -remove keychain-access-groups $tempfile || rc=$?
	fi
	if [[ $rc -eq 0 ]]; then
		codesign --force --sign - --deep --entitlements $tempfile $app_path || rc=$?
	fi
	if [[ $rc -ne 0 ]]; then
		echo "错误：重新签名失败，请用官方安装包重新安装后重跑本脚本。" >&2
	fi
	# 无论成败都清掉临时 entitlements，避免失败时把它留在 TMPDIR。
	rm -f -- "$tempfile" 2>/dev/null || true
	return $rc
}
# --force 返回 0 只说明签名已写入，写坏的签名仍会被 --verify 判为无效。
require_valid_signature() {
	if codesign --verify --deep --strict "$TERMIUS_PATH" >/dev/null 2>&1; then
		return 0
	fi
	echo "错误：重新签名后无法验证应用签名。请用官方安装包重新安装，然后重跑本脚本。" >&2
	exit 1
}

# 清 quarantine 尽力而为：无权修改时不能静默失败；xattr -d 对不存在的属性同样返回
# 非零，所以要确认标记是否仍在，仍在才告警。
clear_quarantine_or_warn() {
	if xattr -dr com.apple.quarantine "$TERMIUS_PATH" 2>/dev/null; then
		return 0
	fi
	if ! xattr -p com.apple.quarantine "$TERMIUS_PATH" >/dev/null 2>&1; then
		return 0
	fi
	echo "警告：未能清除 quarantine 下载标记（应用可能不属于当前用户）。"
	echo "不影响汉化结果；若启动时提示「Apple 无法验证」且无法放行，请执行："
	echo "  sudo xattr -dr com.apple.quarantine \"$TERMIUS_PATH\""
	return 0
}

require_not_running
asar_hash=$(calc_hash "$ASAR_PATH") || exit 1
# calc_hash 与真正写入之间还有一段时间：应用在这期间被启动就改到正在运行的应用上。
require_not_running
update_hash "$TERMIUS_PATH" "$asar_hash" || exit 1
# 具体原因（读取授权失败 / 重签失败）由 resign_app 自己打印，这里只决定是否继续。
resign_app "$TERMIUS_PATH" || exit 1
# 重签之后再确认一次：验证不通过就不清 quarantine，也不报完成。
require_valid_signature
# ad-hoc 重签没有公证，quarantine 在手时启动会被 Gatekeeper 拦截。
clear_quarantine_or_warn
echo -e "\e[92m✔ All done, enjoy\!\e[0m"
