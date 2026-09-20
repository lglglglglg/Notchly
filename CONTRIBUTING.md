# 贡献规范

感谢你关注 Notchly。当前项目仍处于 Alpha 阶段，优先接受能提升可靠性、能耗、无障碍性、隐私透明度和带刘海 Mac 实机体验的改动。

## 提交问题前

- 先搜索已有 issue，避免重复报告。
- 说明 macOS 版本、Notchly 版本和构建号、使用的播放器、是否连接外接显示器，以及稳定的复现步骤。
- 不要提交日历内容、文件托盘文件、完整系统日志、隐私截图、访问令牌或证书。
- 安全问题请不要公开披露细节；在仓库配置私密安全联系渠道前，请先开一个不含漏洞细节的 issue 询问联系方式。

## 本地开发

要求：macOS 14+、最新版 Xcode，以及 Swift 6 工具链。

```sh
swift test
xcodebuild -project Notchly.xcodeproj -scheme Notchly -configuration Debug CODE_SIGNING_ALLOWED=NO build
```

界面、播放器、日历、桌面歌词和文件托盘改动还应执行 [实机回归清单](docs/实机回归清单.md) 中相关项目。

## 提交范围

- 保持提交小而单一；说明用户可见行为和验证方式。
- 不提交 `dist/`、DerivedData、archive、签名产物、证书、私钥或 `.env` 文件。
- `docs/使用截图/` 只在确认不含个人、账户、日历或文件隐私后单独提交。
- 任何新增网络请求、系统权限、第三方服务或持久化数据，都必须同步更新 `PRIVACY.md` 和 README。
- 修改 `project.yml` 后必须重新运行 XcodeGen，并提交生成的 `Notchly.xcodeproj` 变更。
- 不要把私有 MediaRemote 兼容层当作 Mac App Store 可发布方案；相关改动必须更新已知限制。
