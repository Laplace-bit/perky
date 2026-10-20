## Perky 0.1.3

本版本修复了合盖会话启动与恢复的核心问题：

- 启动时直接启用系统级防睡眠 `SleepDisabled`，不再依赖“合盖会导致睡眠”这一在开盖状态下不可靠的判断。
- 停止、到期或触发安全条件时，按启动前记录的值恢复系统睡眠设置。
- 移除了会与 `cfprefsd` 异步落盘竞争的系统电源 plist 指纹校验；改为用 `pmset` 和 IOPMrootDomain 的实际值确认，并加入重试。
- 应用面板现在会明确显示系统级防睡眠是否已确认生效。
- 合盖会话仍受 24 小时上限、电量阈值、低电量模式和热压力保护。

## 安装

适用于 macOS 14 及以上、Apple Silicon（arm64）的 Mac。安装前请先登录桌面。

1. 下载 `Perky-0.1.3-macos-arm64-local.pkg` 和 `Perky-0.1.3-macos-arm64-local.pkg.sha256`。
2. 可选校验：

   ```sh
   shasum -a 256 -c Perky-0.1.3-macos-arm64-local.pkg.sha256
   ```

3. 双击 `.pkg`，输入管理员密码。安装器会安装 Perky、root 权限的本机恢复 helper 和 system LaunchDaemon。
4. 若 macOS 提示无法验证开发者，请到“系统设置 > 隐私与安全性”选择“仍要打开”，或右键安装包选择“打开”。不要关闭 Gatekeeper。
5. 从“应用程序”或 Spotlight 打开 Perky，图标会出现在菜单栏。

本安装包未使用 Apple Developer ID，也未经过 Apple 公证，面向本机自用。

## 使用

1. 点击菜单栏 Perky 图标，选择 15 / 30 / 60 分钟或自定义时长。
2. 打开“合盖运行”开关；会话会立即开始。
3. 等面板显示“系统级防睡眠已确认生效”后再合盖。
4. 关闭开关或点击停止即可恢复系统睡眠设置；到期、电量不足、低电量模式或热压力过高时也会自动恢复。

合盖运行会临时把整台 Mac 的 `SleepDisabled` 设为 `1`。请保持电源连接并留意温度；不要同时运行其他修改睡眠设置的工具。启动前如果 `SleepDisabled` 已经是 `1`，Perky 会保留这个外部设置，停止时不会关闭它。

确认状态：

```sh
pmset -g | grep SleepDisabled
```

会话中应为 `1`，正常停止后应恢复为启动前的值。

## 注意

- 合盖后是否持续运行会受 Mac 机型、macOS 版本和连接设备影响。首次使用请按面板提示确认 `SleepDisabled` 已生效，并自行验证实际合盖行为。
- 外接显示器、键盘和鼠标可以构成 Apple 支持的桌面模式；没有外接显示器时，Perky 仍会尝试系统级防睡眠，但不保证所有机型可用。
- 如果停止后面板提示设置待恢复，请不要强制退出 Perky。helper 会继续重试，并保留恢复记录。

## 卸载

1. 在 Perky 中停止会话，等待系统设置恢复。
2. 退出 Perky。
3. 运行：

   ```sh
   sudo /Applications/Perky.app/Contents/Resources/uninstall-local-package.sh
   ```

存在恢复记录、升级回滚快照或 Perky 仍在运行时，卸载脚本会拒绝执行。

## 验证与限制

- 功能检查覆盖合盖兼容条件、`SleepDisabled` 读取一致性、电池保护、电源断言生命周期等。
- 合盖运行使用全局系统设置，会影响整台 Mac。
- 当前 GitHub 安装包仅提供 Apple Silicon（arm64）版本；Windows 设备不受支持。
- 内建屏幕亮度辅助使用非公开接口，仅在 macOS 26.x 验证，可能随系统更新失效。
