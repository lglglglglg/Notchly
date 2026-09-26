# Notchly

<p align="center">
  <img src="Notchly/Assets.xcassets/AppIcon.appiconset/AppIcon.png" alt="Notchly Logo" width="128" height="128">
</p>

<p align="center">
  <b>为刘海 Mac 打造的原生音乐灵动岛</b><br>
  在屏幕顶部查看正在播放、同步歌词与常用状态，需要时展开，用完自然收起。
</p>

<p align="center">
  <a href="https://lglglglglg.github.io/Notchly/">官方网站</a> ·
  <a href="https://github.com/lglglglglg/Notchly/releases">下载</a> ·
  <a href="https://github.com/lglglglglg/Notchly/issues">问题反馈</a>
</p>

<p align="center">
  <img src="https://img.shields.io/badge/macOS-14.0%2B-blue?logo=apple" alt="macOS 14.0+">
  <img src="https://img.shields.io/badge/Swift-6.0-orange?logo=swift" alt="Swift 6.0">
  <img src="https://img.shields.io/badge/License-MIT-green" alt="MIT License">
  <img src="https://img.shields.io/badge/Version-0.13.17-purple" alt="Version 0.13.17">
</p>

## 关于 Notchly

Notchly 是一款本地优先的 macOS 应用，把音乐信息、同步歌词和少量日常状态放在 MacBook 刘海附近。它使用 SwiftUI 与 AppKit 构建，支持多桌面和真实刘海定位，不读取屏幕内容或系统音频。

## 主要功能

- 显示歌曲、歌手、封面、播放进度，并提供上一曲、播放/暂停和下一曲控制。
- 支持 Apple Music、Spotify，以及网易云音乐、QQ 音乐、酷狗、酷我和汽水音乐的系统媒体会话。
- 从网易云音乐和 LRCLIB 匹配同步歌词，支持本地缓存与 ±3 秒校准。
- 提供单行/双行桌面歌词、KTV 渐变、主题、字号和背景透明度设置。
- 提供频谱、波形、脉冲和“宇宙尘埃”四种本地模拟动效。
- 支持专注计时、喝水与久坐提醒，以及电池和下一日程展示。
- 支持临时文件拖入、Finder 定位、保存期限、容量上限和一键清空。
- 可通过鼠标悬停、菜单栏图标或全局快捷键展开和收起。

## 下载与安装

Notchly 需要 macOS 14.0 或更高版本，当前发布版本仍处于 Alpha 阶段。

前往 [GitHub Releases](https://github.com/lglglglglg/Notchly/releases) 下载最新版本：

- **DMG（推荐）**：打开安装镜像，将 `Notchly.app` 拖入“应用程序”文件夹。
- **ZIP**：解压后，将 `Notchly.app` 移入“应用程序”文件夹。

也可以从 [Notchly 官方网站](https://lglglglglg.github.io/Notchly/) 进入下载页面。

## 快速使用

| 动作 | 操作方式 |
| --- | --- |
| 展开或收起 | 悬停刘海、点击菜单栏图标，或按 `⌘⇧Space` |
| 控制播放 | 使用上一曲、播放/暂停和下一曲按钮 |
| 返回播放器 | 点击专辑封面 |
| 校准歌词 | 使用歌词右侧校准控件，或在设置中调整时间偏移 |
| 管理文件暂存 | 将文件拖入“文件暂存”区域后打开入口 |
| 打开设置 | 展开灵动岛后点击右上角齿轮 |

## 隐私与权限

Notchly 不提供账号、广告、遥测或自建数据收集服务。设置、歌词缓存、专注状态和文件暂存均保存在本机。完整数据边界见 [隐私政策](PRIVACY.md)。

对应功能首次使用时，macOS 可能请求以下权限：

- **日历**：读取下一场非全天日程，仅在岛内展示。
- **自动化**：读取和控制已运行的 Apple Music 或 Spotify。
- **通知**：发送专注、喝水和久坐提醒。
- **网络访问**：匹配同步歌词和加载远程专辑封面。
- **文件访问**：仅处理用户主动拖入文件暂存区域的项目。

Notchly 不读取键盘输入、屏幕内容或系统音频，也不需要屏幕录制权限。

## 已知限制

- 国内播放器兼容层使用私有 `MediaRemote.framework`，当前版本不适合直接提交 Mac App Store。
- 歌词和远程封面的可用性、准确性及内容授权由相应第三方服务决定。
- 当前仍处于 Alpha 阶段，建议保留重要文件的原始副本，并通过 GitHub Issues 反馈问题。

## 开发构建

需要 macOS 14.0+、Xcode 15+、Swift 6 和 [XcodeGen](https://github.com/yonaskolb/XcodeGen)。

```bash
git clone https://github.com/lglglglglg/Notchly.git
cd Notchly
./scripts/package-stable.sh
```

构建产物位于 `dist/`，包括 `Notchly.app`、DMG 和 ZIP。签名、公证与正式发布流程见[证书与发布说明](docs/证书与发布说明.md)。

## 开源与支持

- [问题反馈](https://github.com/lglglglglg/Notchly/issues)
- [贡献指南](CONTRIBUTING.md)
- [隐私政策](PRIVACY.md)
- [安全说明](SECURITY.md)
- [更新记录](CHANGELOG.md)
- [赞助支持](docs/DONATE.md)

## 许可证与版权

Notchly 基于 [MIT License](LICENSE) 开源。

© 2026 **Stephan Li** · 韩十久工作室（Hanshijiu Studio）
