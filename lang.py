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


def create_ignore_filter(ignore_patterns=None, allow_patterns=None):
    """创建文件过滤函数

    Args:
        ignore_patterns: 黑名单模式列表，'!' 开头为例外规则
        allow_patterns: 白名单模式列表，None 表示不使用

    Note:
        - '/' 结尾：只匹配目录 | '/' 开头：只匹配根目录 | '!' 开头：例外规则
        - 工作流程：黑名单 → !例外 → 白名单过滤
    """
    if ignore_patterns is None:
        ignore_patterns = []
    if allow_patterns is None:
        allow_patterns = []

    ignore_list = [p for p in ignore_patterns if not p.startswith('!')]
    allow_list = [p[1:] for p in ignore_patterns if p.startswith('!')]
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

            should_ignore = any(_match_pattern(item, p, is_dir, is_root) for p in ignore_list)

            if should_ignore and allow_list:
                should_ignore = not any(_match_pattern(item, p, is_dir, is_root) for p in allow_list)

            if not should_ignore and allow_patterns and is_file:
                should_ignore = not any(_match_pattern(item, p, is_file, is_root) for p in allow_patterns)

            if should_ignore:
                ignore_set.add(item)

        return ignore_set

    return filter_func


def _match_pattern(name, pattern, is_dir, is_root=False):
    """模式匹配（支持 .gitignore 风格）"""
    if pattern.startswith('/') and not is_root:
        return False
    pattern = pattern.lstrip('/')

    pattern = pattern[2:] if pattern.startswith('*/') else pattern

    if pattern.endswith('/'):
        clean_pattern = pattern[:-1]
        has_wildcard = '*' in clean_pattern or '?' in clean_pattern
        return is_dir and (name == clean_pattern if not has_wildcard else fnmatch.fnmatch(name, clean_pattern))

    has_wildcard = '*' in pattern or '?' in pattern
    return name == pattern if not has_wildcard else fnmatch.fnmatch(name, pattern)


def remove_empty_dirs(directory):
    """递归删除空目录，返回删除数量"""
    removed_count = 0
    for root, dirs, files in os.walk(directory, topdown=False):
        for dir_name in dirs[:]:
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


class TermiusModifier:
    @property
    def _script_dir(self):
        return os.path.dirname(os.path.abspath(__file__))

    @property
    def _backup_path(self):
        """备份文件路径"""
        return os.path.join(self.termius_path, "app.asar.bak")

    @property
    def _original_path(self):
        """原始文件路径"""
        return os.path.join(self.termius_path, "app.asar")

    @property
    def _app_dir(self):
        return os.path.join(self.termius_path, "app")

    @property
    def _unpack_dir(self):
        """解包文件输出目录（脚本同级目录/extract）"""
        return os.path.join(self._script_dir, "extract", "app.asar.unpack")

    @property
    def _rules_dir(self):
        """规则文件目录"""
        return os.path.join(self._script_dir, "rules")

    def __init__(self, termius_path, args):
        """初始化修改器实例"""
        self.termius_path = termius_path
        self.args = args
        self.loaded_rules = []
        self.compiled_rules = []
        self.applied_rules = set()

    def apply_macos_fix(self):
        """应用 macOS 系统修复（重新计算文件 hash）"""
        logging.info("Applying macOS fix...")
        script_path = os.path.join(self._script_dir, "macos", "osxfix.sh")
        run_command(["chmod", "+x", script_path])
        cmd = [script_path]
        if self.args.beta:
            cmd.append("--beta")
        run_command(cmd)
        logging.info("macOS fix applied successfully")

    def load_rules(self):
        """动态加载与参数同名的规则文件

        支持的规则类型：skip_login, trial, style, localize
        规则格式：原字符串|新字符串 或 /正则表达式/|替换内容
        """
        rule_args = ["skip_login", "trial", "style", "localize"]

        for arg in rule_args:
            if not getattr(self.args, arg, False):
                continue
            file_name = f"{arg}.txt"
            try:
                file_path = os.path.join(self._rules_dir, file_name)
                if content := read_file(file_path):
                    self.loaded_rules.extend(content)
            except Exception as e:
                logging.error(f"Failed to load rules from {file_name}: {e}")
                sys.exit(1)

        # 编译规则：区分注释、正则表达式和普通文本
        self.compiled_rules = []
        for line in self.loaded_rules:
            if is_comment_line(line):
                self.compiled_rules.append(("comment", line, None, None))
                continue
            try:
                old_val, new_val = parse_replace_rule(line)
                if is_regex_pattern(old_val):
                    self.compiled_rules.append(("regex", line, re.compile(old_val[1:-1]), new_val))
                else:
                    self.compiled_rules.append(("plain", line, old_val, new_val))
            except ValueError as e:
                logging.warning(f"Skipping invalid rule: {line} - {str(e)}")
            except re.error as e:
                logging.warning(f"Regex compilation error in rule: {line} - {str(e)}")

    def decompress_asar(self):
        """解压 app.asar 文件到 app 目录"""
        cmd = [get_asar_cmd(), "extract", self._original_path, self._app_dir]
        run_command(cmd)

    def copy_unpacked_files(self):
        """复制解包文件到 extract 目录并提取字符串"""
        try:
            # 清理已存在的解包目录
            if os.path.exists(self._unpack_dir):
                shutil.rmtree(self._unpack_dir)
                logging.debug(f"Removed existing unpack directory: {self._unpack_dir}")

            # 仅复制 JS、JSON、CSS 文件，排除 node_modules
            ignore_func = create_ignore_filter(["node_modules"], ["*.js", "*.json", "*.css"])
            shutil.copytree(self._app_dir, self._unpack_dir, ignore=ignore_func)
            remove_empty_dirs(self._unpack_dir)

            logging.info(f"Unpacked files copied to {self._unpack_dir}")

            # 提取所有字符串用于本地化参考
            self.extract_all_strings()

        except Exception as e:
            logging.error(f"Failed to copy unpacked files: {e}")

    def extract_all_strings(self):
        """从 JS 和 JSON 文件中提取所有字符串到 allstring.txt

        提取双引号、单引号和模板字符串，过滤短字符串和纯数字
        """
        try:
            extract_dir = os.path.join(self._script_dir, "extract")
            os.makedirs(extract_dir, exist_ok=True)
            all_strings_file = os.path.join(extract_dir, "allstring.txt")

            # 编译正则表达式（避免重复编译）
            patterns = [
                re.compile(r'"([^"\\]*(?:\\.[^"\\]*)*)"'),
                re.compile(r"'([^'\\]*(?:\\.[^'\\]*)*)'"),
                re.compile(r'`([^`\\]*(?:\\.[^`\\]*)*)`'),
            ]

            # 数字模式（用于过滤）
            number_pattern = re.compile(r'^[0-9.+\-]*$')

            all_strings = set()

            # 遍历所有 JS 和 JSON 文件
            for root, _, files in os.walk(self._unpack_dir):
                for file in files:
                    if not file.endswith(('.js', '.json')):
                        continue

                    file_path = os.path.join(root, file)
                    try:
                        with open(file_path, 'r', encoding='utf-8') as f:
                            content = f.read()

                        # 提取三种类型的字符串
                        for pattern in patterns:
                            all_strings.update(pattern.findall(content))
                    except Exception as e:
                        logging.debug(f"Cannot read file {file_path}: {e}")

            # 过滤：长度>1、非空白、非纯数字，按长度和字母排序
            filtered_strings = sorted(
                [s for s in all_strings if len(s) > 1 and not s.isspace() and not number_pattern.match(s)],
                key=lambda x: (len(x), x.lower())
            )

            # 写入提取结果
            with open(all_strings_file, 'w', encoding='utf-8') as f:
                f.write("# 从 app.asar 中提取的所有字符串\n")
                f.write("# All strings extracted from app.asar\n")
                f.write(f"# 总计: {len(filtered_strings)} 个字符串\n")
                f.write(f"# Total: {len(filtered_strings)} strings\n")
                f.write("=" * 80 + "\n\n")

                for i, string in enumerate(filtered_strings, 1):
                    escaped_string = string.replace('\n', '\\n').replace('\t', '\\t').replace('\r', '\\r')
                    f.write(f"{i:4}. {escaped_string}\n")

            logging.info("String extraction completed")
            logging.info(f"Output: {all_strings_file}")
            logging.info(f"Total strings extracted: {len(filtered_strings)}")

        except Exception as e:
            logging.error(f"Failed to extract strings: {e}")

    def pack_to_asar(self):
        """将修改后的 app 目录打包回 app.asar"""
        cmd = [
            get_asar_cmd(),
            "pack",
            self._app_dir,
            self._original_path,
            "--unpack-dir",
            "{node_modules/@termius,out}"
        ]
        run_command(cmd)

    def restore_backup(self):
        """从备份文件恢复原始 app.asar"""
        if not os.path.exists(self._backup_path):
            logging.info("Backup file not found, skipping restore")
            return

        shutil.copy(self._backup_path, self._original_path)
        logging.info("Restored from backup successfully")

    def create_backup(self):
        """创建初始备份（仅在备份不存在时）"""
        if not os.path.exists(self._backup_path):
            shutil.copy(self._original_path, self._backup_path)
            logging.info("Initial backup created")

    def manage_workspace(self):
        """管理工作区：创建备份并清理临时文件"""
        self.create_backup()
        self.clean_workspace()

    def clean_workspace(self):
        """清理工作区：恢复备份并删除临时 app 目录"""
        self.restore_backup()
        if os.path.exists(self._app_dir):
            safe_rmtree(self._app_dir)
            logging.debug("Cleaned app directory")

    def restore_changes(self):
        """完全还原：清理工作区并删除备份文件"""
        self.clean_workspace()
        if os.path.exists(self._backup_path):
            os.remove(self._backup_path)

    def replace_rules(self):
        """对所有代码文件应用规则替换"""
        logging.info("Starting rule replacement...")
        code_files = self.collect_code_files()
        for file_path in code_files:
            if not os.path.exists(file_path):
                continue
            try:
                content = read_file(file_path, strip_empty=False)
                new_content, matched_rules = self.replace_content(content)
                self.applied_rules.update(matched_rules)
                if new_content != content:
                    write_file_atomic(file_path, new_content)
            except Exception as e:
                logging.error(f"Failed to process file {file_path}: {e}")
        logging.info("Rule replacement completed")

    def replace_content(self, file_content):
        """对单个文件内容执行所有规则的替换

        Returns:
            tuple: (新内容, 匹配的规则集合)
        """
        if not file_content:
            return file_content, set()
        if not self.compiled_rules:
            return file_content, set()

        matched_rules = set()
        for rule_type, line, old_or_pattern, new_val in self.compiled_rules:
            if rule_type == "comment":
                matched_rules.add(line)
                continue
            original_content = file_content
            if rule_type == "regex":
                file_content = old_or_pattern.sub(new_val, file_content)
            else:
                file_content = file_content.replace(old_or_pattern, new_val)
            if original_content != file_content:
                matched_rules.add(line)

        return file_content, matched_rules

    def collect_code_files(self):
        """收集需要处理的代码文件（JS 和可选的 CSS）"""
        prefix_links = [
            os.path.join(self._app_dir, "background-process", "assets"),
            os.path.join(self._app_dir, "ui-process", "assets"),
            os.path.join(self._app_dir, "main-process"),
        ]
        code_files = []
        extensions = (".js", ".css") if self.args.style else ".js"
        for prefix in prefix_links:
            for root, _, files in os.walk(prefix):
                code_files.extend([os.path.join(root, f) for f in files if f.endswith(extensions)])
        return code_files

    def apply_changes(self):
        """执行完整的修改流程：解压->加载规则->替换->打包

        支持的修改类型：localize, trial, skip_login, style
        """
        start_time = time.monotonic()
        self.manage_workspace()
        self.decompress_asar()
        self.load_rules()
        self.replace_rules()
        self.pack_to_asar()
        if is_macos():
            self.apply_macos_fix()
        elapsed = time.monotonic() - start_time
        logging.info(f"Changes applied in {elapsed:.2f}s")

        # 统计规则匹配情况
        logging.info(f"Rules applied: {len(self.applied_rules)}/{len(self.loaded_rules)}")
        unmatched_rules = list(filter(lambda x: x not in self.applied_rules, self.loaded_rules))
        if unmatched_rules:
            if len(unmatched_rules) > 3:
                logging.warning(f"{len(unmatched_rules)} rules did not match. See debug log for details.")
            rules_list = "\n".join([f"{i + 1:>4}. {rule}" for i, rule in enumerate(unmatched_rules)])
            logging.debug(f"Unmatched rules:\n{rules_list}")
        else:
            logging.debug("All rules matched successfully")

    def find_in_content(self):
        """在代码文件中搜索包含所有指定关键词的文件"""
        find_terms = self.args.find

        if not os.path.exists(self._app_dir):
            self.decompress_asar()

        code_files = self.collect_code_files()

        found_files = []
        for file_path in code_files:
            try:
                file_content = read_file(file_path, strip_empty=False)
            except Exception as e:
                logging.warning(f"Skipping unreadable file: {file_path} - {e}")
                continue
            if file_content and all(term in file_content for term in find_terms):
                found_files.append(file_path)

        # 输出搜索结果
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

    def extract_and_unpack(self):
        """执行解包和字符串提取（不应用任何规则）"""
        logging.info("Starting unpack and string extraction...")
        start_time = time.monotonic()

        self.create_backup()
        self.decompress_asar()
        self.copy_unpacked_files()

        elapsed = time.monotonic() - start_time
        logging.info(f"Unpack and string extraction completed in {elapsed:.2f} seconds")


def get_asar_cmd():
    """根据操作系统返回 asar 命令

    Windows: asar.cmd
    macOS/Linux: asar
    """
    return "asar.cmd" if is_windows() else "asar"


def run_command(cmd, shell=False):
    """执行系统命令，失败时退出程序"""
    if isinstance(cmd, list):
        logging.debug(f"Running command: {' '.join(cmd)}")
    else:
        logging.debug(f"Running command: {cmd}")
    try:
        subprocess.run(cmd, shell=shell, check=True)
    except subprocess.CalledProcessError as e:
        logging.error(f"Command failed with exit code {e.returncode}: {' '.join(cmd) if isinstance(cmd, list) else cmd}")
        sys.exit(1)
    except FileNotFoundError as e:
        logging.error(f"Command not found: {cmd}")
        sys.exit(1)
    except Exception as e:
        logging.error(f"Unexpected error executing command: {e}")
        sys.exit(1)


def _handle_remove_readonly(func, path, _):
    """shutil.rmtree 的错误处理回调：移除只读属性后重试"""
    os.chmod(path, stat.S_IWRITE)
    func(path)


def safe_rmtree(path):
    """安全删除目录，处理只读文件

    Python 3.12+ 使用 onexc，之前版本使用 onerror
    """
    if not os.path.exists(path):
        return
    if sys.version_info >= (3, 12):
        shutil.rmtree(path, onexc=_handle_remove_readonly)
    else:
        shutil.rmtree(path, onerror=_handle_remove_readonly)


def read_file(file_path, strip_empty=True):
    """读取文件内容

    Args:
        file_path: 文件路径
        strip_empty: 是否去除空行并返回列表，否则返回完整字符串
    """
    try:
        with open(file_path, "r", encoding="utf-8") as file:
            return [line.rstrip("\r\n") for line in file if line.strip()] if strip_empty else file.read()
    except Exception as e:
        raise RuntimeError(f"Read error: {file_path} - {e}") from e


def write_file_atomic(file_path, content):
    """原子写入文件：先写临时文件再替换，避免中断导致损坏"""
    file_dir = os.path.dirname(file_path) or "."
    temp_path = None
    try:
        with tempfile.NamedTemporaryFile("w", encoding="utf-8", dir=file_dir, delete=False) as temp_file:
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


def is_comment_line(line):
    """判断是否为注释行（以 # 开头）"""
    return line.strip().startswith("#")


def is_regex_pattern(s):
    """判断是否为正则表达式模式（/pattern/ 格式，排除 // 注释）"""
    return len(s) > 1 and s.startswith("/") and s.endswith("/") and "//" not in s


def parse_replace_rule(rule):
    """解析替换规则：原字符串|新字符串

    使用 | 作为分隔符，最多分割一次以支持替换内容中包含 |
    """
    if "|" not in rule:
        raise ValueError("Invalid replacement rule format.")
    return rule.split("|", 1)


def is_valid_path(path):
    """验证路径是否存在且为目录"""
    return path and os.path.isdir(path)


def check_asar_existence(path):
    """检查指定路径下是否存在 app.asar 文件"""
    return os.path.exists(os.path.join(path, "app.asar"))


def check_asar_installed():
    """检查 asar 命令是否已安装"""
    run_command([get_asar_cmd(), "--version"])


def select_directory(title):
    """弹出文件夹选择对话框"""
    try:
        root = tk.Tk()
        root.withdraw()
        selected_path = filedialog.askdirectory(title=title)
        root.destroy()
        return selected_path if is_valid_path(selected_path) else None
    except Exception as e:
        logging.error(f"Failed to select directory: {e}")
        sys.exit(1)


def is_macos():
    return platform.system() == 'Darwin'


def is_windows():
    return platform.system() == 'Windows'


def get_termius_path(beta=False):
    """获取 Termius 安装路径

    自动检测各平台默认路径，若未找到则弹出对话框让用户选择

    Args:
        beta: 是否为 Beta 版本
    """
    app_name = "Termius Beta" if beta else "Termius"
    default_paths = {
        "Windows": lambda: os.path.join(os.getenv("LOCALAPPDATA", ""), "Programs", app_name, "resources"),
        "Darwin": lambda: f"/Applications/{app_name}.app/Contents/Resources",
        "Linux": lambda: f"/opt/{app_name}/resources"
    }
    system = platform.system()
    path_generator = default_paths.get(system)

    if path_generator:
        termius_path = path_generator()
    else:
        logging.error(f"Unsupported operating system: {system}")
        sys.exit(1)

    # 验证路径有效性，无效则让用户手动选择
    if not check_asar_existence(termius_path):
        logging.warning(f"app.asar not found at default location: {termius_path}")
        logging.info("Please select the Termius installation directory manually.")
        termius_path = select_directory("Select Termius directory containing app.asar")
        if not termius_path or not check_asar_existence(termius_path):
            logging.error("Valid app.asar file not found. Exiting.")
            sys.exit(1)

    return termius_path


def main():
    """主函数：解析参数并执行相应操作"""
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
    parser.add_argument("-v", "--verbose", type=lambda s: s.upper(), dest='log_level',
                        choices=['DEBUG', 'INFO', 'WARNING', 'ERROR', 'CRITICAL'], default='INFO',
                        help="Set logging verbosity: DEBUG|INFO|WARNING|ERROR|CRITICAL (default: %(default)s)")

    args = parser.parse_args()

    # 配置日志
    setup_logging(args.log_level)

    # 无参数时默认执行汉化
    if not any((args.trial, args.find, args.style, args.skip_login, args.localize, args.restore, args.extract)):
        args.localize = True
        logging.info("No arguments provided, defaulting to localization mode")

    check_asar_installed()
    termius_path = get_termius_path(args.beta)
    modifier = TermiusModifier(termius_path, args)

    # 根据参数执行对应操作
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
