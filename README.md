# Perky — macOS 定时防睡眠工具

Perky 是一款原生 macOS 菜单栏工具，适合下载、构建、演示和远程连接等长时间任务。你可以设定时长，阻止 Mac 因空闲而自动睡眠；显示器仍遵循 macOS 的显示设置。

Perky 面向 **macOS 14 及以上版本**。基础保持唤醒、可选合盖运行和内建屏幕亮度辅助是不同功能；合盖行为依赖系统授权与设备环境，亮度辅助目前只在 macOS 26.x 验证。请先阅读下面的兼容性说明。

## 功能与限制

- 基础模式可选择 1–1440 分钟，使用 macOS 电源断言阻止空闲系统睡眠；不会阻止用户主动睡眠、关机或重启，也不会强制保持显示器点亮。
- 合盖运行是单独的可选模式，需要安装并获准运行限时恢复 helper。实际效果因 Mac 机型、macOS 版本、供电和外接设备而异；Perky 不保证所有 Mac 合盖后都能继续运行。电池供电时会执行电量保护。
- 内建屏幕亮度辅助仅在 macOS 26.x 暴露，并通过非公开的 DisplayServices 接口工作；它只控制内建屏幕，系统更新可能影响可用性。
- 当前构建面向 Mac 和 macOS，不支持 Windows、Linux 或 RedmiBook、小米笔记本、华为 MateBook、ThinkPad 等 PC 笔记本系列。
- 合盖恢复 helper 需要 Apple 信任的签名。未签名的本地构建仍可使用基础模式，但无法获准安装 helper。

## 构建

需要 macOS 14 或更新版本以及 Swift 5.10 工具链。运行：

```sh
./build-app.sh
```

脚本会先运行 `PerkyFeatureChecks`，再编译、签名并校验完整应用包。检查覆盖时长边界、合盖兼容条件、电池保护、登录项授权路由、亮度范围、只读硬件探测和防睡眠断言的创建/更新/恢复/释放。需要单独确认系统设置跳转时运行 `swift run --configuration release PerkyFeatureChecks --system-smoke`；这会打开“登录项与扩展”。

应用会生成在 `.build/Perky.app`。打包使用 `-Osize`，并只对发行副本执行 `strip -x`，保留 Swift 运行所需符号并去除本地符号表；当前 macOS arm64 包约 568 KB。本地 ad-hoc 签名可用于基础模式；合盖恢复 helper 需要有效的 Apple Development 或 Developer ID 签名身份。

## GitHub 构建与发行

推送到 `main` 后，GitHub Actions 会运行功能检查并生成 arm64 DMG、ZIP 和 SHA-256 文件作为构建产物。正式发行由 `v*` 标签触发，流程会签名、公证并发布 GitHub Release；没有签名、公证凭据时会在发布前失败，不会把 ad-hoc 包标成正式版本。仓库管理员需要在 Actions secrets 中配置 `PERKY_CODESIGN_IDENTITY`、`APPLE_DEVELOPER_ID_CERTIFICATE_P12_BASE64`、`APPLE_DEVELOPER_ID_CERTIFICATE_PASSWORD`、`APPLE_NOTARY_KEY_P8_BASE64`、`APPLE_NOTARY_KEY_ID` 和 `APPLE_NOTARY_ISSUER_ID`。证书须是 Developer ID Application，公证密钥须来自 Apple Developer 团队。

## 品牌与兼容性声明

Perky 是独立项目，与 Apple、Xiaomi（小米）或 Redmi 没有关联、授权、赞助或合作关系。Apple、Mac、macOS、Xiaomi、小米、Redmi、红米和 RedmiBook 等名称及标识归各自权利人所有；在此仅用于说明平台范围和兼容性，不表示任何产品获得认证或支持。RedmiBook 等 Windows 笔记本不是 Perky 的支持设备。

## 网站与搜索信息

仓库根目录的 [`index.html`](index.html) 是产品介绍页，包含可读的兼容性说明和常见问题；网页标题、摘要、社交分享元信息、站点结构化数据、`robots.txt` 与 `sitemap.xml` 已就绪。Google 会根据页面内容生成搜索摘要，结构化数据也不保证触发特殊搜索展示。启用 GitHub Pages 后，站点地址为 `https://laplace-bit.github.io/perky/`。

