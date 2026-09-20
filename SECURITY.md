# Notchly 安全说明

## 报告安全问题

请不要在公开 Issue 中发布可利用的漏洞细节、日志中的个人数据、证书、私钥或访问令牌。请先通过 `lixiaolongstephan@gmail.com` 联系韩十久工作室，并提供：

- 受影响的版本和构建号；
- macOS 版本与芯片架构；
- 最小复现步骤和影响范围；
- 必要的脱敏日志或截图。

我们会在确认问题后评估修复、缓解措施和公开说明时间。Notchly 当前为 Alpha 软件，正式发布前仍需完成 Developer ID 签名、公证和未参与开发设备的安装验收。

## 不要提交的内容

- Apple Developer 证书私钥、`.p12` 文件或钥匙串导出物；
- App Store Connect API Key、`notarytool` 凭据和临时令牌；
- 日历内容、文件暂存内容、播放记录、账号信息或未脱敏系统日志。

项目的权限和数据处理边界见 [PRIVACY.md](PRIVACY.md)，发布验签流程见 [证书与发布说明](docs/证书与发布说明.md)。
