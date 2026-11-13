# CardAI iOS 采集端

iPhone 摄像头 → VideoToolbox HEVC → iroh → Windows 控制端。iOS 端只做发送，不做录制。

## 构建

```sh
xcodegen generate
open CardAICollector.xcodeproj
```

CI：`.github/workflows/ios.yml`（macOS 26，XcodeGen 2.46.0，iroh-ffi 1.2.0）。
未配置签名 secrets 时产出 unsigned `.xcarchive`；配置后额外产出 `.ipa`。

## Secrets

| Secret | 说明 |
|---|---|
| `IOS_CERTIFICATE_BASE64` | `.p12` 的 base64 |
| `IOS_CERTIFICATE_PASSWORD` | `.p12` 密码 |
| `IOS_PROVISIONING_PROFILE_BASE64` | `.mobileprovision` 的 base64 |
| `IOS_TEAM_ID` | Apple Team ID |
| `IOS_BUNDLE_ID` | 覆盖 bundle id（默认 `com.cardai.collector.ios`） |

## 配对

Windows 端 `CARDAI_CAPTURE_SOURCE=iroh` 启动后显示二维码；iOS 扫码或手填
`ticket / room / token / addr`。配对信息保存在 UserDefaults，App 重启后自动重连。`addr` 为 `<endpoint_id>@<ip:port>,...`，
跨语言绑定的 ticket 编解码不兼容时优先使用。

## 限制

- 本轮验收为 CI 构建通过，未做真机运行测试。
- 不支持慢放/回退/单帧：这些是 Windows 端复盘能力。
