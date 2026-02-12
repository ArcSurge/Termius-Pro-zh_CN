# -*- coding: utf-8 -*-
import argparse
import logging
import os
import platform
import re
import shutil
import stat
import subprocess
import sys
import time
import tkinter as tk
from tkinter import filedialog


class TermiusModifier:
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
        script_dir = os.path.dirname(os.path.abspath(__file__))
        return os.path.join(script_dir, "extract", "app.asar.unpack")

    @property
    def _rules_dir(self):
        """规则文件目录"""
        script_dir = os.path.dirname(os.path.abspath(__file__))
        return os.path.join(script_dir, "rules")

    def __init__(self, termius_path, args):
        """初始化修改器实例"""
        self.termius_path = termius_path
        self.args = args
        self.files_cache = {}
        self.loaded_rules = []
        self.applied_rules = set()

    def load_rules(self):
        """动态加载与参数同名的规则文件"""
        script_dir = os.path.dirname(os.path.abspath(__file__))
        # 定义需要处理的参数列表
        rule_args = ["skip_login", "trial", "style", "localize"]

        for arg in rule_args:
            if not getattr(self.args, arg, False):
                continue
            # 自动生成文件名, 强制保持参数名与文件名一致
            file_name = f"{arg}.txt"
            try:
                file_path = os.path.join(script_dir, "rules", file_name)
                if content := read_file(file_path):
                    self.loaded_rules.extend(content)
            except Exception as e:
                logging.error(f"Error loading {file_name}: {e}")
                sys.exit(1)

    def decompress_asar(self):
        """解压 app.asar 文件（使用 list 调用，避免 shell/空格问题）"""
        cmd = [get_asar_cmd(), "extract", self._original_path, self._app_dir]
        run_command(cmd)

    def copy_unpacked_files(self):
        """将解包文件复制到脚本目录下的指定文件夹"""
        try:
            # 如果目标目录已存在，先删除
            if os.path.exists(self._unpack_dir):
                shutil.rmtree(self._unpack_dir)
                logging.debug(f"Removed existing unpack directory: {self._unpack_dir}")

            # 复制整个解包目录
            shutil.copytree(self._app_dir, self._unpack_dir)
            logging.info(f"解包文件已复制到|Unpacked files copied to: {self._unpack_dir}")

            # 提取所有JSON和JS文件中的字符串
            self.extract_all_strings()

        except Exception as e:
            logging.error(f"复制解包文件失败|Failed to copy unpacked files: {e}")

    def extract_all_strings(self):
        """提取所有JSON和JS文件中的字符串到extract目录"""
        try:
            # 确保extract目录存在
            extract_dir = os.path.join(os.path.dirname(os.path.abspath(__file__)), "extract")
            os.makedirs(extract_dir, exist_ok=True)

            all_strings_file = os.path.join(extract_dir, "allstring.txt")

            # 收集所有字符串
            all_strings = set()

            # 遍历解包目录中的所有文件
            for root, dirs, files in os.walk(self._unpack_dir):
                for file in files:
                    if file.endswith(('.js', '.json')):
                        file_path = os.path.join(root, file)
                        try:
                            with open(file_path, 'r', encoding='utf-8') as f:
                                content = f.read()

                                # 提取双引号字符串
                                double_quoted_strings = re.findall(r'"([^"\\]*(?:\\.[^"\\]*)*)"', content)

                                # 提取单引号字符串
                                single_quoted_strings = re.findall(r"'([^'\\]*(?:\\.[^'\\]*)*)'", content)

                                # 提取模板字符串
                                template_strings = re.findall(r'`([^`\\]*(?:\\.[^`\\]*)*)`', content)

                                # 添加到集合中
                                all_strings.update(double_quoted_strings)
                                all_strings.update(single_quoted_strings)
                                all_strings.update(template_strings)

                        except Exception as e:
                            logging.debug(f"无法读取文件|Cannot read file {file_path}: {e}")
                            continue

            # 过滤和排序字符串
            filtered_strings = sorted([
                s for s in all_strings
                if len(s) > 1 and not s.isspace() and not re.match(r'^[0-9\.\+\-]*$', s)
            ], key=lambda x: (len(x), x.lower()))

            # 写入文件
            with open(all_strings_file, 'w', encoding='utf-8') as f:
                f.write("# 从app.asar中提取的所有字符串\n")
                f.write("# All strings extracted from app.asar\n")
                f.write(f"# 总计: {len(filtered_strings)} 个字符串\n")
                f.write(f"# Total: {len(filtered_strings)} strings\n")
                f.write("=" * 80 + "\n\n")

                for i, string in enumerate(filtered_strings, 1):
                    # 转义特殊字符以便于阅读
                    escaped_string = string.replace('\n', '\\n').replace('\t', '\\t').replace('\r', '\\r')
                    f.write(f"{i:4}. {escaped_string}\n")

            logging.info(f"字符串提取完成|String extraction completed: {all_strings_file}")
            logging.info(f"提取到 {len(filtered_strings)} 个字符串|Extracted {len(filtered_strings)} strings")

        except Exception as e:
            logging.error(f"字符串提取失败|Failed to extract strings: {e}")

    def pack_to_asar(self):
        """打包 app.asar 文件（使用 list 调用，避免 shell/空格问题）"""
        # 注意：将 --unpack-dir 作为单独的 arg 传入
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
        """完整还原操作"""
        if not os.path.exists(self._backup_path):
            logging.info("未找到备份文件，跳过恢复备份|Backup file not found, skip backup restore.")
            return

        shutil.copy(self._backup_path, self._original_path)
        logging.info("已从备份恢复|Restored from backup.")

    def create_backup(self):
        """智能备份管理（仅在缺失时创建）"""
        if not os.path.exists(self._backup_path):
            shutil.copy(self._original_path, self._backup_path)
            logging.info("创建初始备份|Created initial backup.")

    def manage_workspace(self):
        # 备份
        self.create_backup()
        self.clean_workspace()

    def clean_workspace(self):
        # 还原备份
        self.restore_backup()
        # 清理
        if os.path.exists(self._app_dir):
            safe_rmtree(self._app_dir)
            logging.debug("Cleaned app directory.")

    def restore_changes(self):
        self.clean_workspace()
        if os.path.exists(self._backup_path):
            os.remove(self._backup_path)

    def load_files(self):
        """加载所有代码文件到内存"""
        code_files = self.collect_code_files()
        for file in code_files:
            if os.path.exists(file):
                self.files_cache[file] = read_file(file, strip_empty=False)

    def replace_content(self, file_content):
        """执行内容替换的核心逻辑"""
        if not file_content:
            return file_content

        for line in self.loaded_rules:
            try:
                if is_comment_line(line):
                    self.applied_rules.add(line)
                    continue
                old_val, new_val = parse_replace_rule(line)
                original_content = file_content
                if is_regex_pattern(old_val):
                    pattern = re.compile(old_val[1:-1])
                    file_content = pattern.sub(new_val, file_content)
                else:
                    file_content = file_content.replace(old_val, new_val)

                if original_content != file_content:
                    # 仅关注内容是否改变
                    self.applied_rules.add(line)

            except ValueError as e:
                logging.error(f"Skipping invalid rule: {line} → {str(e)}")
            except re.error as e:
                logging.error(f"Regex error: {line} → {str(e)}")

        return file_content

    def replace_rules(self):
        """规则替换"""
        logging.info("开始替换汉化规则...|Starting replacement...")
        for file_path in self.files_cache:
            self.files_cache[file_path] = self.replace_content(self.files_cache[file_path])
        logging.info("替换完成|Replacement completed.")

    def write_files(self):
        """将修改后的内容写入文件"""
        logging.info("开始写入...|Starting writing...")
        for file_path, content in self.files_cache.items():
            with open(file_path, "w", encoding="utf-8") as file:
                file.write(content)
        logging.info("写入完成|Writing completed.")

    def collect_code_files(self):
        """获取所有代码文件路径"""
        prefix_links = [
            os.path.join(self._app_dir, "background-process", "assets"),
            os.path.join(self._app_dir, "ui-process", "assets"),
            os.path.join(self._app_dir, "main-process"),
        ]
        code_files = []
        for prefix in prefix_links:
            for root, _, files in os.walk(prefix):
                if self.args.style:
                    code_files.extend([os.path.join(root, f) for f in files if f.endswith((".js", ".css"))])
                else:
                    code_files.extend([os.path.join(root, f) for f in files if f.endswith(".js")])
        return code_files

    def apply_changes(self):
        """规则替换功能"""
        start_time = time.monotonic()
        self.manage_workspace()
        self.decompress_asar()
        self.load_rules()
        self.load_files()
        self.replace_rules()
        self.write_files()
        self.pack_to_asar()
        apply_macos_fix()
        elapsed = time.monotonic() - start_time
        logging.info(f"汉化在 {elapsed:.2f} 秒内完成|Replacement done in {elapsed:.2f} seconds.")

        logging.info(f"应用规则|Rules applied: {len(self.applied_rules)}/{len(self.loaded_rules)}")
        unmatched_rules = list(filter(lambda x: x not in self.applied_rules, self.loaded_rules))
        if unmatched_rules:
            if len(unmatched_rules) > 3:
                logging.warning(f"Found {len(unmatched_rules)} unmatched rules. Check debug log for details.")
            rules_list = "\n".join([f"{i + 1:>4}. {rule}" for i, rule in enumerate(unmatched_rules)])
            logging.debug(f"Unmatched rules ({len(unmatched_rules)}):\n{rules_list}")
        else:
            logging.debug("All rules matched.")

    def find_in_content(self):
        """文件内容搜索功能"""
        find_terms = self.args.find

        # 如果参数是 "extract"，则执行解包和提取字符串功能
        if find_terms and len(find_terms) == 1 and find_terms[0].lower() == "extract":
            self.extract_and_unpack()
            return

        # 原有的搜索功能
        code_files = self.collect_code_files()
        if not os.path.exists(self._app_dir):
            self.decompress_asar()

        found_files = []
        for file_path in code_files:
            file_content = read_file(file_path, strip_empty=False)
            if file_content and all(term in file_content for term in find_terms):
                found_files.append(file_path)

        # 创建分隔线
        separator = "=" * 60

        if found_files:
            # 构建搜索项列表字符串
            terms_list = "\n".join([f"  • {term}" for term in find_terms])
            # 构建文件列表字符串
            files_list = "\n".join([f"  • {file_path}" for file_path in found_files])

            logging.info(f"{separator}")
            logging.info(f"搜索结果|SEARCH RESULTS")
            logging.info(f"{separator}")
            logging.info(f"搜索目标|Search terms ({len(find_terms)}):")
            logging.info(f"{terms_list}")
            logging.info(f"在这些文件中找到|Found in files ({len(found_files)}):")
            logging.info(f"\n{files_list}")
            logging.info(f"{separator}")
        else:
            terms_list = "\n".join([f"  • {term}" for term in find_terms])
            logging.warning(f"{separator}")
            logging.warning("无结果|NO RESULTS FOUND")
            logging.warning(f"{separator}")
            logging.warning(f"搜索目标|Search terms ({len(find_terms)}):")
            logging.warning(f"{terms_list}")
            logging.warning(f"没有在解包文件中搜索到目标|No files contain all the above terms.")
            logging.warning(f"{separator}")

    def extract_and_unpack(self):
        """执行解包和提取字符串功能"""
        logging.info("开始执行解包和字符串提取...|Starting unpack and string extraction...")
        start_time = time.monotonic()

        # 创建备份
        self.create_backup()

        # 解包 asar 文件
        self.decompress_asar()

        # 复制解包文件并提取字符串
        self.copy_unpacked_files()

        elapsed = time.monotonic() - start_time
        logging.info(f"解包和字符串提取在 {elapsed:.2f} 秒内完成|Unpack and string extraction done in {elapsed:.2f} seconds.")

def get_asar_cmd():
    """
    Windows 下使用 asar.cmd
    macOS / Linux 使用 asar
    """
    return "asar.cmd" if is_windows() else "asar"

def run_command(cmd, shell=False):
    """执行系统命令"""
    if isinstance(cmd, list):
        logging.info(f"运行命令|Running command: {' '.join(cmd)}")
    else:
        logging.info(f"运行命令|Running command: {cmd}")
    try:
        subprocess.run(cmd, shell=shell, check=True)
    except subprocess.CalledProcessError as e:
        logging.error(f"Command failed: {e}")
        sys.exit(1)
    except Exception as e:
        logging.error(f"Error: {e}")
        sys.exit(1)


def _handle_remove_readonly(func, path, _):
    """处理只读文件"""
    os.chmod(path, stat.S_IWRITE)
    func(path)


def safe_rmtree(path):
    """安全删除目录"""
    if not os.path.exists(path):
        return
    if sys.version_info >= (3, 12):
        shutil.rmtree(path, onexc=_handle_remove_readonly)
    else:
        shutil.rmtree(path, onerror=_handle_remove_readonly)


def read_file(file_path, strip_empty=True):
    """安全读取文件内容"""
    try:
        with open(file_path, "r", encoding="utf-8") as file:
            return [line.rstrip("\r\n") for line in file if line.strip()] if strip_empty else file.read()
    except Exception as e:
        logging.error(f"Read error: {file_path} - {e}")
        sys.exit(1)


def is_comment_line(line):
    """判断是否为注释行"""
    return line.strip().startswith("#")


def is_regex_pattern(s):
    """判断是否为正则表达式模式(/pattern/格式)"""
    return len(s) > 1 and s.startswith("/") and s.endswith("/") and "//" not in s


def parse_replace_rule(rule):
    """分割替换规则"""
    if "|" not in rule:
        raise ValueError("Invalid replacement rule format.")
    # 最多分割一次
    return rule.split("|", 1)


def is_valid_path(path):
    """验证路径是否合法"""
    return path and os.path.isdir(path)


def check_asar_existence(path):
    """检查指定路径下是否存在 app.asar 文件"""
    return os.path.exists(os.path.join(path, "app.asar"))


def check_asar_installed():
    """检查是否安装了 asar 命令"""
    # 改为 list 调用，避免依赖 shell
    run_command([get_asar_cmd(), "--version"])


def select_directory(title):
    """弹出文件夹选择对话框, 手动文件夹路径"""
    try:
        root = tk.Tk()
        root.withdraw()
        selected_path = filedialog.askdirectory(title=title)
        root.destroy()
        return selected_path if is_valid_path(selected_path) else None
    except Exception as e:
        logging.error(f"An error occurred: {e}")
        sys.exit(1)


def is_macos():
    return platform.system() == 'Darwin'

def is_windows():
    return platform.system() == 'Windows'

def apply_macos_fix():
    if is_macos():
        logging.info("Applying macOS fix...")
        script_path = "./macos/osxfix.sh"
        run_command(["chmod", "+x", script_path])
        # 以 list 形式执行脚本（脚本已赋可执行权限）
        run_command([script_path])
        logging.info("MacOS fix applied.")


def get_termius_path():
    """获取 Termius 的路径"""
    default_paths = {
        "Windows": lambda: os.path.join(os.getenv("LOCALAPPDATA"), "Programs", "Termius", "resources"),
        "Darwin": lambda: "/Applications/Termius.app/Contents/Resources",
        "Linux": lambda: "/opt/Termius/resources"
    }
    system = platform.system()
    path_generator = default_paths.get(system)

    if path_generator:
        # 调用 lambda 函数生成路径
        termius_path = path_generator()
    else:
        logging.error(f"Unsupported OS: {system}")
        sys.exit(1)
    if not check_asar_existence(termius_path):
        logging.warning(f"Termius app.asar file not found at: {os.path.join(termius_path, 'app.asar')}")
        logging.info("Please select the correct Termius folder.")
        termius_path = select_directory("Please select the Termius path containing app.asar.")
        if not termius_path or not check_asar_existence(termius_path):
            logging.error("Valid Termius app.asar file not found. Exiting.")
            sys.exit(1)

    return termius_path


def main():
    parser = argparse.ArgumentParser(description="Modify Termius application.")
    parser.add_argument("-t", "--trial", action="store_true", help="Activate professional edition trial.")
    parser.add_argument("-k", "--skip-login", action="store_true", help="Disable authentication workflow.")
    parser.add_argument("-l", "--localize", action="store_true",
                        help="Enable localization patch (Chinese translation/adaptation).")
    parser.add_argument("-s", "--style", action="store_true", help="UI/UX customization preset.")
    parser.add_argument("-r", "--restore", action="store_true", help="Restore software to initial state.")
    parser.add_argument("-f", "--find", nargs="+", help="Multi-mode search operation.")
    parser.add_argument("--log-level", type=lambda s: s.upper(),
                        choices=['DEBUG', 'INFO', 'WARNING', 'ERROR', 'CRITICAL'], default='INFO',
                        help="Set logging level: DEBUG|INFO|WARNING|ERROR|CRITICAL (default: %(default)s)")

    args = parser.parse_args()

    # 日志配置
    logging.basicConfig(level=args.log_level, format="%(asctime)s - %(levelname)7s - %(message)s", force=True)

    # 如果没有提供参数，默认执行 `--localize`
    if not any((args.trial, args.find, args.style, args.skip_login, args.localize, args.restore)):
        args.localize = True

    check_asar_installed()
    termius_path = get_termius_path()
    modifier = TermiusModifier(termius_path, args)

    if any((args.trial, args.style, args.skip_login, args.localize)):
        modifier.apply_changes()
    elif args.find:
        modifier.find_in_content()
    elif args.restore:
        modifier.restore_changes()
    else:
        logging.error("Invalid command. Use '--help'.")


if __name__ == "__main__":
    main()