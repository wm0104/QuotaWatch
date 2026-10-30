# QuotaWatch

原生 iOS 多账户额度监控，面向 **iOS 16.3+ / TrollStore**。独立实现，无第三方运行时依赖。

> **0.1.0 是首个测试版。** 编译、固定样例测试与实际账号验证是三件事：本仓库的自动测试不登录任何真实账户。Codex 登录、余额读取、通知与 TrollStore 安装需要在自己的设备上验收。

## 功能

- Codex：浏览器 OAuth / PKCE 独立登录，按账户隔离钥匙串及刷新令牌，通过客户端用量接口读取各额度窗口、剩余比例及重置时间。
- DeepSeek：API Key 查询官方 API 余额，按 CNY / USD 分别展示总额、赠金、充值余额。
- 多账户：新增、重登／更换 Key、改别名、删除；重复 Codex 账户不重复入库，不合并不同账户、窗口或币种。
- 提醒：每个账户、窗口／币种自定义低额阈值，成功查询后本地通知，持续低额不反复提醒。
- 前台到期自动刷新、下拉手动刷新、限流退避及过期状态；后台只申请系统刷新机会。

## 必须了解的限制

1. **Codex 用量接口未公开，不是官方保证的第三方集成。** 当前参考公开客户端使用的 OAuth 流程和 `https://chatgpt.com/backend-api/wham/usage`；账户、套餐、客户端版本、地区及服务策略变化均可能使其失效。OAuth 使用 Codex CLI 的公开客户端标识，不能据此推定第三方集成已获官方许可，请自行确认适用服务条款。
2. **不能保证后台准点告警。** iOS 决定 BGAppRefreshTask 何时、是否执行。TrollStore 永久安装不等于 App 常驻；本项目不注入系统进程、不使用假音频保活、不安装越狱守护进程。可靠的检查时机是 App 处于前台并成功联网时。
3. 显示的剩余百分比是用量窗口比例，不是固定消息数、token 数或承诺可调用次数。重置时间到达只代表需要重新查询，不自动填为 100%。
4. 同一 DeepSeek 账户的不同 Key 可能共用余额。App 不根据相似金额猜测账户，也不重复求和。

## 使用

1. 从本仓库的 Actions 构建产物或 Releases 下载 IPA，交给 TrollStore 安装。无需 Apple 开发者证书；普通非 TrollStore 侧载不在当前测试范围。
2. 添加账户并填写别名。Codex 在 OpenAI 网页自行登录；如网页仍使用旧账号，请先切换账号并核对身份。DeepSeek 输入自己的开放平台 API Key。
3. 验证成功后进入账户详情，对需要监控的窗口／币种设置阈值，并允许系统通知。设置页面可以发送测试通知。
4. 手动刷新有 30 秒防抖，服务器 Retry-After 优先。认证失效／403 后需主动重登或检查权限，不会不断自动重试。
5. 删除只清理本机账户、凭据和通知，不代表远端注销或撤销 OAuth 授权。

## 隐私与安全

- API Key 和 OAuth 凭据仅存 App 自己的 Keychain，不读取 Minis／浏览器／CLI 已有凭据。
- 没有开发者运营的服务器，不上传账户给开发者，不嵌入分析或广告 SDK。
- 仅向对应服务发起认证和只读余额／额度请求，不调用聊天模型来估算用量。
- 非敏感账户缓存有版本号、文件保护、原子写入并排除云备份；发现读取错误即进入只读保护，不自动覆盖损坏文件。
- 日志、错误和本地通知不包含 Key、授权码、原始令牌或完整服务端响应；锁屏提醒默认不展示具体余额。
- 越狱环境本身可能减弱系统隔离，本应用无法防御拥有系统权限的恶意插件。

## 构建与测试

GitHub Actions 运行于 macOS / Xcode，先运行 Foundation 核心样例测试，再编译 iOS arm64、使用系统 codesign 进行无需证书的 ad-hoc 签名并严格校验，ldid 仅用于读取签名权限。构建日志公开，不要向代码、Issue 或 Actions 输入真实密钥。

```sh
# macOS，Apple Swift 工具链
swiftc QuotaWatch/Models.swift QuotaWatch/QuotaParser.swift Tests/main.swift -o /tmp/quotawatch-tests
/tmp/quotawatch-tests
# iOS 工程由 XcodeGen 的 project.yml 生成，完整步骤见工作流。
```

版本源为 project.yml / Info.plist，当前 **0.1.1 (2)**。本次针对 Codex 登录页弹出即退出的问题，移除添加账户页在被 Safari 覆盖时误取消登录的生命周期逻辑；保留用户取消、超时及安全校验。新增源码级回归检查，真机是否解决仍需复测。Actions 产物包含 IPA 与 SHA-256。不上传凭据、不把测试夹具当成真实账号联网验证。

## 架构

`SwiftUI → AccountStore → QuotaClient / CodexOAuth → 平台接口`

`AccountStore → LocalArchive / KeychainVault / AlertEvaluator / NotificationService`

详见 [架构与验收](docs/ARCHITECTURE.md)、[模块接口](CONTRACT.md) 和 [参考来源](THIRD_PARTY_NOTICES.md)。

## License

本项目原创代码采用 MIT 许可证。标准 OAuth 流程和接口格式参考公开资料，不包含从 OpenMinis 复制的代码；参考项目的 GPL 许可不应被忽略或用本项目许可证替代。
