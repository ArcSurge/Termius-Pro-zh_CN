# -*- coding: utf-8 -*-
import argparse
import fnmatch
import logging
import os
import platform
import re
import shutil
import stat
import subprocess
import sys
import tempfile
import time
import tkinter as tk
from tkinter import filedialog

from logger import setup_logging

# Electron v1 熔丝表（格式参考 @electron/fuses）：
# [哨兵字符串][版本号 1 字节][熔丝数量 1 字节][状态字节 x N]
# 状态字节 '1'/'0'/'r' 分别表示开启/关闭/移除
FUSE_SENTINEL = b"dL7pKGdnNz796PbbjQWNKmHXBZaB9tsX"
FUSE_ASAR_INTEGRITY = 4  # EnableEmbeddedAsarIntegrityValidation 在熔丝表中的序号
FUSE_ON = 0x31           # '1'
FUSE_OFF = 0x30          # '0'
FUSE_REMOVED = 0x72      # 'r'

# 字符串提取的过滤阈值
MIN_STRING_LENGTH = 4        # 短于此长度的多为压缩后的符号碎片
MAX_STRING_LENGTH = 300      # 更长的多为代码或数据块
SPACE_REQUIRED_ABOVE = 20    # 超过此长度必须含空格，否则多为压缩后的标识符
PROBE_SAMPLE_COUNT = 20      # 汉化探测的抽样条数（每条需一次全文件扫描）


def is_windows():
    return platform.system() == "Windows"


def is_macos():
    return platform.system() == "Darwin"


def read_file(file_path, strip_empty=True):
    """按行读取文件；strip_empty=False 时返回完整内容"""
    try:
        with open(file_path, "r", encoding="utf-8") as file:
            if not strip_empty:
                return file.read()
            return [line.rstrip("\r\n") for line in file if line.strip()]
    except Exception as e:
        raise RuntimeError(f"Read error: {file_path} - {e}") from e


def write_file_atomic(file_path, content=None, offsets=None):
    """原子写入：先写临时文件再替换，避免中断损坏文件

    offsets 提供时只在副本上改写指定字节，避免为改几个字节而整块读写
    数百 MB 的可执行文件；否则用 content 整体覆写（bytes 走二进制）。
    """
    file_dir = os.path.dirname(file_path) or "."
    temp_path = None
    try:
        if offsets:
            fd, temp_path = tempfile.mkstemp(dir=file_dir)
            os.close(fd)
            shutil.copyfile(file_path, temp_path)
            # mkstemp 默认 0600 且 copyfile 不带权限位，需还原，否则会丢掉可执行位
            shutil.copymode(file_path, temp_path)
            with open(temp_path, "r+b") as temp_file:
                for offset, patch in sorted(offsets.items()):
                    temp_file.seek(offset)
                    temp_file.write(patch if isinstance(patch, (bytes, bytearray))
                                    else patch.encode("utf-8"))
        else:
            if content is None:
                raise ValueError("write_file_atomic: content is required when offsets is empty")
            binary = isinstance(content, (bytes, bytearray))
            with tempfile.NamedTemporaryFile("wb" if binary else "w",
                                             encoding=None if binary else "utf-8",
                                             dir=file_dir, delete=False) as temp_file:
                temp_file.write(content)
                temp_path = temp_file.name
        if temp_path is not None:
            os.replace(temp_path, file_path)
    finally:
        if temp_path is not None and os.path.exists(temp_path):
            try:
                os.remove(temp_path)
            except OSError:
                pass


def _handle_remove_readonly(func, path, _):
    """shutil.rmtree 的错误处理回调：移除只读属性后重试"""
    os.chmod(path, stat.S_IWRITE)
    func(path)


def safe_rmtree(path):
    """删除目录，遇到只读文件先去掉只读属性再重试"""
    if not os.path.exists(path):
        return
    if sys.version_info >= (3, 12):
        shutil.rmtree(path, onexc=_handle_remove_readonly)
    else:
        shutil.rmtree(path, onerror=_handle_remove_readonly)


def remove_empty_dirs(directory):
    """递归删除空目录，返回删除数量"""
    removed_count = 0
    for root, dirs, _ in os.walk(directory, topdown=False):
        for dir_name in dirs:
            dir_path = os.path.join(root, dir_name)
            try:
                with os.scandir(dir_path) as it:
                    if not any(it):
                        os.rmdir(dir_path)
                        removed_count += 1
            except OSError as e:
                logging.warning(f"Failed to remove empty directory {dir_path}: {e}")
    if removed_count > 0:
        logging.debug(f"Removed {removed_count} empty directories")
    return removed_count


def scan_file_for_sentinel(file_path, chunk_size=1024 * 1024):
    """分块扫描文件是否包含熔丝哨兵字符串"""
    tail = b""
    try:
        with open(file_path, "rb") as file:
            while True:
                chunk = file.read(chunk_size)
                if not chunk:
                    return False
                if FUSE_SENTINEL in tail + chunk:
                    return True
                tail = chunk[-(len(FUSE_SENTINEL) - 1):]
    except OSError:
        return False


def _match_pattern(name, pattern, is_dir, is_root=False):
    """gitignore 风格匹配：'/' 结尾只匹配目录，'/' 开头只匹配根层"""
    if pattern.startswith("/") and not is_root:
        return False
    pattern = pattern.lstrip("/")
    pattern = pattern[2:] if pattern.startswith("*/") else pattern

    if pattern.endswith("/"):
        clean_pattern = pattern[:-1]
        has_wildcard = "*" in clean_pattern or "?" in clean_pattern
        if not is_dir:
            return False
        return name == clean_pattern if not has_wildcard else fnmatch.fnmatch(name, clean_pattern)

    has_wildcard = "*" in pattern or "?" in pattern
    return name == pattern if not has_wildcard else fnmatch.fnmatch(name, pattern)


def create_ignore_filter(ignore_patterns=None, allow_patterns=None):
    """创建 copytree 用的过滤函数（黑名单 → '!' 例外 → 白名单）"""
    ignore_patterns = ignore_patterns or []
    allow_patterns = allow_patterns or []
    ignore_list = [p for p in ignore_patterns if not p.startswith("!")]
    allow_list = [p[1:] for p in ignore_patterns if p.startswith("!")]
    first_call = [True]

    def filter_func(directory, contents):
        is_root, first_call[0] = first_call[0], False
        ignore_set = set()

        for item in contents:
            full_path = os.path.join(directory, item)
            try:
                st = os.lstat(full_path)
                is_file, is_dir = stat.S_ISREG(st.st_mode), stat.S_ISDIR(st.st_mode)
            except OSError:
                is_file, is_dir = os.path.isfile(full_path), os.path.isdir(full_path)

            def matches(pattern):
                return _match_pattern(item, pattern, is_dir, is_root)

            should_ignore = any(matches(p) for p in ignore_list)
            if should_ignore and allow_list:
                should_ignore = not any(matches(p) for p in allow_list)
            if not should_ignore and allow_patterns and is_file:
                should_ignore = not any(matches(p) for p in allow_patterns)
            if should_ignore:
                ignore_set.add(item)

        return ignore_set

    return filter_func


def is_comment_line(line):
    """是否为注释行（以 # 开头）"""
    return line.strip().startswith("#")


def is_regex_pattern(s):
    """是否为 /正则/ 形式（'//' 视为注释而非正则）"""
    return len(s) > 1 and s.startswith("/") and s.endswith("/") and "//" not in s


def parse_replace_rule(rule):
    """解析「原字符串|新字符串」，只切一次以支持替换内容含 |"""
    if "|" not in rule:
        raise ValueError("Invalid replacement rule format.")
    return rule.split("|", 1)


def run_command(cmd, shell=False):
    """执行系统命令，失败即退出"""
    cmd_text = " ".join(cmd) if isinstance(cmd, list) else cmd
    logging.debug(f"Running command: {cmd_text}")
    try:
        subprocess.run(cmd, shell=shell, check=True)
    except subprocess.CalledProcessError as e:
        logging.error(f"Command failed with exit code {e.returncode}: {cmd_text}")
        sys.exit(1)
    except FileNotFoundError:
        logging.error(f"Command not found: {cmd_text}")
        sys.exit(1)
    except Exception as e:
        logging.error(f"Unexpected error executing command: {e}")
        sys.exit(1)


def get_asar_cmd():
    """解析 asar 命令的绝对路径

    Windows 下 npm 全局安装的是 asar.cmd；Linux/macOS 用 sudo 运行时 root 的
    PATH 往往不含用户 npm 的全局 bin 目录，直接调 'asar' 会 FileNotFoundError。
    """
    names = ("asar.cmd", "asar") if is_windows() else ("asar",)
    for name in names:
        resolved = shutil.which(name)
        if resolved:
            return resolved
    logging.error(
        "asar command not found in PATH. Install it with: npm install -g @electron/asar. "
        "If running with sudo, preserve your PATH: sudo env \"PATH=$PATH\" python3 lang.py ..."
    )
    sys.exit(1)


def check_asar_installed():
    """确认 asar 命令可用（不可用时 run_command 直接退出）"""
    run_command([get_asar_cmd(), "--version"])


def is_valid_path(path):
    """路径存在且为目录"""
    return bool(path) and os.path.isdir(path)


def check_asar_existence(path):
    """指定目录下是否存在 app.asar"""
    return os.path.exists(os.path.join(path, "app.asar"))


def resolve_resources_dir(path, max_depth=3):
    """向下定位包含 app.asar 的目录

    用户可能选到安装根目录，macOS 上还可能选到 .app 或 Contents，故只在
    resources/contents 子目录中逐层查找，避免误扫整个安装目录。
    """
    if not is_valid_path(path):
        return None
    if check_asar_existence(path):
        return path
    if max_depth <= 0:
        return None
    try:
        entries = sorted(os.listdir(path))
    except OSError:
        return None
    for name in entries:
        sub_path = os.path.join(path, name)
        if os.path.isdir(sub_path) and name.lower() in ("resources", "contents"):
            found = resolve_resources_dir(sub_path, max_depth - 1)
            if found:
                return found
    return None


def select_directory(title):
    """弹出文件夹选择对话框，取消时返回 None"""
    try:
        root = tk.Tk()
        root.withdraw()
        selected_path = filedialog.askdirectory(title=title)
        root.destroy()
        return selected_path if is_valid_path(selected_path) else None
    except Exception as e:
        logging.error(f"Failed to select directory: {e}")
        sys.exit(1)


def _windows_local_appdata():
    """取 %LOCALAPPDATA%；部分精简环境（受限终端、CI）没有该变量，退回用户目录"""
    return os.getenv("LOCALAPPDATA") or os.path.expanduser(os.path.join("~", "AppData", "Local"))


def get_termius_path(beta=False):
    """获取 Termius 的 resources 目录，默认位置找不到时让用户手动选择"""
    app_name = "Termius Beta" if beta else "Termius"
    default_paths = {
        "Windows": lambda: os.path.join(_windows_local_appdata(), "Programs", app_name, "resources"),
        "Darwin": lambda: f"/Applications/{app_name}.app/Contents/Resources",
        "Linux": lambda: f"/opt/{app_name}/resources",
    }
    system = platform.system()
    path_generator = default_paths.get(system)
    if not path_generator:
        logging.error(f"Unsupported operating system: {system}")
        sys.exit(1)

    termius_path = path_generator()
    if check_asar_existence(termius_path):
        return termius_path

    logging.warning(f"app.asar not found at default location: {termius_path}")
    logging.info(f"Please select the '{app_name}' installation directory "
                 f"(the folder containing the 'resources' subfolder) or the 'resources' folder itself.")
    while True:
        selected = select_directory("Select the Termius installation folder (containing 'resources')")
        if not selected:
            logging.error("No directory selected. Exiting.")
            sys.exit(1)
        resolved = resolve_resources_dir(selected)
        if resolved:
            if os.path.normcase(os.path.abspath(resolved)) != os.path.normcase(os.path.abspath(selected)):
                logging.info(f"Using resources directory: {resolved}")
            return resolved
        logging.error(f"app.asar not found in '{selected}' or its 'resources' subfolder. "
                      "Make sure Termius is installed and select its installation directory again.")


class TermiusModifier:
    """改写 app.asar 里的前端代码：先解包成目录，替换文案后再重新打包覆盖原件"""

    @property
    def _script_dir(self):
        return os.path.dirname(os.path.abspath(__file__))

    @property
    def _backup_path(self):
        return os.path.join(self.termius_path, "app.asar.bak")

    @property
    def _original_path(self):
        return os.path.join(self.termius_path, "app.asar")

    @property
    def _app_dir(self):
        """解包的临时工作目录"""
        return os.path.join(self.termius_path, "app")

    @property
    def _unpack_dir(self):
        """供人工查看的轻量解包副本（脚本同级 extract 目录）"""
        return os.path.join(self._script_dir, "extract", "app.asar.unpack")

    @property
    def _rules_dir(self):
        return os.path.join(self._script_dir, "rules")

    @property
    def _executable_candidates(self):
        """可能藏有熔丝表的可执行文件路径"""
        app_name = "Termius Beta" if self.args.beta else "Termius"
        parent = os.path.dirname(self.termius_path)
        if is_windows():
            return [os.path.join(parent, f"{app_name}.exe")]
        return [os.path.join(parent, app_name), os.path.join(parent, app_name.lower())]

    def __init__(self, termius_path, args):
        self.termius_path = termius_path
        self.args = args
        self.loaded_rules = []
        self.compiled_rules = []
        self.applied_rules = set()

    def apply_changes(self):
        """解包 app.asar → 应用规则 → 重新打包覆盖原件 → 清理临时目录"""
        start_time = time.monotonic()
        self.manage_workspace()
        self.disable_asar_integrity_validation()
        self.decompress_asar()
        self.load_rules()
        self.replace_rules()
        self.pack_to_asar()
        # 打包成功后临时目录已无用途，且 app.asar 缺失时会被 Electron 当作旧版本回退加载
        self._remove_app_dir()
        if is_macos():
            self.apply_macos_fix()
        logging.info(f"Changes applied in {time.monotonic() - start_time:.2f}s")
        self._report_rule_matches()

        if self._looks_localized(self._backup_path):
            logging.warning(
                "app.asar.bak contains a localized version rather than the original English one, "
                "so the English text has already been lost and --restore cannot bring it back. "
                "Reinstall Termius to get a clean original."
            )

    def extract_and_unpack(self):
        """解包并提取字符串供规则编写使用（不应用任何规则）"""
        logging.info("Starting unpack and string extraction...")
        start_time = time.monotonic()

        self.create_backup()
        # 上次中断可能留下不完整的解包目录，先清掉避免混入陈旧文件
        self._remove_app_dir()
        self.decompress_asar()
        # 复制成功才删：失败时保留全量解包结果供排查
        if self.copy_unpacked_files():
            self._remove_app_dir()

        logging.info(f"Unpack and string extraction completed in {time.monotonic() - start_time:.2f} seconds")

    def find_in_content(self):
        """搜索同时包含所有给定关键词的文件"""
        find_terms = self.args.find
        if not os.path.exists(self._app_dir):
            self.decompress_asar()

        found_files = []
        for file_path in self.collect_code_files():
            try:
                file_content = read_file(file_path, strip_empty=False)
            except Exception as e:
                logging.warning(f"Skipping unreadable file: {file_path} - {e}")
                continue
            if file_content and all(term in file_content for term in find_terms):
                found_files.append(file_path)

        separator = "=" * 60
        terms_list = "\n".join([f"  • {term}" for term in find_terms])
        logging.info(separator)
        logging.info("Search results" if found_files else "No results found")
        logging.info(separator)
        logging.info(f"Search terms ({len(find_terms)}):\n{terms_list}")
        if found_files:
            files_list = "\n".join([f"  • {file_path}" for file_path in found_files])
            logging.info(f"Found in {len(found_files)} file(s):\n{files_list}")
        else:
            logging.info("No files contain all the specified terms.")
        logging.info(separator)

    def restore_changes(self):
        """还原原始 app.asar 并删除备份"""
        self.clean_workspace()
        if os.path.exists(self._backup_path):
            os.remove(self._backup_path)

    def manage_workspace(self):
        """创建备份并清空上次的运行残留"""
        self.create_backup()
        self.clean_workspace()

    def clean_workspace(self):
        """恢复原始 app.asar 并删除临时解包目录"""
        self.restore_backup()
        self._remove_app_dir()

    def create_backup(self):
        """创建初始备份（备份已存在时不覆盖，避免把汉化版当原件）"""
        if os.path.exists(self._backup_path):
            return
        shutil.copy(self._original_path, self._backup_path)
        logging.info("Initial backup created")

    def restore_backup(self):
        """从备份恢复原始 app.asar"""
        if not os.path.exists(self._backup_path):
            logging.info("Backup file not found, skipping restore")
            return
        shutil.copy(self._backup_path, self._original_path)
        logging.info("Restored from backup successfully")

    def _remove_app_dir(self):
        """删除临时解包目录（不存在时静默返回）"""
        if os.path.exists(self._app_dir):
            safe_rmtree(self._app_dir)
            logging.debug(f"Removed temporary app directory: {self._app_dir}")

    def disable_asar_integrity_validation(self):
        """关闭可执行文件中的 asar 完整性校验熔丝

        新版 Termius 启用了 EnableEmbeddedAsarIntegrityValidation，替换 app.asar
        后启动会因校验失败被阻止。macOS 由 osxfix.sh 更新 Info.plist 里的预期
        hash，无需关闭熔丝，故跳过。
        """
        if is_macos():
            return
        exe_path = self._find_fuse_executable()
        if not exe_path:
            logging.warning("Termius executable not found, skip disabling asar integrity validation")
            return
        try:
            with open(exe_path, "rb") as file:
                content = file.read()
        except OSError as e:
            logging.warning(f"Cannot read executable {exe_path}: {e}")
            return

        index = content.find(FUSE_SENTINEL)
        if index < 0:
            logging.info("Fuse wire not found in executable, nothing to do")
            return
        wire_start = index + len(FUSE_SENTINEL)
        if len(content) < wire_start + 2:
            logging.warning("Fuse wire truncated, skip")
            return
        version, fuse_count = content[wire_start], content[wire_start + 1]
        if version != 1 or fuse_count <= FUSE_ASAR_INTEGRITY \
                or len(content) < wire_start + 2 + fuse_count:
            logging.warning(f"Unsupported fuse wire (version={version}, count={fuse_count}), skip")
            return
        offset = wire_start + 2 + FUSE_ASAR_INTEGRITY
        state = content[offset]
        if state in (FUSE_OFF, FUSE_REMOVED):
            logging.info("Asar integrity validation already disabled")
            return
        if state != FUSE_ON:
            logging.warning(f"Unexpected fuse state {bytes([state])!r}, skip")
            return

        # 需同时可写可执行文件及其所在目录（临时文件建在目录内），提前给出准确提示
        if not (os.access(exe_path, os.W_OK) and os.access(os.path.dirname(exe_path), os.W_OK)):
            logging.error(
                f"No write permission for Termius executable: {exe_path}. "
                "Disabling asar integrity validation requires elevated privileges "
                "(run as administrator on Windows, or use sudo on Linux/macOS)."
            )
            sys.exit(1)
        # 只改 1 字节，用局部补丁避免整块读写可执行文件
        try:
            write_file_atomic(exe_path, offsets={offset: bytes([FUSE_OFF])})
        except OSError as e:
            logging.error(
                f"Failed to write executable: {e}. Make sure Termius is fully closed "
                "and you have write access to the Termius directory."
            )
            sys.exit(1)
        logging.info("Asar integrity validation disabled (EnableEmbeddedAsarIntegrityValidation)")

    def _find_fuse_executable(self):
        """定位含熔丝表的可执行文件"""
        for path in self._executable_candidates:
            if os.path.isfile(path):
                return path
        # 已知名称未命中时，在安装目录一级文件中扫描哨兵字符串兜底
        parent = os.path.dirname(self.termius_path)
        try:
            entries = os.listdir(parent)
        except OSError:
            return None
        for name in entries:
            path = os.path.join(parent, name)
            if os.path.isfile(path) and os.path.getsize(path) <= 512 * 1024 * 1024 \
                    and scan_file_for_sentinel(path):
                return path
        return None

    def decompress_asar(self):
        """把 app.asar 解包成 app 目录，方便直接改里面的文件"""
        run_command([get_asar_cmd(), "extract", self._original_path, self._app_dir])

    def pack_to_asar(self):
        """把改过的 app 目录重新打包成 app.asar，覆盖原文件"""
        run_command([
            get_asar_cmd(), "pack", self._app_dir, self._original_path,
            "--unpack-dir", "{node_modules/@termius,out}",
        ])

    def load_rules(self):
        """加载与参数同名的规则文件并编译

        规则格式：原字符串|新字符串 或 /正则表达式/|替换内容。
        必须保持文件中的原始顺序：短规则可能先于完整正则出现，换序会破坏匹配。
        """
        for arg in ("skip_login", "trial", "style", "localize"):
            if not getattr(self.args, arg, False):
                continue
            file_name = f"{arg}.txt"
            try:
                if content := read_file(os.path.join(self._rules_dir, file_name)):
                    self.loaded_rules.extend(content)
            except Exception as e:
                logging.error(f"Failed to load rules from {file_name}: {e}")
                sys.exit(1)

        self.compiled_rules = []
        for line in self.loaded_rules:
            if is_comment_line(line):
                continue
            try:
                old_val, new_val = parse_replace_rule(line)
                if is_regex_pattern(old_val):
                    self.compiled_rules.append(("regex", line, re.compile(old_val[1:-1]), new_val))
                else:
                    self.compiled_rules.append(("plain", line, old_val, new_val))
            except ValueError as e:
                logging.warning(f"Skipping invalid rule: {line} - {e}")
            except re.error as e:
                logging.warning(f"Regex compilation error in rule: {line} - {e}")

    def collect_code_files(self):
        """收集待替换的代码文件（JS，style 模式下含 CSS）"""
        extensions = (".js", ".css") if self.args.style else ".js"
        code_files = []
        for prefix in (
            os.path.join(self._app_dir, "background-process", "assets"),
            os.path.join(self._app_dir, "ui-process", "assets"),
            os.path.join(self._app_dir, "main-process"),
        ):
            for root, _, files in os.walk(prefix):
                code_files.extend(os.path.join(root, f) for f in files if f.endswith(extensions))
        return code_files

    def replace_content(self, file_content):
        """对单个文件内容应用所有规则，返回 (新内容, 命中的规则集合)"""
        if not file_content or not self.compiled_rules:
            return file_content, set()

        matched_rules = set()
        for rule_type, line, old_or_pattern, new_val in self.compiled_rules:
            if rule_type == "regex":
                if old_or_pattern.search(file_content):
                    matched_rules.add(line)
                    file_content = old_or_pattern.sub(new_val, file_content)
            elif old_or_pattern in file_content:
                matched_rules.add(line)
                file_content = file_content.replace(old_or_pattern, new_val)
        return file_content, matched_rules

    def replace_rules(self):
        """对所有代码文件应用规则替换"""
        logging.info("Starting rule replacement...")
        for file_path in self.collect_code_files():
            try:
                content = read_file(file_path, strip_empty=False)
                new_content, matched_rules = self.replace_content(content)
                self.applied_rules.update(matched_rules)
                if matched_rules:
                    write_file_atomic(file_path, new_content)
            except Exception as e:
                logging.error(f"Failed to process file {file_path}: {e}")
        logging.info("Rule replacement completed")

    def _report_rule_matches(self):
        """输出规则命中统计（compiled_rules 已排除注释行）"""
        total_rule_lines = [line for _, line, _, _ in self.compiled_rules]
        logging.info(f"Rules applied: {len(self.applied_rules)}/{len(total_rule_lines)}")
        unmatched_rules = [line for line in total_rule_lines if line not in self.applied_rules]
        if not unmatched_rules:
            logging.debug("All rules matched successfully")
            return
        if len(unmatched_rules) > 3:
            logging.warning(f"{len(unmatched_rules)} rules did not match. See debug log for details.")
        rules_list = "\n".join(f"{i + 1:>4}. {rule}" for i, rule in enumerate(unmatched_rules))
        logging.debug(f"Unmatched rules:\n{rules_list}")

    def copy_unpacked_files(self):
        """把解包结果复制到 extract 目录并提取字符串

        Returns:
            bool: 复制与提取是否成功
        """
        try:
            if os.path.exists(self._unpack_dir):
                safe_rmtree(self._unpack_dir)
                logging.debug(f"Removed existing unpack directory: {self._unpack_dir}")
            # 仅复制 JS、JSON、CSS 文件，排除 node_modules
            ignore_func = create_ignore_filter(["node_modules"], ["*.js", "*.json", "*.css"])
            shutil.copytree(self._app_dir, self._unpack_dir, ignore=ignore_func)
            remove_empty_dirs(self._unpack_dir)
            logging.info(f"Unpacked files copied to {self._unpack_dir}")
            self.extract_all_strings()
            return True
        except Exception as e:
            logging.error(f"Failed to copy unpacked files: {e}")
            return False

    def extract_all_strings(self):
        """从 JS/JSON 中提取字符串写入 allstring.txt，供翻译参考"""
        try:
            extract_dir = os.path.join(self._script_dir, "extract")
            os.makedirs(extract_dir, exist_ok=True)
            all_strings_file = os.path.join(extract_dir, "allstring.txt")

            patterns = [
                re.compile(r'"([^"\\]*(?:\\.[^"\\]*)*)"'),
                re.compile(r"'([^'\\]*(?:\\.[^'\\]*)*)'"),
                re.compile(r'`([^`\\]*(?:\\.[^`\\]*)*)`'),
            ]
            number_pattern = re.compile(r"^[0-9.+\-]*$")
            all_strings = set()

            for root, _, files in os.walk(self._unpack_dir):
                for file in files:
                    if not file.endswith((".js", ".json")):
                        continue
                    file_path = os.path.join(root, file)
                    try:
                        with open(file_path, "r", encoding="utf-8") as f:
                            content = f.read()
                        for pattern in patterns:
                            all_strings.update(pattern.findall(content))
                    except Exception as e:
                        logging.debug(f"Cannot read file {file_path}: {e}")

            # 过滤短碎片、首尾空白、换行/制表、超长串和纯数字；
            # 超过 SPACE_REQUIRED_ABOVE 的无空格串多为压缩标识符
            filtered_strings = sorted(
                [s for s in all_strings
                 if MIN_STRING_LENGTH <= len(s) <= MAX_STRING_LENGTH
                 and s == s.strip()
                 and "\n" not in s and "\t" not in s and "\r" not in s
                 and (len(s) <= SPACE_REQUIRED_ABOVE or " " in s)
                 and not number_pattern.match(s)],
                key=lambda s: (len(s), s.lower()),
            )

            with open(all_strings_file, "w", encoding="utf-8") as f:
                f.write("# 从 app.asar 中提取的所有字符串\n")
                f.write("# All strings extracted from app.asar\n")
                f.write(f"# 总计: {len(filtered_strings)} 个字符串\n")
                f.write(f"# Total: {len(filtered_strings)} strings\n")
                f.write("=" * 80 + "\n\n")
                for i, string in enumerate(filtered_strings, 1):
                    escaped = string.replace("\n", "\\n").replace("\t", "\\t").replace("\r", "\\r")
                    f.write(f"{i:4}. {escaped}\n")

            logging.info("String extraction completed")
            logging.info(f"Output: {all_strings_file}")
            logging.info(f"Total strings extracted: {len(filtered_strings)}")
        except Exception as e:
            logging.error(f"Failed to extract strings: {e}")

    def apply_macos_fix(self):
        """调用 osxfix.sh 重新计算 Info.plist 里的 asar hash"""
        logging.info("Applying macOS fix...")
        script_path = os.path.join(self._script_dir, "macos", "osxfix.sh")
        run_command(["chmod", "+x", script_path])
        run_command([script_path] + (["--beta"] if self.args.beta else []))
        logging.info("macOS fix applied successfully")

    def _looks_localized(self, asar_path):
        """抽样判断指定 asar 是否已被汉化（英文原文大面积消失）"""
        try:
            rules = read_file(os.path.join(self._rules_dir, "localize.txt"))
            with open(asar_path, "rb") as file:
                content = file.read()
        except (RuntimeError, OSError):
            return False

        originals = []
        for line in rules:
            if "|" not in line or is_comment_line(line):
                continue
            old_val, new_val = line.split("|", 1)
            if not is_regex_pattern(old_val) and len(old_val) >= 8 \
                    and any("\u4e00" <= ch <= "\u9fff" for ch in new_val):
                originals.append(old_val)
        if not originals:
            return False

        step = max(1, len(originals) // PROBE_SAMPLE_COUNT)
        sample = [old.encode("utf-8") for old in originals[::step]][:PROBE_SAMPLE_COUNT]
        present = sum(needle in content for needle in sample)
        return present * 2 < len(sample)


def main():
    parser = argparse.ArgumentParser(description="Modify Termius application.")
    parser.add_argument("-b", "--beta", action="store_true", help="Specify if this is a beta version.")
    parser.add_argument("-l", "--localize", action="store_true",
                        help="Enable localization patch (Chinese translation/adaptation).")
    parser.add_argument("-t", "--trial", action="store_true", help="Activate professional edition trial.")
    parser.add_argument("-k", "--skip-login", action="store_true", help="Disable authentication workflow.")
    parser.add_argument("-s", "--style", action="store_true", help="UI/UX customization preset.")
    parser.add_argument("-e", "--extract", action="store_true", help="Unpack and extract application strings.")
    parser.add_argument("-f", "--find", nargs="+", help="Multi-mode search operation.")
    parser.add_argument("-r", "--restore", action="store_true", help="Restore software to initial state.")
    parser.add_argument("-v", "--verbose", type=lambda s: s.upper(), dest="log_level",
                        choices=["DEBUG", "INFO", "WARNING", "ERROR", "CRITICAL"], default="INFO",
                        help="Set logging verbosity: DEBUG|INFO|WARNING|ERROR|CRITICAL (default: %(default)s)")

    args = parser.parse_args()
    setup_logging(args.log_level)

    # 无参数时默认执行汉化
    if not any((args.trial, args.find, args.style, args.skip_login,
                args.localize, args.restore, args.extract)):
        args.localize = True
        logging.info("No arguments provided, defaulting to localization mode")

    check_asar_installed()
    modifier = TermiusModifier(get_termius_path(args.beta), args)

    if any((args.trial, args.style, args.skip_login, args.localize)):
        modifier.apply_changes()
    elif args.find:
        modifier.find_in_content()
    elif args.extract:
        modifier.extract_and_unpack()
    elif args.restore:
        modifier.restore_changes()
    else:
        logging.error("Invalid command. Use '--help' for usage information.")


if __name__ == "__main__":
    main()
