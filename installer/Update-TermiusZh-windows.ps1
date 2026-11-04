# Windows Termius 汉化脚本（自动匹配已安装版本）。
#
# 用法：
#   Update-TermiusZh-windows.cmd                 双击运行：检查后汉化（默认 localize 包）
#   Update-TermiusZh-windows.cmd -check          只检查，不改动任何文件
#   Update-TermiusZh-windows.cmd -trial          用「汉化 + 试用」包
#   Update-TermiusZh-windows.cmd -skip           用「汉化 + 跳过登录」包
#
#   powershell -ExecutionPolicy Bypass -File .\Update-TermiusZh-windows.ps1 -Apply
#   powershell -ExecutionPolicy Bypass -File .\Update-TermiusZh-windows.ps1 -TargetVersion 9.43.1
#   powershell -ExecutionPolicy Bypass -File .\Update-TermiusZh-windows.ps1 -Help
#
# 参数：
#   -Apply            真正下载并替换；不带此参数时只检查，不改动任何文件
#   -CheckOnly        显式指定只检查（与不带 -Apply 等价）
#   -Flavor <类型>    汉化包类型，三选一：
#                       localize  仅汉化（默认）
#                       trial     汉化 + 试用（去掉 Upgrade now 等按钮）
#                       skip      汉化 + 跳过登录（离线可用）
#   -TargetVersion <x.y.z>  指定版本，默认取本机已安装 Termius 的版本号。
#                     仅在自动识别失败，或想装与当前不同版本的包时才需要。
#   -InstallDir       指定 Termius 安装目录，默认 %LOCALAPPDATA%\Programs\Termius
#   -Beta             操作 Termius Beta
#   -Help             显示本说明
#
# 只下载与本机版本号严格对应的包；该版本未发布时直接报错，不会退到相近版本。
# 只用系统自带的 Windows PowerShell、.NET 与 curl.exe（Win10 1803 起自带），无需安装任何工具。
# 会替换 resources\app.asar，并在必要时关闭 Termius.exe 的 asar 完整性熔丝；
# 不创建备份、不自动回滚。修改代码签名后内置自动更新可能不可用。

[CmdletBinding()]
param(
  [switch]$Apply,
  [switch]$CheckOnly,
  [switch]$Beta,
  [switch]$Help,
  [ValidateSet('localize', 'trial', 'skip')]
  [string]$Flavor = 'localize',
  [string]$TargetVersion,
  [string]$InstallDir
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# 结束时等一次按键再关窗，让用户看清结果。
# launcher 把 PowerShell 的 stdin 单独接到 CON（<CON），虽然 cmd 自身 stdin 是 NUL，
# 但控制台输入句柄仍可用；ReadKey 在某些宿主/句柄组合下会抛异常，因此安全回退。
function Wait-EnterIfInteractive {
  if (-not [Console]::IsOutputRedirected) {
      try {
          Write-Host '按任意键关闭此窗口…' -NoNewline
          [void][Console]::ReadKey($true)
      } catch {
          # 控制台输入句柄不可读（例如宿主重定向）时不再抛二次错误。
      }
      Write-Host ''
  }
}

trap {
  Write-Host "错误：$($_.Exception.Message)" -ForegroundColor Red
  Wait-EnterIfInteractive
  exit 1
}

# Ctrl+C 处理：用 Windows 原生控制台回调，不依赖 PowerShell 事件管线。
# 回调线程只设置线程安全标志并返回 TRUE；下载主循环检测后停止 curl，
# 避免 Ctrl+C 被 PowerShell/curl 抢先当作终止信号而误报下载完成。
if (-not ('TermiusZh.ConsoleSignal' -as [type])) {
  Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Threading;
namespace TermiusZh {
  public static class ConsoleSignal {
      public static volatile int CtrlCPressed;
      private delegate bool HandlerRoutine(uint controlType);
      private static HandlerRoutine handler = Handle;
      [DllImport("kernel32.dll", SetLastError=true)]
      private static extern bool SetConsoleCtrlHandler(HandlerRoutine callback, bool add);
      private static bool Handle(uint controlType) {
          if (controlType == 0) {
              CtrlCPressed = 1;
              return true;
          }
          return false;
      }
      public static bool Install() { return SetConsoleCtrlHandler(handler, true); }
  }
}
'@
}
[TermiusZh.ConsoleSignal]::CtrlCPressed = 0
if (-not [Console]::IsOutputRedirected) {
  if (-not [TermiusZh.ConsoleSignal]::Install()) {
      throw '无法注册 Ctrl+C 控制台处理器。'
  }
}

# 双击运行的窗口是本脚本专属的：设置标题，并在开头告知用户中断与关窗方式。
try {
  $Host.UI.RawUI.WindowTitle = 'Termius 汉化'
} catch { }
Write-Host 'Termius 汉化脚本'
Write-Host ''

# 关掉 PowerShell 自带的进度渲染。Invoke-WebRequest 这类命令会用它反复重绘
# 控制台底部，重绘时会把上方含中文的行覆盖成残影（每个字看起来像画了两遍）。
# 下载进度由 Save-FileWithProgress 自己输出，用户仍然能看到百分比。
$ProgressPreference = 'SilentlyContinue'
# -Help 打印脚本头部注释（到 param 之前为止），然后退出，不碰任何文件。
if ($Help) {
  $inHeader = $true
  foreach ($line in (Get-Content -LiteralPath $PSCommandPath)) {
      if ($line -match '^\[CmdletBinding') { $inHeader = $false }
      if ($inHeader -and $line -match '^#') { $line -replace '^#\s?', '' }
  }
  exit 0
}

# 配置文件与本脚本同目录；不存在时全部使用内置默认值。
$ConfFile = $null
function Read-ConfValue {
  param([string]$Key)
  if (-not $ConfFile) { return $null }
  foreach ($line in (Get-Content -LiteralPath $ConfFile -ErrorAction SilentlyContinue)) {
      if ($line -match "^\s*$Key\s*=\s*(.*)$") {
          # 去掉行尾注释与空白
          return ($Matches[1] -replace '\s+#.*$', '').Trim()
      }
  }
  return $null
}


Write-Host '正在读取配置…'
$confPath = Join-Path $PSScriptRoot 'TermiusZh.conf'
if (Test-Path -LiteralPath $confPath -PathType Leaf) { $ConfFile = $confPath }

$Repo = 'ArcSurge/Termius-Pro-zh_CN'
# Electron 熔丝表：哨兵 + 版本字节 + 数量字节 + 每项一个状态字节。
# 第 4 项为 EnableEmbeddedAsarIntegrityValidation：'1' 开启，'0' 关闭，'r' 重置。
$FuseSentinel = 'dL7pKGdnNz796PbbjQWNKmHXBZaB9tsX'
$FuseIndex = 4
$StateEnabled = [byte][char]'1'
$StateDisabled = [byte][char]'0'

if ($Apply -and $CheckOnly) { throw '请只使用 -Apply 或 -CheckOnly 之一。' }
if ($env:OS -ne 'Windows_NT') { throw '本脚本仅支持 Windows。' }

$ProcessName = if ($Beta) { 'Termius Beta' } else { 'Termius' }
$ExeName = if ($Beta) { 'Termius Beta.exe' } else { 'Termius.exe' }

Write-Host "正在定位 $ProcessName…"
# ---- 定位安装目录 ---------------------------------------------------------

function Resolve-InstallDir {
  param([string]$Explicit)

  if ($Explicit) {
      if (-not (Test-Path -LiteralPath $Explicit -PathType Container)) {
          throw "安装目录不存在：$Explicit"
      }
      return [IO.Path]::GetFullPath($Explicit)
  }

  $candidates = @(
      (Join-Path $env:LOCALAPPDATA "Programs\$ProcessName")
      (Join-Path $env:ProgramFiles $ProcessName)
      (Join-Path ${env:ProgramFiles(x86)} $ProcessName)
  )
  foreach ($candidate in $candidates) {
      if (-not $candidate) { continue }
      if (Test-Path -LiteralPath (Join-Path $candidate "resources\app.asar") -PathType Leaf) {
          return $candidate
      }
  }
  throw "未找到 $ProcessName。请确认已安装，或用 -InstallDir 指定安装目录。"
}

# 命令行参数优先；否则用配置文件；两者都没有才自动查找。
if (-not $InstallDir) {
  $confInstallDir = Read-ConfValue 'install_dir'
  if ($confInstallDir) { $InstallDir = $confInstallDir }
}

# beta 配置与 -Beta 参数是"或"的关系：任一为真就按 Beta 处理。
$confBeta = Read-ConfValue 'beta'
if ($confBeta -match '^(yes|true|1|on)$') { $Beta = $true }

# 配置可能改变了 Beta 状态，这里重新计算进程名与主程序名。
$ProcessName = if ($Beta) { 'Termius Beta' } else { 'Termius' }
$ExeName = if ($Beta) { 'Termius Beta.exe' } else { 'Termius.exe' }

$install = Resolve-InstallDir -Explicit $InstallDir

# 路径名与 beta 设置必须一致：Beta 目录名以 "Termius Beta" 结尾。
$installLeaf = Split-Path -Leaf $install
if ($Beta -and $installLeaf -eq 'Termius') {
  throw "安装路径指向正式版（$install），但配置/参数启用了 Beta。请改用 Beta 的路径，或关掉 beta 配置。"
}
if (-not $Beta -and $installLeaf -eq 'Termius Beta') {
  throw "安装路径指向 Beta 版（$install），但配置/参数没有启用 Beta。请在配置里设 beta = yes 或用 -Beta。"
}
$exe = Join-Path $install $ExeName
$asar = Join-Path $install 'resources\app.asar'
if (-not (Test-Path -LiteralPath $exe -PathType Leaf)) { throw "找不到主程序：$exe" }
if (-not (Test-Path -LiteralPath $asar -PathType Leaf)) { throw "找不到 app.asar：$asar" }

# ---- 版本 ----------------------------------------------------------------

# 版本取自可执行文件的 ProductVersion，而不是更新源或可能已被替换过的 app.asar。
# 默认取本机已安装的版本；用 -TargetVersion 显式指定时以指定值为准。
$productVersion = (Get-Item -LiteralPath $exe).VersionInfo.ProductVersion
if ($TargetVersion) {
  if ($TargetVersion -notmatch '^(\d+\.\d+\.\d+)$') {
      throw "版本号格式应为 x.y.z（例如 10.2.1），当前传入：$TargetVersion"
  }
  $version = $Matches[1]
} else {
  if ($productVersion -notmatch '^(\d+\.\d+\.\d+)(?:\.0)?$') {
      throw "无法识别 Termius 版本（$productVersion），请用 -TargetVersion 手动指定。"
  }
  $version = $Matches[1]
}
# Beta 版的发布标签与文件名都多一个 -beta 后缀：
#   标签 v10.3.0-beta，文件 app-windows-localize-beta.asar
$betaSuffix = if ($Beta) { '-beta' } else { '' }
$tag = "v$version$betaSuffix"

# 配置文件的 package 非空时：以 .asar 结尾按完整文件名原样使用；否则按 l/t/s 简写自动拼接。
$confPackage = if ($Flavor -eq 'localize') { Read-ConfValue 'package' } else { $null }
if ($confPackage) {
  if ($confPackage -match '\.asar$') {
      # 完整文件名：原样使用，但要校验平台与 Beta 后缀。
      if ($confPackage -match '^app-(macos|linux)') {
          throw "配置文件里的 package 是其它平台的包（$confPackage），Windows 应使用 app-windows 开头的文件名。"
      }
      if ($Beta -and $confPackage -notmatch '\-beta\.asar$') {
          throw "配置文件里的 package 是正式版文件名（$confPackage），但已启用 Beta。Beta 版文件名应以 -beta.asar 结尾，例如 app-windows-localize-beta.asar。"
      }
      if (-not $Beta -and $confPackage -match '\-beta\.asar$') {
          throw "配置文件里的 package 是 Beta 版文件名（$confPackage），但未启用 Beta。请在配置里设 beta = yes 或用 -Beta，或改用正式版文件名。"
      }
      $assetName = $confPackage
  } else {
      # 简写：l/t/s 字母组合，自动按平台和 Beta 拼全名。
      if ($confPackage -notmatch '^[lts]+$') {
          throw "配置文件里的 package 简写只能用 l / t / s 字母组合，当前为：$confPackage"
      }
      $suffix = ''
      if ($confPackage -match 'l') { $suffix += '-localize' }
      if ($confPackage -match 't') { $suffix += '-trial' }
      if ($confPackage -match 's') { $suffix += '-skip' }
      $assetName = "app-windows$suffix$betaSuffix.asar"
  }
} else {
  # 官方资源命名规则：localize 无后缀，另两种为 localize-trial / localize-skip，
  # Beta 版再统一追加 -beta。
  $flavorSuffix = if ($Flavor -eq 'localize') { '' } else { "-$Flavor" }
  $assetName = "app-windows-localize$flavorSuffix$betaSuffix.asar"
}
$assetUrl = "https://github.com/$Repo/releases/download/$tag/$assetName"


Write-Host '正在获取汉化包校验信息…'
# 旧版本的发布没有这个文件，取不到时为空，脚本回退到下载后直接安装。
$sumsExpected = $null
$assetPattern = [regex]::Escape($assetName)
try {
  $sumsTxt = Invoke-WebRequest -Uri "https://github.com/$Repo/releases/download/$tag/SHA256SUMS-windows.txt" -UseBasicParsing -TimeoutSec 60 -ErrorAction Stop
  # GitHub 以 application/octet-stream 返回该文件，PS 5.1 与 PS 7 的 .Content 都是 byte[]，
  # 直接 -split 得到的是一串数字而不是文本行，必须先解码。
  $sumsContent = $sumsTxt.Content
  if ($sumsContent -is [byte[]]) { $sumsContent = [Text.Encoding]::UTF8.GetString($sumsContent) }
  foreach ($line in ($sumsContent -split "`n")) {
      # 归一化：容忍二进制模式星号（Git Bash/MSYS2）与 CRLF 行尾。
      $line = $line.Trim() -replace ' \*', '  '
      if ($line -match "^([0-9a-f]{64})\s+$assetPattern\s*$") {
          $sumsExpected = $Matches[1]
          break
      }
  }
} catch {
  # 取不到就保持 $null：尝试从 GitHub 资产页解析（旧 release 没有 SHA256SUMS 文件）。
}
if (-not $sumsExpected) {
  try {
    $page = Invoke-WebRequest -Uri "https://github.com/$Repo/releases/expanded_assets/$tag" -UseBasicParsing -TimeoutSec 60 -ErrorAction Stop
    if ($page.Content -match "digest for $assetPattern`".*?value=`"sha256:([0-9a-f]{64})`"") {
      $sumsExpected = $Matches[1]
    }
  } catch {
    # 页面取不到也保持 $null：回退到下载后直接安装。
  }
}


# ---- 辅助 ----------------------------------------------------------------

function Assert-TermiusStopped {
  # 任何 Termius 进程在跑（包括另一个安装）都不安全；绝不结束用户的会话。
  if (Get-Process -Name $ProcessName -ErrorAction SilentlyContinue) {
      throw "请先完全退出 $ProcessName 再运行。"
  }
}

function Get-AsarIntegrityFuse {
  param([string]$Path)

  $stream = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
  try {
      $buffer = New-Object byte[] (1024 * 1024)
      $carry = ''
      $position = [long]0
      $found = [long]-1
      while (($read = $stream.Read($buffer, 0, $buffer.Length)) -gt 0) {
          # 用 ASCII 解码保留哨兵；非 ASCII 字节无法伪造出哨兵。保留重叠区以处理跨块命中。
          $chunk = $carry + [Text.Encoding]::ASCII.GetString($buffer, 0, $read)
          $start = 0
          while (($hit = $chunk.IndexOf($FuseSentinel, $start, [StringComparison]::Ordinal)) -ge 0) {
              if ($found -ge 0) { throw '主程序中有多个 Electron 熔丝表，拒绝修改。' }
              $found = $position - $carry.Length + $hit + $FuseSentinel.Length
              $start = $hit + 1
          }
          $carry = $chunk.Substring([Math]::Max(0, $chunk.Length - ($FuseSentinel.Length - 1)))
          $position += $read
      }
      if ($found -lt 0) { throw '主程序中没有 Electron 熔丝表，拒绝修改。' }
      if ($stream.Length -lt $found + 2) { throw 'Electron 熔丝表不完整，拒绝修改。' }
      $stream.Position = $found
      $wireVersion = $stream.ReadByte()
      $fuseCount = $stream.ReadByte()
      if ($wireVersion -ne 1 -or $fuseCount -le $FuseIndex -or
          $stream.Length -lt ($found + 2 + $fuseCount)) {
          throw 'Electron 熔丝表布局不受支持，拒绝修改。'
      }
      $offset = $found + 2 + $FuseIndex
      $stream.Position = $offset
      $state = $stream.ReadByte()
      if ($state -notin @($StateEnabled, $StateDisabled, [byte][char]'r')) {
          throw "asar 完整性熔丝状态异常（$state），拒绝修改。"
      }
      return [pscustomobject]@{ Offset = $offset; State = $state }
  } finally {
      $stream.Dispose()
  }
}

# 同卷改名覆盖目标，不创建备份。Windows PowerShell 5.1 不支持
# File.Replace(source, target, $null)，改用 MoveFileExW + REPLACE_EXISTING。
if (-not ('TermiusZh.NativeFile' -as [type])) {
  Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
namespace TermiusZh {
  public static class NativeFile {
      [DllImport("kernel32.dll", EntryPoint="MoveFileExW", CharSet=CharSet.Unicode, ExactSpelling=true, SetLastError=true)]
      private static extern bool MoveFileEx(string source, string target, int flags);
      public static void Replace(string source, string target) {
          const int MOVEFILE_REPLACE_EXISTING = 0x1;
          const int MOVEFILE_WRITE_THROUGH = 0x8;
          if (!MoveFileEx(source, target, MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH)) {
              throw new Win32Exception(Marshal.GetLastWin32Error());
          }
      }
  }
}
'@
}

function Get-Sha256 {
  param([string]$Path)
  # 不用 Get-FileHash：launcher 经 CALL <NUL 重定向 stdin 后，PS 5.1 的模块
  # 自动加载被禁用，Get-FileHash 不存在。.NET API 不受影响，且流式读取省内存。
  $sha = [Security.Cryptography.SHA256]::Create()
  $stream = [IO.File]::OpenRead($Path)
  try {
      ([BitConverter]::ToString($sha.ComputeHash($stream))).Replace('-', '').ToLower()
  } finally {
      $stream.Dispose()
      $sha.Dispose()
  }
}




# 下载并显示进度。
#
# 用系统自带 curl.exe（Win10 1803+）下载，PowerShell 主线程轮询调度：
#   - curl 以独立进程后台运行（Start-Process -PassThru），用 --progress-bar
#     在终端画出与 Linux/macOS 端一致的进度条，自带断点续传（-C -）、
#     重试（--retry 3）与停滞检测（--speed-time/--speed-limit）；
#   - PS 每 500ms 轮询一次：curl 退出则结束；键盘缓冲区有 Ctrl+C 则停掉 curl、
#     抛出「已中断」。主线程不被任何长调用阻塞，中断响应及时，
#     TermiusZh.ConsoleSignal 回调使 PowerShell 本身不会被 Ctrl+C 杀掉；
#   - 非终端（输出被重定向）时 curl 会自动隐藏进度条。
#
# 优先用 System32 下的系统 curl：PATH 里可能先命中 Git/Conda 带的 OpenSSL 版 curl。

# Schannel 后端默认强制检查证书吊销，吊销服务器不可达时报
# CRYPT_E_REVOCATION_OFFLINE (0x80092013)，curl 退出码 35。
# 7.70.0+ 用 --ssl-revoke-best-effort：能查到吊销状态仍会拦截，查不到才放行；
# 7.44.0+ 只能用 --ssl-no-revoke；更旧的版本不认识这些参数，传了会直接失败。
function Get-CurlRevokeOption {
  param([string]$CurlPath)

  try {
      $versionText = (& $CurlPath -V 2>$null) -join "`n"
  } catch {
      return @()
  }
  # 旧版 curl（如 Win10 1803 自带的 7.55.1）把 Schannel 后端显示为 WinSSL。
  if ($versionText -notmatch '(?i)\b(Schannel|WinSSL)\b') { return @() }
  if ($versionText -notmatch '(?m)^curl\s+(\d+)\.(\d+)\.(\d+)') { return @() }

  $curlVersion = [version]('{0}.{1}.{2}' -f $Matches[1], $Matches[2], $Matches[3])
  if ($curlVersion -ge [version]'7.70.0') { return @('--ssl-revoke-best-effort') }
  if ($curlVersion -ge [version]'7.44.0') { return @('--ssl-no-revoke') }
  return @()
}

# Start-Process -ArgumentList 只用空格拼接数组、不加引号：TEMP 路径含空格
# （例如用户名 "John Smith"）时 curl 会把路径拆成多个参数。这里按 Windows
# 命令行解析规则（CommandLineToArgvW）自己加引号：引号前的反斜杠要翻倍，
# 结尾反斜杠也要翻倍，否则会把收尾引号转义掉。
function ConvertTo-CommandLineArgument {
  param([string]$Value)

  if ($Value -and $Value -notmatch '[\s"]') { return $Value }
  $escaped = [regex]::Replace($Value, '(\\*)"', { param($m) $m.Groups[1].Value * 2 + '\"' })
  $escaped = [regex]::Replace($escaped, '(\\+)$', { param($m) $m.Groups[1].Value * 2 })
  return '"' + $escaped + '"'
}

function Save-FileWithProgress {
   param(
       [string]$Url,
       [string]$Destination
   )

   $interactive = -not [Console]::IsOutputRedirected

   $curlExe = Join-Path $env:SystemRoot 'System32\curl.exe'
   if (-not (Test-Path -LiteralPath $curlExe -PathType Leaf)) { $curlExe = 'curl.exe' }

   $curlArgs = @(
       '--fail', '--location', '--retry', '3', '-C', '-'
       '--connect-timeout', '20', '--speed-time', '60', '--speed-limit', '1024'
   ) + @(Get-CurlRevokeOption -CurlPath $curlExe) + @(
       '--progress-bar', '--show-error', '--output', $Destination, $Url
   )
   $curlCommandLine = ($curlArgs | ForEach-Object { ConvertTo-CommandLineArgument $_ }) -join ' '
   $curl = Start-Process -FilePath $curlExe -ArgumentList $curlCommandLine -NoNewWindow -PassThru
   # Windows PowerShell 5.1 里，不带 -Wait 的 Start-Process 若没人提前取过进程句柄，
   # 进程退出后 ExitCode 会是 $null，下面的失败判断就被跳过。先取一次句柄让它缓存下来。
   $null = $curl.Handle

   try {
       while ($true) {
           # 先查取消标志，避免把 Ctrl+C 误判为下载成功。
           if ([TermiusZh.ConsoleSignal]::CtrlCPressed -ne 0) {
               try { if (-not $curl.HasExited) { $curl.Kill() } } catch {
               }
               if ($interactive) { Write-Host '' }
               throw '已手动中断（Ctrl+C）。已下载的部分已保留，下次运行将从断点继续。'
           }
           if ($curl.HasExited) { break }
           Start-Sleep -Milliseconds 500
       }
   } finally {
       try { if (-not $curl.HasExited) { $curl.Kill() } } catch {
       }
   }

  $curl.WaitForExit()
  $curl.Refresh()
  if ($interactive) { Write-Host '' }
  $curlExitCode = $curl.ExitCode
  if ([TermiusZh.ConsoleSignal]::CtrlCPressed -ne 0) {
      throw '已手动中断（Ctrl+C）。已下载的部分已保留，下次运行将从断点继续。'
  }
  if ($null -eq $curlExitCode) {
      throw '无法获取 curl 退出码，不能确认下载是否成功。'
  }
  if ($curlExitCode -ne 0) {
      throw "下载失败（curl 退出码 $curlExitCode）。"
  }
  if (-not (Test-Path -LiteralPath $Destination -PathType Leaf)) {
      throw 'curl 结束但没有生成下载文件。'
  }
}
# ---- 检查 -----------------------------------------------------------------

Write-Host '正在检查本机文件…'

$fuse = Get-AsarIntegrityFuse $exe

# 本机已装的 app.asar 与官方包一致时跳过下载：重复运行不再重复耗流量。
$sameAsar = $false
if ($sumsExpected -and (Get-Sha256 $asar) -eq $sumsExpected) { $sameAsar = $true }

Write-Host "安装目录 : $install"
$versionLabel = if ($TargetVersion) { '指定版本' } else { '本机版本' }
Write-Host "${versionLabel} : $version"
Write-Host "目标版本 : $ProcessName"
Write-Host "汉化包   : $assetUrl"
if ($sameAsar) { Write-Host '本机文件 : 与官方包一致，跳过下载' }
Write-Host "完整性熔丝: $(if ($fuse.State -eq $StateEnabled) { '开启' } else { '已关闭' })"

Write-Host '正在检查汉化包可用性…'
if (-not $Apply) {
  $available = '未知'
  try {
      $head = Invoke-WebRequest -Uri $assetUrl -Method Head -UseBasicParsing -MaximumRedirection 5
      if ($head.StatusCode -eq 200) { $available = '可用' }
  } catch {
      $status = $null
      if ($_.Exception.Response) { $status = [int]$_.Exception.Response.StatusCode }
      if ($status -eq 404) { $available = "该版本暂无 $assetName" }
  }
  if ($sameAsar) { $available = '可用（本机已是该包）' }
  Write-Host "汉化包状态: $available"
  Write-Host '仅检查：未改动任何文件。去掉 -CheckOnly 并加 -Apply 才会真正写入。'
  Wait-EnterIfInteractive
  exit 0
}

# ---- 下载 -----------------------------------------------------------------

# 先下载，确认这个版本确实有对应汉化包，再动本地文件。
# 本机 hash 与官方校验值一致时跳过下载，只按需关闭熔丝。
#
# 下载临时文件名 = 发布标签 + 官方 hash 前 8 位 + 资产名。
# curl -C - 续传只发 Range、不带 If-Range：维护者在同一标签下重传同名资产后，
# 服务器照样返回 206，旧 .part 的前半段会和新包的后半段拼成一个长度正确、
# 内容错误的文件。hash 进文件名后，重传会换一个文件名，旧片段不会再被续传。
# 取不到官方 hash 时文件名不带 hash，且不续传（见下载分支）。
$tempRoot = if ($env:TEMP) { $env:TEMP } else { [IO.Path]::GetTempPath() }
$hashTag = if ($sumsExpected) { '-' + $sumsExpected.Substring(0, 8) } else { '' }
$cacheFile = Join-Path $tempRoot ("termius-zh-$tag$hashTag-$assetName")
$download = "$cacheFile.part"
$stagedAsar = $null
$stagedExe = $null
$exeReplaced = $false
$asarReplaced = $false

# TEMP 里可能残留同名目录，或被重定向到别处的符号链接/联接点：
# 不先清理，后面的移动、复制会以“拒绝访问”这类原始异常失败。
function Remove-BlockingPath {
  param([string]$Path)

  if (-not (Test-Path -LiteralPath $Path)) { return }
  $item = Get-Item -LiteralPath $Path -Force
  if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
      # 只删链接本身，不跟随到目标目录（Remove-Item -Recurse 会跟进去）。
      if ($item.PSIsContainer) { [IO.Directory]::Delete($Path, $false) }
      else { [IO.File]::Delete($Path) }
      return
  }
  if ($item.PSIsContainer) { Remove-Item -LiteralPath $Path -Recurse -Force }
}

# 成功后清理同一渠道的旧缓存与片段：旧版本、旧命名格式、被重传替换掉的 hash。
# 正式版与 Beta 分开清理：Beta 文件名含 -beta-，两者可能同时安装、交替运行，
# 互相删缓存会导致白下载，也可能删到另一个渠道正在写入的 .part。
# 当前包的缓存保留，供重复运行或回退时复用。删除失败（文件被占用）就跳过。
function Remove-StaleTermiusCache {
  param([string]$Keep)

  $isBetaFile = { param($name) $name -match '-beta[-.]' }
  Get-ChildItem -LiteralPath $tempRoot -Filter 'termius-zh-*' -File -ErrorAction SilentlyContinue |
      Where-Object { $_.FullName -ne $Keep -and (& $isBetaFile $_.Name) -eq [bool]$Beta } |
      ForEach-Object { Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue }
}

try {
  if ($sameAsar) {
      $assetHash = $sumsExpected
  } else {
      $assetHash = $null
      # TEMP 路径被目录或链接占用时既不能当缓存也不能当下载目标，先清掉。
      # 普通文件（可续传的 .part）不受影响。
      Remove-BlockingPath $cacheFile
      Remove-BlockingPath $download
      # 上次下载校验通过的完整包直接复用，不再联网。缓存在 TEMP 里可能被损坏或替换，
      # 取到官方校验值时必须重新比对；不一致就删掉重下。
      if ((Test-Path -LiteralPath $cacheFile -PathType Leaf) -and (Get-Item -LiteralPath $cacheFile).Length -gt 0) {
          $cacheHash = Get-Sha256 $cacheFile
          if ($sumsExpected -and $cacheHash -ne $sumsExpected) {
              Write-Host '已缓存的汉化包与官方校验值不一致，删除后重新下载。'
              Remove-Item -LiteralPath $cacheFile -Force
          } else {
              $assetHash = $cacheHash
              # 后面按 $download 是否为空决定从 .part 还是缓存复制，复用缓存时必须清空。
              $download = $null
              Write-Host '使用已缓存的汉化包，无需下载。'
          }
      }
      if (-not $assetHash) {
          # 取文件总大小，用于提示和续传前的长度检查（HEAD 取不到时为 0，不影响下载）。
          $totalBytes = 0
          try {
              $head = Invoke-WebRequest -Uri $assetUrl -Method Head -UseBasicParsing -MaximumRedirection 5
              if ($head.Headers.ContainsKey('Content-Length')) {
                  # PS 5.1 返回字符串，PS 7 返回 string[]：取第一个元素，两者都能转换。
                  $totalBytes = [long](@($head.Headers['Content-Length'])[0])
              }
          } catch {
          }

          $partLength = [long]0
          if (Test-Path -LiteralPath $download -PathType Leaf) { $partLength = (Get-Item -LiteralPath $download).Length }
          if ($partLength -gt 0 -and -not $sumsExpected) {
              # 没有官方校验值就发现不了拼接出的坏文件，宁可从头下载。
              Write-Host '该版本没有官方校验值，不续传，重新下载。'
              Remove-Item -LiteralPath $download -Force
              $partLength = 0
          } elseif ($partLength -gt 0 -and $totalBytes -gt 0 -and $partLength -gt $totalBytes) {
              Write-Host '未完成的下载比完整文件还大，删除后重新下载。'
              Remove-Item -LiteralPath $download -Force
              $partLength = 0
          }

          if ($partLength -gt 0 -and $partLength -eq $totalBytes) {
              # 上次已下完但没来得及转为缓存：不再调用 curl，直接进入校验。
              Write-Host '发现已下载完整的文件，直接校验。'
          } else {
              if ($partLength -gt 0) {
                  Write-Host ("发现未完成的下载（{0:N0} MB），将从断点续传…" -f [Math]::Floor($partLength / 1MB))
              }
              if ($totalBytes -gt 0) {
                  $totalMB = [Math]::Ceiling($totalBytes / 1MB)
                  Write-Host ("正在下载汉化包…（共 {0} MB）" -f $totalMB)
              } else {
                  Write-Host '正在下载汉化包…'
              }
              Save-FileWithProgress -Url $assetUrl -Destination $download
          }

          $downloadLength = (Get-Item -LiteralPath $download).Length
          # 校验失败的 .part 必须删除：curl -C - 对已满或超长的文件仍返回 0 且不改动它，
          # 留着会让之后每次运行都续传到同一个坏文件，永远校验失败。
          if ($downloadLength -lt 1048576) {
              Remove-Item -LiteralPath $download -Force -ErrorAction SilentlyContinue
              throw "下载文件异常小（$downloadLength 字节），可能是错误页面。已删除，请重新运行。"
          }
          $assetHash = Get-Sha256 $download
          if ($sumsExpected -and $assetHash -ne $sumsExpected) {
              Remove-Item -LiteralPath $download -Force -ErrorAction SilentlyContinue
              throw '下载文件与官方校验值不一致，已删除，请重新运行。'
          }
          # 校验通过：转为完整缓存，供下次运行免下载复用。
          Move-Item -LiteralPath $download -Destination $cacheFile -Force
          $download = $null
      }
  }

  Assert-TermiusStopped
  if ((Get-Item -LiteralPath $exe).VersionInfo.ProductVersion -ne $productVersion) {
      throw '下载期间 Termius 版本发生变化，请稍后重试。'
  }

  $resourceDir = Split-Path -Parent $asar
  if (-not $sameAsar) {
      $sameAsar = ((Get-Sha256 $asar) -eq $assetHash)
  }
  if ($sameAsar -and $fuse.State -eq $StateDisabled) {
      Write-Host '本机 app.asar 已是该汉化包，无需改动。'
      if ($download) { Remove-Item -LiteralPath $download -Force -ErrorAction SilentlyContinue }
      Remove-StaleTermiusCache -Keep $cacheFile
      Wait-EnterIfInteractive
      exit 0
  }



Write-Host '正在替换 app.asar…'

  # 先在目标卷上准备好两份待替换文件，成功后再改名，避免出现半写状态。
  $nonce = [guid]::NewGuid().ToString('N')
  $stagedAsar = Join-Path $resourceDir "app.asar.staged-$nonce"
  $stagedExe = Join-Path $install "$ExeName.staged-$nonce"
  if (-not $sameAsar) {
      $pkgSource = if ($download) { $download } else { $cacheFile }
      [IO.File]::Copy($pkgSource, $stagedAsar, $false)
  }

  if ($fuse.State -eq $StateEnabled) {
      [IO.File]::Copy($exe, $stagedExe, $false)
      $stream = [IO.File]::Open($stagedExe, [IO.FileMode]::Open, [IO.FileAccess]::Write, [IO.FileShare]::None)
      try {
          $stream.Position = $fuse.Offset
          $stream.WriteByte($StateDisabled)
          $stream.Flush($true)
      } finally { $stream.Dispose() }

      $check = [IO.File]::ReadAllBytes($stagedExe)[$fuse.Offset]
      if ($check -ne $StateDisabled) { throw '关闭 asar 完整性熔丝未生效。' }
  }

  Assert-TermiusStopped

  # 先关熔丝，再换 app.asar：避免出现"新 asar + 旧校验"的中间态。
  if (Test-Path -LiteralPath $stagedExe -PathType Leaf) {
      [TermiusZh.NativeFile]::Replace($stagedExe, $exe)
      $stagedExe = $null
      $exeReplaced = $true
  }
  if (-not $sameAsar) {
      [TermiusZh.NativeFile]::Replace($stagedAsar, $asar)
      $stagedAsar = $null
      $asarReplaced = $true
  }

  if ((Get-Sha256 $asar) -ne $assetHash) { throw '写入后校验 app.asar 失败。' }
  if ((Get-AsarIntegrityFuse $exe).State -eq $StateEnabled) {
      throw '写入后校验熔丝失败，asar 完整性仍是开启状态。'
  }
  Write-Host "汉化完成，可以重新打开 $ProcessName。"
  Write-Warning '未保留备份，也无法自动回滚；如需还原请用官方安装包重装。修改代码签名后内置自动更新可能不可用。'
  if ($download) { Remove-Item -LiteralPath $download -Force -ErrorAction SilentlyContinue }
  Remove-StaleTermiusCache -Keep $cacheFile
  Wait-EnterIfInteractive
  exit 0
} catch {
  # 顶层抛异常会打印位置、行号和堆栈，对使用者是噪音；
  # 这里只输出一句中文错误。启动器不再代为 pause，统一在这里等待按键，
  if ([TermiusZh.ConsoleSignal]::CtrlCPressed -ne 0) {
      $partMB = 0
      if ($download -and (Test-Path -LiteralPath $download -PathType Leaf)) { $partMB = (Get-Item -LiteralPath $download).Length / 1MB }
      if ($sumsExpected) {
          Write-Host ("提示：已手动中断（Ctrl+C）。下载片段（{0:N1} MB）已保留，重新运行可续传。" -f $partMB) -ForegroundColor Yellow
      } else {
          Write-Host '提示：已手动中断（Ctrl+C）。该版本没有官方校验值，重新运行会从头下载。' -ForegroundColor Yellow
      }
  } elseif ($exeReplaced -or $asarReplaced) {
      Write-Host "错误：改动 Termius 文件后失败（exe=$exeReplaced, asar=$asarReplaced）：$($_.Exception.Message)" -ForegroundColor Red
      Write-Host '请关闭 Termius，必要时用官方安装包重装。' -ForegroundColor Red
  } else {
      Write-Host "错误：$($_.Exception.Message)" -ForegroundColor Red
  }
  Write-Host ''
  Wait-EnterIfInteractive
  exit 1
} finally {
  # 下载半成品保留：下次运行用 Range 续传，不从头再来。
  # 只有暂存文件必须清理（它们在应用目录内，残留会污染安装目录）。
  foreach ($temporary in @($stagedAsar, $stagedExe)) {
      if ($temporary -and (Test-Path -LiteralPath $temporary)) {
          Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue
      }
  }
}
