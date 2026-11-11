# 架构与验收

## 目标与边界

iOS 16.3+ 原生 SwiftUI、多 Codex 订阅账户和多 DeepSeek API Key；查看剩余数据、独立自定义低额规则和 Codex 按窗口一次性重置提醒。正式 App 不包含聊天、云同步、小组件、App Group、共享凭据、越狱注入或常驻守护进程。独立 `WidgetProbe/` 诊断工程与其构建工作流完整保留，不嵌入正式产物。版本保持 0.2.2 (8)。

## 依赖关系

```text
Overview / AccountDetail / AccountEditor / RuleEditor / Settings
      ├── NativeMenuButton → UIButton / UIMenu / UIAction（系统菜单动画）
      └── DisclosureGroup / sheet / confirmationDialog（原生内容及确认）
                         │
                    AccountStore (@MainActor)
                         ├── CodexOAuth：PKCE、浏览器、loopback、令牌续期
                         ├── QuotaClient：只读 HTTPS、拒绝重定向、状态码映射
                         ├── QuotaParser：Foundation JSON → 统一快照
                         ├── KeychainVault：按 UUID 保存凭据
                         ├── LocalArchive：版本化、受保护、原子 JSON
                         ├── AlertEvaluator → NotificationService（低额）
                         └── ResetNotificationPlanner → NotificationService（重置对账）
```

Model 不依赖 UI 和网络；解析与提醒判断可在 macOS 的 swiftc 固定样例测试中运行。Store 串行协调账户事务，单账户网络 single-flight，全部刷新最多两个账户并行。入口显式持有状态对象，不靠未注入的全局环境对象。

## 数据模型

- Account：本地 UUID、平台、别名、可核对身份／远端账户 ID、快照、提醒规则及去重状态；不包含凭据。
- Credential：API Key 或 OAuth access／refresh token、有效期及会话账户，仅进入独立 Keychain。
- QuotaSnapshot：采集时间、套餐／可用状态和指标数组。
- QuotaMetric：稳定 ID、百分比／币种／credits 单位、剩余 Decimal、可选重置时间和赠金／充值明细。
- AlertRule / latch：按指标比较剩余 <= 阈值；初次低额提醒、持续低位不重复，成功读取健康值后重新允许提醒。
- Account.resetAlerts：可选指标 ID 集合，nil／缺字段表示全关闭；兼容旧归档，不迁移凭据。各账户各窗口独立，改变验证身份时清空，同身份重登保留。
- ResetNotificationPlan：稳定的账户 UUID + 无损指标 ID 请求标识、真实未来 resetAt、别名和不承诺恢复的文案；不修改快照或低额 latch。

不同窗口、币种、账户永远不相加。未返回字段不是零，到达重置时间不是自动恢复。旧快照保留作参考，失败／过期／未知不会冒充正常状态。Keychain 和缓存删除、凭据更新、请求取消均有独立处理。

## 数据源

DeepSeek：官方 `GET https://api.deepseek.com/user/balance`，Bearer API Key；金额按币种显示，不推导已用百分比。

Codex：使用公开客户端 OAuth 配置独立授权，随后 `GET https://chatgpt.com/backend-api/wham/usage`；解析实际主／次窗口和额外限制。该路径未经正式第三方公开 API 稳定性承诺，任何真实账户验证失败应直接显示错误，不能以样例数据冒充成功。

同一 Codex 计费账户不重复添加；DeepSeek 不同 Key 可能共享余额池，没有可靠标识时不猜测合并。删除本地凭据不代表服务端撤销授权。

## 原生界面

- 首页按平台分组的 List，账户名与 Codex 各实际窗口摘要优先同排，宽度不够或大字体自动堆叠；DeepSeek 别名与金额优先同排，额外币种独立展示。短更新时间、真实错误、过期与认证提示保留，不加首页进度条，不截取固定数量指标。
- 详情核心额度仅展示文字数字，单个实际窗口占满一行、多个窗口双列，大字体回退单列，不绘制任何额度进度条；重置时间在下一行按服务端时间展示，到点仅提示等待刷新。DeepSeek 不制造百分比；轻量刷新与更新时间同行。额度详情、Credits、账户信息三个 DisclosureGroup 各自默认关闭；DeepSeek 无 Credits 组。重置时间／提醒状态／赠金充值明细保留，长邮箱允许换行，重要错误在折叠组外。
- 真实 UIKit 更多菜单：刷新、提醒设置 → 指标 → 重置开关／现有低额表单、账户管理 → 别名／重登或换 Key／危险删除、官网。删除仍二次确认。Credits 关于页为原生 sheet。OAuth、既有取消和登录呈现逻辑未修改。

## 刷新与通知

- 低额与重置入口共用 single-flight 原生授权服务：实时读取状态，仅尚未决定时请求系统允许／不允许框；已允许不重复请求，已拒绝只能去系统设置。成功授权后才允许开启；异步返回校验账户 revision 和当前窗口。诊断只含系统状态、布尔返回与受控错误代码。
- 通知点击经 AppDelegate → 内存待处理路由 → 单一 NavigationStack，冷启动也保留目标。等待登录／验证／保存事务及实际 UIKit sheet 关闭后定位该 UUID；已删除／无效目标回首页。点击自动查询，但投递之后已有成功查询时去重；并发槽位满则等待，失败保留错误与手动刷新。
- 前台循环以最近真实未来 resetAt 缩短检查等待；已到点且快照早于 resetAt 时可越过普通 5／10 分钟间隔，绝不越过 Retry-After 或认证保护。成功快照即使仍带旧 resetAt 也不再获得即时刷新资格；失败保留默认自动间隔和服务器退避，不按旧时间每 30／60 秒重查。通知本身不执行后台网络。

- 前台 Codex 5 分钟、DeepSeek 10 分钟；进入前台检查到期账户；下拉手动刷新有 30 秒防抖。
- 服务器 Retry-After 优先，网络失败退避。401 仅允许必要的一次令牌续期重试；403 不更换身份绕过访问拒绝。
- BGAppRefreshTask 仅尽力申请机会，系统不保证时点，杀进程或权限关闭后不能承诺监控。
- 一次刷新命中多个窗口合并成账户通知；锁屏默认仅别名和低额状态，不显示余额。通知授权和系统显示状态不等同于确定已送达。
- 删除或改规则会使旧请求结果失效，防止旧凭据／旧阈值回写。通知是否在真机显示须另验收。
- 重置通知仅为已开启的 Codex 百分比窗口使用有限且未来的服务端 resetAt；没有可靠时间、已经到时、不限量、认证失效时不排程。短暂网络失败不清除仍可靠的未来时间；不按时长猜测或创建重复通知。
- 冷启动、回前台、成功保存账户均发起对账；串行主 actor worker 在异步点用 generation 检查旧结果，过期 add 完成后再以最新账户补偿对账。只清理 reset- 命名空间，低额／测试通知不受影响。系统通知 API 不是原子事务，编辑瞬间已投递的通知不能保证撤回。
- 关开关／删账户／换身份清理待发及已送达归属，改名替换待发文案；改时间先取消过时请求，若新 add 失败显示错误，下次对账重试。开启时先检查系统权限，再核对 revision，持久化后才排程。
- 系统最多 64 个待发请求：重置最多占最近 48 个，并扣除其他待发通知、额外预留 8 个槽位；无容量、权限不足、排程失败均真实提示。被延后窗口需下次对账，不承诺杀 App 后自动补位。仅文案提示“额度重置时间已到”，不回填 100%。

## 自动检查层次

`bash scripts/test.sh --source-only` 实际执行工程／图标／格式／Probe 自检及 Python 源码安全检查。`bash scripts/test.sh` 还强制编译运行原核心夹具与新重置夹具（JSON 兼容、独立开关、更新取消、身份清理、去重、容量、时间有效性及低额独立性），二进制均放系统临时目录。签名测试使用合成 bundle 和 mocked Apple tools，仅证明拒绝逻辑，不证明真实签名。tree-sitter 语法解析不等于 Swift 类型检查或 SDK 编译。

## 设备验收清单

- [ ] iPhone / iPad iOS 16.3+ 编译、arm64、版本0.2.2/build8、ad-hoc签名、TrollStore 安装；正式包无扩展及 App Group。
- [ ] 深浅色、最大动态字体、长别名／长邮箱、多币种／额外窗口、原生菜单进入返回／勾选、三个独立折叠与 Credits sheet。
- [ ] 重置默认关闭、各账户各窗口开关持久化、改名／换身份／删账户／快速切换与刷新竞态、无 resetAt、时间推后或提前、网络失败保留、权限撤回、队列容量及一次性通知实际显示。
- [ ] 自有 Codex 账户网页登录、回调、取消、超时、端口占用、刷新令牌轮换和多账号身份核对。
- [ ] 自有 DeepSeek Key 查询、失效 Key、网络权限、代理和离线处理。
- [ ] 相同账户不重复添加，A失败不影响B，删除／重登后旧请求不可回写。
- [ ] 百分比、金额、缺字段、重置／过期、限流、首次低额→持续低额→回升→再低额。
- [ ] 通知授权开／关、前台／锁屏显示、应用重启后的去重、后台失去执行机会的明确提示。

复选框是**待真机验收事项**，并非声称已通过。构建和固定样例结果以 Actions 记录为准，不把 CI 成功等同真实账号可用。
