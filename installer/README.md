# Termius 一键汉化脚本 · 使用说明

本目录的四个脚本用于给 Termius 装上中文界面。**不需要懂编程，也不需要装任何东西**，系统自带的环境就够用。

- 下载时会自动挑与本机 Termius 版本号对应的汉化包
- 不会动你的账号、服务器配置和密钥
- 不保留备份，也不能自动撤销（详见「想恢复原样怎么办」）

---

## 一、我该点哪个文件

按你的电脑系统选一个：

| 你的系统 | 用这个文件 | 怎么运行 |
|---|---|---|
| **Windows** | `Update-TermiusZh-windows-launcher.cmd` | 双击 |
| **macOS** | `Update-TermiusZh-macOS.command` | 双击 |
| **Linux** | `Update-TermiusZh-linux.sh` | 见下方说明 |

`Update-TermiusZh-windows.ps1` 是 Windows 那个 `.cmd` 背后真正干活的文件，**不用管它，也别单独双击**。

### 关于 macOS 第一次打不开

macOS 默认会拦截非商店来源的脚本，第一次双击可能提示「无法打开，因为无法验证开发者」。

解决办法：在文件上**点右键 → 打开**，然后在弹窗里再点一次「打开」。之后就可以正常双击了。

### 关于 Linux

Linux 一般不用双击，打开终端执行（把路径换成你实际存放的位置）：

```bash
bash Update-TermiusZh-linux.sh
```

想先看看会发生什么、不实际改动，加 `--check`：

```bash
bash Update-TermiusZh-linux.sh --check
```

---

## 二、运行后会看到什么

脚本会先检查，再下载，最后替换。正常流程的输出大致如下：

```
安装目录 : C:\Users\你的用户名\AppData\Local\Programs\Termius
本机版本 : 10.2.1
汉化包   : https://github.com/.../v10.2.1/app-windows-localize.asar
完整性熔丝: 已关闭
汉化包状态: 可用
```

各行的意思：

| 行 | 含义 |
|---|---|
| 安装目录 | 找到了 Termius 装在哪里 |
| 本机版本 | 读到的 Termius 版本号 |
| 汉化包 | 准备下载的那个包 |
| 完整性熔丝 | 决定汉化包能否被 Termius 接受，显示「已关闭」是正常的 |
| 汉化包状态 | `可用` 表示这个版本有现成的汉化包 |

检查通过后会开始下载，能看到 curl 的进度条：

```
正在下载汉化包…（共 151 MB）
####################                    45.0%
```

下载完还要再等十几秒（关闭校验、替换文件）。最后出现：

```
汉化完成，可以重新打开 Termius。
```

看到这一行就成功了，重新打开 Termius 即可。

---

## 三、运行前必须做的事

**先完全退出 Termius。**

脚本会检查，如果 Termius 还开着就直接停下并提示：

```
错误：请先完全退出 Termius 再运行。
```

退出方式：
- Windows：关掉所有 Termius 窗口，并确认**右下角托盘**里也没有图标（有的话右键 → 退出）
- macOS：按 `⌘Q` 彻底退出，或右键 Dock 图标 → 退出
- Linux：关闭所有窗口

---

## 四、我需要选不同的汉化包吗

默认用的是「仅汉化」包，**大多数情况选它就对了**。

官方一共提供三种包，区别如下：

| 包类型 | 适合谁 | 做了什么 |
|---|---|---|
| **仅汉化**（默认） | 所有人 | 只把界面翻成中文，其它功能完全不变 |
| **汉化 + 试用** | 想把「Upgrade now」这类按钮去掉的人 | 除汉化外，隐藏升级提示按钮 |
| **汉化 + 跳过登录** | 完全离线使用、不想登录账号的人 | 除汉化外，跳过登录步骤 |

### Windows 怎么选

在放脚本的文件夹空白处，**按住 `Shift` 点右键** → 选择「在此处打开 PowerShell 窗口」（Windows 11 需先点「显示更多选项」）。然后在弹出的窗口里输入下面某一行，回车：

```batch
.\Update-TermiusZh-windows-launcher.cmd -trial
.\Update-TermiusZh-windows-launcher.cmd -skip
.\Update-TermiusZh-windows-launcher.cmd -check
```

依次对应：汉化 + 试用、汉化 + 跳过登录、只看检查结果。

### macOS / Linux 怎么选

在终端里加参数：

```bash
bash Update-TermiusZh-macOS.command --trial     # 汉化 + 试用
bash Update-TermiusZh-macOS.command --skip      # 汉化 + 跳过登录
bash Update-TermiusZh-macOS.command --check     # 只看检查结果，不改动任何东西
```

### 用配置文件改（不用敲命令，推荐新手）

配置文件不随脚本发布，需要先从模板复制一份（只需做一次）：

```bash
cp TermiusZh.conf.example TermiusZh.conf      # macOS / Linux
copy TermiusZh.conf.example TermiusZh.conf    # Windows（cmd）
```

之后直接改 **`TermiusZh.conf`** 这个文件即可，用记事本打开就行。它被 git 忽略，拉取更新时你的配置不会被重置。

找到 `package` 那一行，可以用「简写」或「完整文件名」两种方式填写：

```ini
package = ls                          # 简写：l=仅汉化，t=试用，s=跳过登录，可自由组合
package = app-windows-localize-trial.asar   # 完整文件名：原样使用
```

**简写（推荐）**：用 `l` / `t` / `s` 表示功能，脚本会自动按你的平台和 Beta 拼出完整文件名。例如 `ls` 会拼成 `localize-skip`，`ts` 拼成 `trial-skip`。组合包是否存在取决于上游，没有时脚本会如实报错。

**完整文件名**：直接写 `.asar` 结尾的全名，脚本原样使用，适合上游以后出现的新组合包或老版本命名（例如 `app-windows.asar`）。

保存后重新双击脚本即可生效。**留空就是默认的仅汉化包。**

如果你装的是 **Termius Beta**（程序名里带 Beta），还要把 `beta` 改成 `yes`：

```
beta = yes
```

留空就是正式版。改对后，脚本会自动去 Beta 的发布里找对应包，正式版与 Beta 版的包不能混用。

**用完整文件名时，开头平台名必须与系统一致**：Windows 填 `app-windows…`，macOS 填 `app-macos…`，Linux 填 `app-linux…`。填错平台会被脚本拒绝——把别的平台的包装进去会让 Termius 打不开。简写则无需关心平台名，脚本会自动选对。

配置文件里的注释把所有可选项都列出来了，照着填即可。
> 注意：命令行参数（`-trial` / `--skip`）与配置文件**同时存在时，以命令行参数为准**，`package` / `beta` / `install_dir` 三项均是如此。

### 重复运行不会重复下载

脚本每次运行都会先取官方校验值（优先 `SHA256SUMS-<平台>.txt`，旧发布没有该文件时自动改从 GitHub 发布页解析），与本机已装的 `app.asar` 比对：
一致就直接跳过下载，只有版本或包类型变化时才会重新下载约 160 MB 的完整包。

下载完成后还会核对下载内容的完整性，不一致直接报错退出。

下载中断或网络失败时会保留已下载的部分；重新运行从断点续传。校验成功的完整包会缓存，下次运行免下载复用。不同版本/包使用不同缓存，不会互相拼接。

> 注意：若发布既没有 `SHA256SUMS-<平台>.txt`、发布页也解析不到校验值，脚本会退回「下载后直接比对安装」的行为，不影响使用。

---

## 五、想装别的版本怎么办

脚本**默认只装与本机 Termius 版本号完全一致**的汉化包。这是故意的：版本对不上的包会导致应用异常甚至打不开。

如果确实需要指定版本（比如自动识别失败），可以手动传入：

```batch
:: Windows（-Apply 表示真正写入；不加只会检查）
powershell -ExecutionPolicy Bypass -File .\Update-TermiusZh-windows.ps1 -TargetVersion 9.43.1 -Apply
```

```bash
# macOS
bash Update-TermiusZh-macOS.command --version 9.43.1

# Linux
bash Update-TermiusZh-linux.sh --version 9.43.1
```

版本号写成 `主.次.修订` 三段（例如 `10.2.1`）。**该版本若没有发布对应汉化包，脚本会直接报错，不会退而求其次用别的版本**。

---

## 六、常见问题

### 提示「该版本暂无对应汉化包」

说明这个 Termius 版本的上游汉化包还没发布。等维护者更新，或联系发布者。**不要**拿相邻版本的包凑合，会导致应用异常。

### 提示「下载失败」

- 检查网络能否访问 GitHub（可能需要代理）
- 稍后重试

### 提示「未找到 Termius」

脚本按常见位置查找，找不到时说明 Termius 装在别处。此时手动指定路径：

```batch
:: Windows
powershell -ExecutionPolicy Bypass -File .\Update-TermiusZh-windows.ps1 -InstallDir "D:\你的路径\Termius" -Apply
```

```bash
# macOS
bash Update-TermiusZh-macOS.command --app /你的路径/Termius.app

# Linux
bash Update-TermiusZh-linux.sh --dir /你的路径/Termius
```

### 提示「缺少必需命令」

Linux 下才会出现，说明系统缺 `curl` 一类的基础工具。按提示安装对应命令即可（通常发行版默认都有）。

### 关闭窗口时提示「汉化未完成」

留意这一行：

- **应用文件未被修改** —— 没造成任何影响，处理掉报错原因后重跑即可
- **Termius 文件已被改动** —— 情况较严重，此时 Termius 可能打不开，请用官方安装包重新安装

### 汉化后内置自动更新失败

正常现象。脚本改动了应用文件，签名随之失效。以后要升级 Termius，请到官网重新下载安装，装完再跑一次本脚本。

---

## 七、想恢复原样怎么办

脚本**不保留备份，也无法自动撤销**。

恢复方法：到 [Termius 官网](https://termius.com) 下载官方安装包，覆盖安装一次即可。你的账号、主机、密钥等数据存在独立位置，重装不会丢失。

---

## 八、想了解脚本做了什么（可选）

它只做两件事：

1. 把 Termius 安装目录下 `resources/app.asar` 这个文件替换成汉化版
2. 关闭 Termius 主程序里的「asar 完整性校验」开关，否则 Termius 会认为文件被篡改而拒绝启动

除此之外不写注册表、不改系统设置、不上传任何数据。

如果你习惯手动操作，README 的「手动汉化」章节记录了逐步手动的方法。

---

## 附：完整参数速查

各脚本都支持加 `--help`（Windows 用 `-Help`）打印完整说明。

| 想做什么 | Windows（双击的 .cmd） | Windows（直接跑 .ps1） | macOS / Linux |
|---|---|---|---|
| 只检查不改动 | `-check` | `-CheckOnly` | `--check` |
| 仅汉化（默认） | 不加参数 | 不加参数 | 不加参数 |
| 汉化 + 试用 | `-trial` | `-Flavor trial` | `--trial` |
| 汉化 + 跳过登录 | `-skip` | `-Flavor skip` | `--skip` |
| 指定版本 | 不支持，用配置/改用 .ps1 | `-TargetVersion 9.43.1` | `--version 9.43.1` |
| 指定安装位置 | 不支持，用配置/改用 .ps1 | `-InstallDir PATH` | `--dir PATH` / `--app PATH` |
| 操作 Beta 版 | 改配置 `beta = yes` | `-Beta` 或改配置 | `--beta` 或改配置 |
| 指定汉化包 | 改配置 `package` | 同左（三端共用一份配置） | 同左 |
| 查看全部说明 | 改用 .ps1 加 `-Help` | `-Help` | `--help` |
