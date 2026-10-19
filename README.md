# Perky — MacBook 合盖后继续运行任务

Perky 是一款原生 macOS 菜单栏工具，帮助 MacBook 在合盖后继续运行下载、构建和远程任务。它提供限时会话与授权恢复机制；具体合盖方式取决于是否连接外接显示器、Mac 机型和 macOS 版本。Perky 面向 macOS 14 及以上版本。

## MacBook 合盖运行方式

### 外接显示器桌面模式：Apple 支持的使用方式

Apple 支持将 MacBook 连接外接显示器后合盖使用。需按具体机型连接兼容显示器及所需的键盘、鼠标或触控板，并遵循设备对供电和配件连接的要求。该桌面模式由 macOS 支持；Perky 仍会检查供电和外接显示器等运行条件。

### 无外接显示器：实验性 IOKit 合盖覆盖

没有外接显示器时，Perky 提供实验性的合盖覆盖路径。macOS SDK 中存在相关 IOKit selector，但 Apple 没有承诺第三方 App 可依赖此接口或在所有机型上使用。实际效果可能随 Mac 机型、硬件和 macOS 版本变化；Perky 不保证所有 MacBook 都能在无外接显示器时合盖运行。

如果 IOKit 路径不可用，现有回退方案会通过 `pmset -a disablesleep` 设置全局系统级防睡眠状态。这会影响整台 Mac 的睡眠行为，不是仅针对 Perky 或某个会话的开关。Perky 会记录启用前的值，并在会话结束时恢复；如果不能确认恢复状态，应用会保留恢复记录并提示检查。系统中其他程序或管理员也可能改动该设置，因此恢复状态异常时应按应用提示处理。

## 其他功能与兼容性

- 合盖会话为限时操作，最长 24 小时；可提前停止。电池保护及恢复期限由应用和 helper 管理。
- 开盖基础模式可选择 1–1440 分钟，通过 macOS 电源断言阻止空闲系统睡眠。它不等同于合盖运行，不会阻止用户主动睡眠、关机或重启，也不会强制保持显示器点亮。
- 内建屏幕亮度辅助仅在 macOS 26.x 验证，通过非公开的 DisplayServices 接口工作；只控制内建屏幕，系统更新可能影响可用性。
- 当前构建面向 Mac 和 macOS，不支持 Windows、Linux 或运行 Windows 的 RedmiBook、Redmi / Xiaomi（小米）笔记本、华为 MateBook、ThinkPad 等 PC 笔记本系列。
- 本机安装包通过管理员认证安装 root-owned 恢复 helper，不使用 Apple Developer ID 或公证。首次从网络下载后，macOS 可能要求你在“隐私与安全性”中手动允许打开；此包面向本机自用，不提供发布者身份验证。

## 构建

需要 macOS 14 或更新版本以及 Swift 5.10 工具链。运行：

```sh
./build-app.sh
```

脚本会先运行 `PerkyFeatureChecks`，再编译、签名并校验完整应用包。检查覆盖时长边界、合盖兼容条件、电池保护、登录项授权路由、亮度范围、只读硬件探测和防睡眠断言的创建/更新/恢复/释放。需要单独确认系统设置跳转时运行 `swift run --configuration release PerkyFeatureChecks --system-smoke`；这会打开“登录项与扩展”。

应用会生成在 `.build/Perky.app`。打包使用 `-Osize`，并只对发行副本执行 `strip -x`，保留 Swift 运行所需符号并去除本地符号表。创建本机安装包：

```sh
./package-local-installer.sh
open .build/packages/Perky-0.1.2-macos-arm64-local.pkg
```

菜单栏中的「合盖运行」开关会立即按所选时长启动；停止、到期或触发安全条件时会恢复系统合盖策略。

安装时 macOS 会请求管理员认证，并安装 system LaunchDaemon；这不同于登录项批准。若 Gatekeeper 阻止首次打开，请到“系统设置 > 隐私与安全性”手动允许。安装包不会调用 `sudo pmset`；helper 会在停止或到期时恢复它管理的系统状态。

卸载前先在 Perky 中停止会话，并等待系统恢复状态完成。然后运行 `sudo /Applications/Perky.app/Contents/Resources/uninstall-local-package.sh`。脚本会在仍有恢复记录、升级回滚快照或 Perky 正在运行时拒绝卸载；不会删除其他共享目录中的文件。

## GitHub 构建与发行

推送到 `main` 后，GitHub Actions 会运行功能检查并生成 arm64 构建产物。推送 `v*` 标签会构建本机管理员安装包并发布 GitHub Release；流程不需要 Apple Developer ID、证书或公证密钥。GitHub 上的安装包是未公证的本机自用包，下载后可能需要手动通过 Gatekeeper。

## 品牌与兼容性声明

Perky 是独立项目，与 Apple、Xiaomi（小米）或 Redmi 没有关联、授权、赞助或合作关系。Apple、Mac、macOS、Xiaomi、小米、Redmi、红米和 RedmiBook 等名称及标识归各自权利人所有；在此仅用于说明平台范围和兼容性，不表示任何产品获得认证或支持。运行 Windows 的 RedmiBook 以及其他 Redmi / Xiaomi Windows 笔记本不是 Perky 的支持设备。

## 网站与搜索信息

仓库根目录的 [`index.html`](index.html) 是产品介绍页；标题、摘要、社交分享元信息和结构化数据围绕 MacBook 合盖运行，并列出实验性方案与设备限制。Google 会根据页面内容生成搜索摘要，结构化数据不保证触发特殊搜索展示。启用 GitHub Pages 后，站点地址为 `https://laplace-bit.github.io/perky/`。
