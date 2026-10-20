# Perky — MacBook 合盖后继续运行任务

Perky 是一款原生 macOS 菜单栏工具，帮助 MacBook 在合盖后继续运行下载、构建和远程任务。它通过管理员安装的本机恢复 helper 临时启用系统级防睡眠，并在停止、到期或触发安全条件时恢复原值。Perky 面向 macOS 14 及以上版本。

## 系统要求

- macOS 14 Sonoma 或更新版本。
- GitHub Releases 中的安装包为 Apple Silicon（arm64）版本。Intel Mac 需要自行从源码构建，且未经验证。
- 安装时需要管理员账户，并先登录到 macOS 桌面。

## 从 GitHub Releases 安装

1. 打开 [GitHub Releases](https://github.com/Laplace-bit/perky/releases)，下载最新版本的 `Perky-<版本>-macos-arm64-local.pkg` 和对应的 `.pkg.sha256`。
2. 可选：校验安装包完整性。在下载目录运行：

   ```sh
   shasum -a 256 -c Perky-0.1.3-macos-arm64-local.pkg.sha256
   ```

   输出应为 `OK`。
3. 双击 `.pkg`。安装器会请求管理员认证，用于写入应用、root 权限的本机恢复 helper 和 LaunchDaemon。
4. 如果 macOS 提示无法验证开发者，请到“系统设置 > 隐私与安全性”，在安全提示旁选择“仍要打开”；也可以右键点击安装包后选择“打开”。不要关闭 Gatekeeper。
5. 安装完成后，从“应用程序”或 Spotlight 打开 Perky。它只显示在菜单栏，不显示 Dock 图标。

本安装包没有使用 Apple Developer ID，也没有经过 Apple 公证。它面向本机自用，不提供发布者身份验证。

## 使用合盖运行

1. 点击菜单栏中的 Perky 图标。
2. 选择保持时长：15、30、60 分钟或自定义时长。合盖会话最长 24 小时。
3. 打开“合盖运行”开关，会话会立即开始，不需要再点一次“开始”。
4. 等待面板显示“系统级防睡眠已确认生效”，再合上屏幕。Perky 会用 `pmset` 和系统电源状态确认设置是否真的生效。
5. 需要停止时，关闭“合盖运行”开关或点击停止按钮，并等待面板提示系统设置已恢复。到期、电量达到阈值、进入低电量模式或热压力过高时，也会自动停止并恢复。

合盖运行会临时把整台 Mac 的 `SleepDisabled` 设为 `1`，因此：

- 请保持电源连接，并留意电池和温度；不要把正在运行的 Mac 放进包里。
- 不要同时使用其他修改睡眠设置的工具，避免互相覆盖。
- 外接显示器、键盘和鼠标可以构成 Apple 支持的桌面模式；没有外接显示器时，Perky 仍会尝试系统级防睡眠，但兼容性会随机型和 macOS 版本变化。
- 如果启动前 `SleepDisabled` 已经是 `1`，Perky 会把它视为外部设置，只记录会话时间，不会在停止时关闭它。

可以在终端确认当前状态：

```sh
pmset -g | grep SleepDisabled
```

会话进行中应为 `1`，正常停止后应回到启动前的值。若停止后仍是 `1`，请回到 Perky 面板处理恢复提示，不要直接强制退出应用。

## 常见问题

### 安装后提示 helper 尚未获准运行

本机安装包不使用登录项批准流程，helper 由安装器直接装为 system LaunchDaemon。请确认安装包完整安装完成；仍失败时可重新安装，并检查：

```sh
launchctl print system/com.perky.app.lid-helper
```

### 面板显示“系统设置需要处理”

这表示 helper 无法确认系统电源设置是否仍由本次会话拥有。请按面板提示选择“恢复原设置”或“保留当前”，不要同时用其他工具修改睡眠设置。选择完成前不要强制退出 Perky。

### Gatekeeper 阻止第一次打开

到“系统设置 > 隐私与安全性”选择“仍要打开”，或右键安装包选择“打开”。这是未公证安装包的预期行为。

### 支持 Windows 笔记本吗

不支持。Perky 是 macOS 应用，不能运行在 RedmiBook、Redmi / Xiaomi（小米）笔记本、MateBook 或 ThinkPad 等 Windows 设备上。

## 卸载

1. 先在 Perky 中停止合盖会话，等待系统设置恢复完成。
2. 退出 Perky。
3. 运行安装包内置的卸载脚本：

   ```sh
   sudo /Applications/Perky.app/Contents/Resources/uninstall-local-package.sh
   ```

脚本会删除应用、helper、LaunchDaemon 和安装状态。只要还有恢复记录、升级回滚快照，或 Perky 仍在运行，脚本就会拒绝卸载。

## 开发与构建

需要 macOS 14 或更新版本以及 Swift 5.10 工具链：

```sh
./build-app.sh
```

脚本会先运行 `PerkyFeatureChecks`，再编译、签名并校验完整应用包。检查覆盖时长边界、合盖兼容条件、`SleepDisabled` 读取一致性、电池保护、登录项授权路由、亮度范围、只读硬件探测和防睡眠断言的创建/更新/恢复/释放。需要单独确认系统设置跳转时运行 `swift run --configuration release PerkyFeatureChecks --system-smoke`。

应用会生成在 `.build/Perky.app`。创建本机管理员安装包：

```sh
./package-local-installer.sh
open .build/packages/Perky-0.1.3-macos-arm64-local.pkg
```

## 实现说明

helper 使用 `pmset -a disablesleep 1` 让 macOS 在合盖后不进入睡眠，并通过 `pmset -g` 在启动、会话期间和恢复时验证 `SleepDisabled`。该设置是系统级开关，会影响整台 Mac；因此 Perky 只提供限时会话，并持久保存启用前的值。helper 每 3 秒复查一次，若设置在会话期间被其他程序关闭，Perky 不会覆盖新状态，而是保留恢复记录并要求你明确选择。

开盖基础模式可选择 1–1440 分钟，通过 macOS 电源断言阻止空闲系统睡眠。它不等同于合盖运行，不会阻止用户主动睡眠、关机或重启，也不会强制保持显示器点亮。内建屏幕亮度辅助仅在 macOS 26.x 验证，使用非公开 DisplayServices 接口，系统更新可能影响可用性。

## GitHub 构建与发行

推送到 `main` 后，GitHub Actions 会运行功能检查并生成 arm64 构建产物。推送 `v*` 标签会构建本机管理员安装包并发布 GitHub Release；流程不需要 Apple Developer ID、证书或公证密钥。

## 品牌与兼容性声明

Perky 是独立项目，与 Apple、Xiaomi（小米）或 Redmi 没有关联、授权、赞助或合作关系。Apple、Mac、macOS、Xiaomi、小米、Redmi、红米和 RedmiBook 等名称及标识归各自权利人所有；在此仅用于说明平台范围和兼容性，不表示任何产品获得认证或支持。运行 Windows 的 RedmiBook 以及其他 Redmi / Xiaomi Windows 笔记本不是 Perky 的支持设备。

## 网站与搜索信息

仓库根目录的 [`index.html`](index.html) 是产品介绍页；标题、摘要、社交分享元信息和结构化数据围绕 MacBook 合盖运行，并列出合盖机制与设备限制。启用 GitHub Pages 后，站点地址为 `https://laplace-bit.github.io/perky/`。
