# 架构与验收

## 目标与边界

iOS 16.3+ 原生 SwiftUI、多 Codex 订阅账户和多 DeepSeek API Key；查看剩余数据、独立自定义低额规则。本版本不包含聊天、云同步、小组件、越狱注入或常驻守护进程。

## 依赖关系

```text
Overview / AccountDetail / AccountEditor / RuleEditor / Settings
                         │
                    AccountStore (@MainActor)
                         ├── CodexOAuth：PKCE、浏览器、loopback、令牌续期
                         ├── QuotaClient：只读 HTTPS、拒绝重定向、状态码映射
                         ├── QuotaParser：Foundation JSON → 统一快照
                         ├── KeychainVault：按 UUID 保存凭据
                         ├── LocalArchive：版本化、受保护、原子 JSON
                         └── AlertEvaluator → NotificationService
```

Model 不依赖 UI 和网络；解析与提醒判断可在 macOS 的 swiftc 固定样例测试中运行。Store 串行协调账户事务，单账户网络 single-flight，全部刷新最多两个账户并行。入口显式持有状态对象，不靠未注入的全局环境对象。

## 数据模型

- Account：本地 UUID、平台、别名、可核对身份／远端账户 ID、快照、提醒规则及去重状态；不包含凭据。
- Credential：API Key 或 OAuth access／refresh token、有效期及会话账户，仅进入独立 Keychain。
- QuotaSnapshot：采集时间、套餐／可用状态和指标数组。
- QuotaMetric：稳定 ID、百分比／币种／credits 单位、剩余 Decimal、可选重置时间和赠金／充值明细。
- AlertRule / latch：按指标比较剩余 <= 阈值；初次低额提醒、持续低位不重复，成功读取健康值后重新允许提醒。

不同窗口、币种、账户永远不相加。未返回字段不是零，到达重置时间不是自动恢复。旧快照保留作参考，失败／过期／未知不会冒充正常状态。Keychain 和缓存删除、凭据更新、请求取消均有独立处理。

## 数据源

DeepSeek：官方 `GET https://api.deepseek.com/user/balance`，Bearer API Key；金额按币种显示，不推导已用百分比。

Codex：使用公开客户端 OAuth 配置独立授权，随后 `GET https://chatgpt.com/backend-api/wham/usage`；解析实际主／次窗口和额外限制。该路径未经正式第三方公开 API 稳定性承诺，任何真实账户验证失败应直接显示错误，不能以样例数据冒充成功。

同一 Codex 计费账户不重复添加；DeepSeek 不同 Key 可能共享余额池，没有可靠标识时不猜测合并。删除本地凭据不代表服务端撤销授权。

## 刷新与通知

- 前台 Codex 5 分钟、DeepSeek 10 分钟；进入前台检查到期账户；下拉手动刷新有 30 秒防抖。
- 服务器 Retry-After 优先，网络失败退避。401 仅允许必要的一次令牌续期重试；403 不更换身份绕过访问拒绝。
- BGAppRefreshTask 仅尽力申请机会，系统不保证时点，杀进程或权限关闭后不能承诺监控。
- 一次刷新命中多个窗口合并成账户通知；锁屏默认仅别名和低额状态，不显示余额。通知授权和系统显示状态不等同于确定已送达。
- 删除或改规则会使旧请求结果失效，防止旧凭据／旧阈值回写。通知是否在真机显示须另验收。

## 首版验收清单

- [ ] iPhone / iPad iOS 16.3+ 编译、arm64、版本0.1.0/build1、ad-hoc签名、TrollStore 安装。
- [ ] 自有 Codex 账户网页登录、回调、取消、超时、端口占用、刷新令牌轮换和多账号身份核对。
- [ ] 自有 DeepSeek Key 查询、失效 Key、网络权限、代理和离线处理。
- [ ] 相同账户不重复添加，A失败不影响B，删除／重登后旧请求不可回写。
- [ ] 百分比、金额、缺字段、重置／过期、限流、首次低额→持续低额→回升→再低额。
- [ ] 通知授权开／关、前台／锁屏显示、应用重启后的去重、后台失去执行机会的明确提示。

复选框是**待真机验收事项**，并非声称已通过。构建和固定样例结果以 Actions 记录为准，不把 CI 成功等同真实账号可用。
