import argparse
import cloudscraper
import logging
import os
import platform
import random
import re
import shutil
import stat
import subprocess
import sys
import time

from bs4 import BeautifulSoup
from cloudscraper.exceptions import CloudflareChallengeError, CloudflareCaptchaError
from requests.exceptions import ConnectionError, HTTPError, Timeout, TooManyRedirects
from pathlib import Path
from tqdm import tqdm

# ------------------------------ Parameters Configuration ------------------------------
APP_FILE = "Termius"
DIR_TMP = ".tmp_dir"
EXT_APKM = ".apkm"
EXT_APK = ".apk"
APKM_FILENAME = f"{APP_FILE}{EXT_APKM}"
APK_EDITOR_FILENAME = "APKEditor.jar"
LANGUAGE_XML = "strings.xml"
BASE_URL = "https://www.apkmirror.com"
BASE_APK_URL = f"{BASE_URL}/apk/termius-corporation/termius-ssh-telnet-client/"
GITHUB_REPO_OWNER = "REAndroid"
GITHUB_REPO_NAME = "APKEditor"
APK_SIGN_PROPERTIES = "apk.sign.properties"
ALIGNED_SUFFIX = "_aligned"
SIGNED_SUFFIX = "_signed"
ZH_SUFFIX = "_zh"

# ------------------------------ Log Configuration ------------------------------
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s - %(levelname)-1.1s: %(message)s",
    handlers=[logging.StreamHandler()]
)
logger = logging.getLogger(__name__)

GLOBAL_HEADERS = {
    "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/138.0.0.0 Safari/537.36 Edg/138.0.0.0"
}


def get_scraper():
    """Get CloudScraper instance"""
    return CloudScraperWrapper(
        browser={
            'browser': 'chrome',
            'platform': 'windows',
            'mobile': False
        },
        delay=5,
        timeout=30,
        max_retries=3,
        user_agent=GLOBAL_HEADERS["User-Agent"],
        debug=True
    )


def is_windows():
    """Check if it's a Windows system"""
    return platform.system() == 'Windows'


def get_apksigner_shell():
    """Get apksigner shell command"""
    return "apksigner.bat" if is_windows() else "apksigner"


def split_filename(abs_path):
    """Extract filename from absolute path and separate basename and extension"""
    full_filename = os.path.basename(abs_path)
    base_name, ext = os.path.splitext(full_filename)
    return base_name, ext


def run_command(cmd, shell=False, log=True):
    """Execute system command"""
    if log:
        logging.info(f"Executing command: {cmd}")
        if isinstance(cmd, list):
            logging.info(f"Executing command: {' '.join(cmd)}")
        else:
            logging.info(f"Executing command: {cmd}")
    try:
        return subprocess.run(cmd, shell=shell, check=True)
    except subprocess.CalledProcessError as e:
        logging.error(f"Command execution failed: {e}")
        sys.exit(1)
    except Exception as e:
        logging.error(f"Execution error: {e}")
        sys.exit(1)


def replace_file(source_path, target_path):
    """Safely replace target file"""
    if not os.path.exists(source_path):
        logger.error(f"Source file does not exist, cannot replace: {source_path}")
        return False

    target_exists = os.path.exists(target_path)
    if not target_exists:
        logger.warning(f"Target file does not exist, will copy directly: {target_path}")

    try:
        shutil.copy2(source_path, target_path)
        logger.info(f"File replaced successfully: {target_path}, [Source: {source_path}]")
        return True
    except PermissionError:
        logger.error(f"No write permission for target path: {target_path}, check directory permissions")
        return False
    except Exception as e:
        logger.error(f"File replacement failed: {str(e)}")
        return False


def _handle_remove_readonly(func, path, _):
    """Handle read-only files"""
    os.chmod(path, stat.S_IWRITE)
    func(path)


def safe_rmtree(path):
    """Safely delete directory"""
    if not os.path.exists(path):
        return
    if sys.version_info >= (3, 12):
        shutil.rmtree(path, onexc=_handle_remove_readonly)
    else:
        shutil.rmtree(path, onerror=_handle_remove_readonly)


def windows_hide_file(file_path):
    """Hide Windows file"""
    run_command(["attrib", "+h", file_path])


def create_or_recreate_dir(dir_path):
    """Create or recreate directory"""
    if os.path.exists(dir_path):
        if os.path.isdir(dir_path):
            safe_rmtree(dir_path)
        else:
            os.remove(dir_path)
    os.mkdir(dir_path)
    if is_windows():
        windows_hide_file(dir_path)


class CloudScraperWrapper:
    def __init__(self, browser=None, delay=5, timeout=30, max_retries=3, user_agent=None, debug=False):
        self.browser = browser or {
            'browser': 'chrome',
            'platform': 'windows',
            'mobile': False,
            'desktop': True
        }
        self.delay = delay
        self.timeout = timeout
        self.max_retries = max_retries
        self.user_agent = user_agent
        self.debug = debug
        self.scraper = self._create_scraper()

    def _create_scraper(self):
        scraper = cloudscraper.create_scraper(browser=self.browser, delay=self.delay)

        if self.user_agent:
            scraper.headers.update({'User-Agent': self.user_agent})

        return scraper

    def _log(self, message, level="INFO"):
        level = level.lower().strip()
        valid_levels = ['debug', 'info', 'warning', 'error', 'critical']
        if level not in valid_levels:
            raise ValueError(f"无效等级: {level}. 有效值: {valid_levels}")
        log = getattr(logger, level)
        if self.debug:
            log(message)

    def _handle_exception(self, e: Exception, attempt: int) -> bool:
        if isinstance(e, CloudflareCaptchaError):
            self._log(f"Manual captcha required, stop retrying: {str(e)[:200]}", "ERROR")
            return False

        elif isinstance(e, CloudflareChallengeError):
            self._log(f"Cloudflare validation failed (Attempt {attempt + 1}/{self.max_retries}): {str(e)[:200]}", "WARNING")
            return attempt < self.max_retries - 1

        elif isinstance(e, Timeout):
            self._log(f"Request timeout (Attempt {attempt + 1}/{self.max_retries}): {str(e)}", "WARNING")
            return attempt < self.max_retries - 1

        elif isinstance(e, ConnectionError):
            self._log(f"Connection error (Attempt {attempt + 1}/{self.max_retries}): {str(e)}", "WARNING")
            return attempt < self.max_retries - 1

        elif isinstance(e, TooManyRedirects):
            self._log(f"Too many redirects: {str(e)}", "ERROR")
            return False

        elif isinstance(e, HTTPError):
            status = e.response.status_code
            if status in (429, 500, 502, 503, 504):  # Retryable status codes
                self._log(f"HTTP error {status} (Attempt {attempt + 1}/{self.max_retries}): {str(e)}", "WARNING")
                return attempt < self.max_retries - 1
            else:
                self._log(f"HTTP error {status}: {str(e)}", "ERROR")
                return False

        else:
            self._log(f"Unknown error: {type(e).__name__} - {str(e)}", "ERROR")
            return False

    def request(self, method, url, **kwargs):
        last_exception = None

        if self.timeout:
            kwargs.setdefault('timeout', self.timeout)

        for attempt in range(self.max_retries):
            try:
                # Random delay
                time.sleep(random.uniform(0.5, 1.5) * (attempt + 1))

                # Execute request
                self._log(f"Request {method} {url} (Attempt {attempt + 1}/{self.max_retries})")
                response = self.scraper.request(method, url, **kwargs)

                # Check HTTP errors
                response.raise_for_status()

                self._log(f"Successfully received response: {len(response.content)} bytes")
                return response

            except Exception as e:
                last_exception = e
                should_retry = self._handle_exception(e, attempt)

                if not should_retry:
                    break

        # All attempts failed
        error_msg = f"Request failed: {method} {url}"
        if last_exception:
            error_msg += f" - {type(last_exception).__name__}: {str(last_exception)}"
        self._log(error_msg, "CRITICAL")
        raise last_exception if last_exception else Exception("Unknown error")

    def get(self, url, **kwargs):
        return self.request('GET', url, **kwargs)

    def post(self, url, **kwargs):
        return self.request('POST', url, **kwargs)

    def download(self, url, save_path, chunk_size=8192, **kwargs):
        try:
            response = self.get(url, stream=True, **kwargs)
            response.raise_for_status()

            total_size = int(response.headers.get('content-length', 0))
            downloaded = 0

            progress_bar = tqdm(
                total=total_size,
                unit='B',
                unit_scale=True,
                unit_divisor=1024,
                desc=os.path.basename(save_path),
                leave=True
            )

            with open(save_path, 'wb') as f:
                for chunk in response.iter_content(chunk_size):
                    if chunk:
                        f.write(chunk)
                        downloaded += len(chunk)
                        progress_bar.update(len(chunk))

            progress_bar.close()
            self._log(f"File download completed: {save_path} ({downloaded}/{total_size} bytes)" if total_size else
                      f"File download completed: {save_path} (unknown size)")

            return True

        except Exception as e:
            self._log(f"Download failed: {str(e)}", "ERROR")
            return False

    def get_json(self, url, **kwargs):
        response = self.get(url, **kwargs)
        try:
            return response.json()
        except ValueError:
            self._log("Response is not valid JSON format", "ERROR")
            raise


class TermiusAPKModifier:
    """Termius APK Modifier class"""

    def __init__(self, working_dir=None):
        self.working_dir = working_dir or Path(__file__).parent.resolve()
        self._tmp_dir = None
        self.scraper = get_scraper()
        self.sign_properties = self._load_sign_properties()

    @property
    def tmp_dir(self):
        if self._tmp_dir is None:
            self._tmp_dir = self._create_tmp_dir()
        return self._tmp_dir

    @property
    def keystore_dir(self):
        keystore = os.path.join(self.working_dir, "keystore")
        if not os.path.exists(keystore):
            os.mkdir(keystore)
        return keystore

    def _create_tmp_dir(self):
        tmp_dir = os.path.abspath(os.path.join(self.working_dir, DIR_TMP))
        create_or_recreate_dir(tmp_dir)
        return tmp_dir

    def extract_version(self):
        main_page_soup = self._fetch_page(BASE_APK_URL, GLOBAL_HEADERS)

        if not main_page_soup:
            raise Exception("Failed to access main page, terminating program.")

        title_selector = '#primary > div.listWidget.p-relative .appRow h5.appRowTitle'
        title_element = main_page_soup.select_one(title_selector)

        if not title_element:
            logger.error("Application title element not found, please check selector compatibility")
            return None

        full_title = title_element.get_text(strip=True)
        version_match = re.search(r'v?(\d+\.\d+\.\d+)', full_title)

        if not version_match:
            logger.error(f"No valid version found in title: {full_title}")
            return None

        latest_version = version_match.group(1)

        if not latest_version:
            raise Exception("Failed to extract version number, terminating program.")

        logger.info(f"Detected latest version: {latest_version}")
        return latest_version

    def _fetch_page(self, url, headers=None):
        headers = headers or GLOBAL_HEADERS
        try:
            response = self.scraper.get(url, headers=headers)
            return BeautifulSoup(response.text, 'html.parser')
        except Exception as e:
            raise Exception(f"Failed to fetch page: {str(e)}")

    def _build_apkmirror_download_chain(self, base_url, version_slug, headers=None):
        headers = headers or GLOBAL_HEADERS
        try:
            download_page_url = f"{base_url.rstrip('/')}/{version_slug}-release/{version_slug}-android-apk-download/"
            download_soup = self._fetch_page(download_page_url, headers)

            if not download_soup:
                logger.error(f"Download page does not exist or is inaccessible: {download_page_url}")
                return None, None

            apk_button = download_soup.find('a', class_='downloadButton', href=True)
            if not apk_button or not apk_button['href']:
                logger.error("Android APK download button not found, page structure may have changed")
                return None, None

            full_apk_url = f"{BASE_URL}{apk_button['href'].rstrip('/')}"
            return download_page_url, full_apk_url

        except Exception as e:
            logger.error(f"Exception occurred while building download chain: {str(e)}")
            return None, None

    def _get_final_download_url(self, url):
        try:
            response = self.scraper.get(url, allow_redirects=True, timeout=15)
            soup = BeautifulSoup(response.text, 'html.parser')
            download_link = soup.find('a', id='download-link', href=True)
            if download_link:
                return f"{BASE_URL}{download_link['href']}"

            logger.error("Unable to obtain valid download link, page structure may have changed")
            return None

        except Exception as e:
            logger.error(f"Failed to obtain final link: {str(e)}")
            return None

    def _download_apk_editor_jar(self, filename=APK_EDITOR_FILENAME):
        """Download APKEditor.jar"""
        file_path = os.path.join(self.working_dir, filename)
        if os.path.exists(file_path):
            logger.info(f"{filename} already exists, skipping download")
            return

        try:
            logger.info(f"{filename} not found, starting download...")
            api_url = f"https://api.github.com/repos/{GITHUB_REPO_OWNER}/{GITHUB_REPO_NAME}/releases/latest"
            response = self.scraper.get_json(api_url)
            assets = response.get('assets', [])

            if not assets:
                raise Exception("No available assets found in latest repository release.")

            download_url = assets[0].get('browser_download_url')
            if not download_url:
                raise Exception("Asset download link not found.")

            logger.info(f"Starting download {filename}: {download_url}")
            if not self.scraper.download(download_url, file_path):
                raise Exception(f"{filename} download failed.")
            logger.info(f"{filename} download completed, saved to: {file_path}")
        except Exception as e:
            logger.error(f"Error downloading {filename}: {str(e)}")

    def _download_termius_apk(self, filename=APKM_FILENAME):
        """Download Termius.apk"""
        file_path = os.path.join(self.working_dir, filename)
        if os.path.exists(file_path):
            logger.info(f"{filename} already exists, skipping download")
            return

        try:
            logger.info(f"{filename} does not exist, starting download...")
            logger.info(f"Fetching version number for {filename}...")

            latest_version = self.extract_version()
            if not latest_version:
                raise Exception("Failed to extract version number, terminating program.")

            version_replace = latest_version.replace('.', '-')
            version_slug = f"termius-modern-ssh-client-{version_replace}"

            _, apk_download_page_url = self._build_apkmirror_download_chain(BASE_APK_URL, version_slug, GLOBAL_HEADERS)

            if not apk_download_page_url:
                raise Exception("Failed to build valid download link, terminating program.")

            direct_download_url = self._get_final_download_url(apk_download_page_url)
            if not direct_download_url:
                raise Exception("Failed to obtain final download link, terminating program.")

            logger.info(f"Obtained final download link: {direct_download_url}")
            logger.info(f"Starting download {filename}...")
            if not self.scraper.download(direct_download_url, file_path):
                raise Exception(f"{filename} download failed.")
            logger.info(f"{filename} download completed")
        except Exception as e:
            raise Exception(f"Error occurred while downloading {filename}: {str(e)}")

    def _load_sign_properties(self):
        """Load signing configuration"""
        path_sign_config_file = os.path.join(self.working_dir, APK_SIGN_PROPERTIES)
        if not os.path.exists(path_sign_config_file):
            path_sign_config_file = os.path.abspath(os.path.join(os.path.expanduser('~'), APK_SIGN_PROPERTIES))
            if not os.path.exists(path_sign_config_file):
                return None

        sign_config_file_lines = []
        with open(path_sign_config_file, 'r', encoding='UTF-8') as sign_config_file:
            sign_config_file_lines = sign_config_file.readlines()

        properties = {}
        for line in sign_config_file_lines:
            checked_line = line.strip().replace('\r', '').replace('\n', '')
            if checked_line is None or checked_line == '' or line.startswith('#'):
                continue
            line_parts = checked_line.split('=')
            if len(line_parts) != 2:
                continue
            property_key = line_parts[0].strip()
            property_value = line_parts[1].strip()
            properties[property_key] = property_value

        required_keys = ['sign.keystore', 'sign.keystore.password', 'sign.key.alias', 'sign.key.password']
        if not all(key in properties for key in required_keys):
            return None

        if any(properties[key] == '' for key in ['sign.keystore.password', 'sign.key.alias', 'sign.key.password']):
            return None

        return properties

    def _zipalign_apk(self, apk_filename):
        """Execute APK zipalign operation"""
        logger.info('Executing APK zipalign operation')
        built_apk_file = os.path.join(self.tmp_dir, apk_filename + EXT_APK)
        if not os.path.exists(built_apk_file):
            raise Exception("APK file for zipalign does not exist")

        built_apk_aligned_file = os.path.join(self.tmp_dir, apk_filename + ALIGNED_SUFFIX + EXT_APK)
        if os.path.exists(built_apk_aligned_file):
            os.remove(built_apk_aligned_file)

        run_command(['zipalign', '-p', '-f', '4', built_apk_file, built_apk_aligned_file])
        os.remove(built_apk_file)
        shutil.move(str(built_apk_aligned_file), str(built_apk_file))
        logger.info('Zipalign operation completed')

    def _generate_keystore(self, sign_config):
        """Generate keystore"""
        logger.info('Generating keystore')
        run_command([
            'keytool', '-genkeypair',
            '-alias', sign_config["sign.key.alias"],
            '-keyalg', 'RSA',
            '-keysize', '2048',
            '-validity', '10000',
            '-keystore', os.path.join(self.keystore_dir, sign_config["sign.keystore"]),
            '-storepass', sign_config["sign.keystore.password"],
            '-keypass', sign_config["sign.key.password"],
            '-dname', f"CN={sign_config['sign.key.dname.cn']},C={sign_config['sign.key.dname.c']}"
        ], log=False)
        logger.info('Keystore generation completed')

    def _sign_apk(self, apk_filename):
        """Sign APK file"""
        logger.info('Signing APK file')
        build_apk_file = os.path.join(self.tmp_dir, apk_filename + EXT_APK)
        if not os.path.exists(build_apk_file):
            raise Exception("APK file for signing does not exist")

        build_apk_signed_file = os.path.join(self.tmp_dir, apk_filename + SIGNED_SUFFIX + EXT_APK)
        if os.path.exists(build_apk_signed_file):
            os.remove(build_apk_signed_file)

        run_command([
            get_apksigner_shell(), 'sign',
            '--ks', os.path.join(self.keystore_dir, self.sign_properties["sign.keystore"]),
            '--ks-pass', f"pass:{self.sign_properties['sign.keystore.password']}",
            '--ks-key-alias', self.sign_properties["sign.key.alias"],
            '--key-pass', f"pass:{self.sign_properties['sign.key.password']}",
            '--out', build_apk_signed_file,
            build_apk_file
        ], log=False)

        logger.info('APK signing completed')
        logger.info('Verifying APK signature')
        run_command([get_apksigner_shell(), 'verify', '--verbose', build_apk_signed_file])
        logger.info('APK signature verification completed')

        os.remove(build_apk_file)
        shutil.move(str(build_apk_signed_file), str(build_apk_file))

    def _apkm_to_apk(self, apkm_file, apk_file):
        """Convert APKM to APK"""
        apk_editor_jar = os.path.join(self.working_dir, APK_EDITOR_FILENAME)
        if not os.path.exists(apk_editor_jar):
            raise Exception(f"{apk_editor_jar} not found.")
        if os.path.exists(apk_file):
            os.remove(apk_file)
        run_command(['java', '-jar', apk_editor_jar, 'm', '-i', apkm_file, '-o', apk_file])

    def _decode_apk(self, apk_file, out_dir):
        """Decompile APK file"""
        apk_editor_jar = os.path.join(self.working_dir, APK_EDITOR_FILENAME)
        if not os.path.exists(apk_editor_jar):
            raise Exception(f"{apk_editor_jar} not found.")
        if os.path.exists(out_dir):
            safe_rmtree(out_dir)
        run_command(['java', '-jar', apk_editor_jar, 'd', '-i', apk_file, '-o', out_dir])

    def _replace_language_xml(self, target_dir):
        """Replace language resource file"""
        if not os.path.exists(self.working_dir):
            raise Exception(f"Failed to replace {LANGUAGE_XML}, source file not found: {self.working_dir}")
        src_xml = os.path.join(self.working_dir, LANGUAGE_XML)
        tar_xml = os.path.join(target_dir, 'resources', 'package_1', 'res', 'values-zh-rCN', LANGUAGE_XML)
        logger.info(f"Replacing language file: Source={src_xml}, Target={tar_xml}")
        replace_file(src_xml, tar_xml)

    def _build_apk(self, out_dir, apk_filename):
        """Repackage APK file"""
        apk_editor_jar = os.path.join(self.working_dir, APK_EDITOR_FILENAME)
        if not os.path.exists(apk_editor_jar):
            raise Exception(f"{apk_editor_jar} not found.")
        if not os.path.exists(out_dir):
            raise Exception("Decompile directory not found.")
        apk_file = os.path.join(self.tmp_dir, apk_filename + EXT_APK)
        if os.path.exists(apk_file):
            os.remove(apk_file)
        run_command(['java', '-jar', apk_editor_jar, 'b', '-i', out_dir, '-o', apk_file])

    def _export_apk(self, apk_filename, export_filename):
        """Export final APK file"""
        apk_file = os.path.join(self.tmp_dir, apk_filename + EXT_APK)
        out_dir = os.path.join(self.working_dir, "out")
        if not os.path.exists(out_dir):
            os.mkdir(out_dir)
        export_apk_file = os.path.join(out_dir, export_filename + EXT_APK)
        if os.path.exists(export_apk_file):
            os.remove(export_apk_file)
        shutil.move(str(apk_file), str(export_apk_file))

    def _check_required_files(self):
        """Check if required files exist"""
        language_xml = os.path.join(self.working_dir, LANGUAGE_XML)
        if not os.path.exists(language_xml):
            raise Exception("Language xml not found.")

        termius_apk = os.path.join(self.working_dir, APKM_FILENAME)
        if not os.path.exists(termius_apk):
            self._download_termius_apk(APKM_FILENAME)

        apk_editor_jar = os.path.join(self.working_dir, APK_EDITOR_FILENAME)
        if not os.path.exists(apk_editor_jar):
            self._download_apk_editor_jar(APK_EDITOR_FILENAME)

        sign_keystore = os.path.join(self.keystore_dir, self.sign_properties["sign.keystore"])
        if not os.path.exists(sign_keystore):
            self._generate_keystore(self.sign_properties)

    def modify_apk(self):
        """Main method to modify APK file"""
        if not self.sign_properties:
            logger.error("Signing configuration file not found")
            sys.exit(1)

        try:
            logger.info("Starting APK file processing")
            self._check_required_files()

            decompile_dir = os.path.join(self.tmp_dir, APP_FILE)
            apkm_file = os.path.join(self.working_dir, APP_FILE + EXT_APKM)
            apk_file = os.path.join(self.tmp_dir, APP_FILE + EXT_APK)
            filename_zh = APP_FILE + ZH_SUFFIX

            logger.info("Converting APKM to APK")
            self._apkm_to_apk(apkm_file, apk_file)

            logger.info("Decompiling APK file")
            self._decode_apk(apk_file, decompile_dir)

            logger.info("Replacing language resources")
            self._replace_language_xml(decompile_dir)

            logger.info("Repackaging APK file")
            self._build_apk(decompile_dir, filename_zh)

            logger.info("Executing zipalign operation")
            self._zipalign_apk(filename_zh)

            logger.info("Signing APK file")
            self._sign_apk(filename_zh)

            logger.info("Exporting final APK file")
            self._export_apk(filename_zh, APP_FILE)

            logger.info(f"Cleaning temporary directory: {self.tmp_dir}")
            safe_rmtree(self.tmp_dir)

            logger.info("APK modification completed")

        except Exception as e:
            logger.error(f"Process terminated abnormally: {e}")
            sys.exit(1)


def main():
    """Main function"""
    logger.info("Process initialization started")
    parser = argparse.ArgumentParser(
        description="🔧 Termius APK Localization Modification Tool",
        epilog="📝 Usage examples:\n  python apktools.py -l  # Execute localization modification\n  python apktools.py -v  # Display version information",
        formatter_class=argparse.RawDescriptionHelpFormatter
    )

    parser.add_argument(
        "-l", "--localize",
        action="store_true",
        help="🌍 Enable localization patch (Chinese translation)"
    )

    parser.add_argument(
        "-v", "--version",
        action="store_true",
        help="📌 Display program version information"
    )

    args = parser.parse_args()

    modifier = TermiusAPKModifier()
    if args.version:
        try:
            version = modifier.extract_version()
            if version:
                print(version)
            else:
                print("0.0.0")
                sys.exit(1)
        except Exception as e:
            print(f"Error: {e}")
            sys.exit(1)

    if not args.localize and not args.version:
        logger.info("No parameters specified, will execute default localization operation")
        args.localize = True

    if args.localize:
        modifier.modify_apk()

    logger.info("Process completed")


if __name__ == "__main__":
    main()
