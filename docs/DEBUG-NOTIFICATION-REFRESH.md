# 通知授权、文字额度与自动刷新调试追踪（2026-11-11）

## 边界和现场

- 开始时工作树干净；当前分支 `test/compact-ui-reset-alerts`，本地／远端均为 `40d2ccbb4be7c974481fe0705d04c2d01301fc0d`；main／远端 main 为 `18febec9607e6945d9a83a0bf44d0f7538451425`。
- 本轮仅本地相关代码、文档、测试；不 commit、不 push、不触发 CI、不合 main、不改版本／Release、不下载 IPA。后续若另获提交授权，标题及正文使用中文。
- 版本、Bundle ID、签名最小权限、Info.plist、OAuth 实现、独立 WidgetProbe 和工作流保持不变。没有新增归档字段，保留旧 JSON 默认关闭语义。
- 日志、临时工具源码及缓存均在源码树外的外置 `QuotaWatch/repair-20261111/`，Python 禁止 bytecode 写入。

## UI／动画／弹窗盘点（源码查证，不等于运行验收）

| 项目 | 实现／生命周期 | 处理 |
| --- | --- | --- |
| 首页与详情导航 | SwiftUI List／NavigationStack／ScrollView | 保留原生导航；根栈统一 UUID 路径，避免通知重复推入 |
| 更多菜单 | NativeMenuButton → UIButton.menu／UIMenu／UIAction | 保留系统菜单、子菜单、勾选与关闭动画，不自绘 |
| 提醒和账户表单 | RuleEditor／AccountEditor 原生 sheet | 保留表单；通知路由先等待完整登录、验证、保存事务结束，再关闭 sheet，等待 UIKit 实际呈现／转场结束 |
| 其他弹窗 | Credits sheet、别名 alert、删除 confirmationDialog、原有错误提示 | 保留；路由时清理所属呈现状态，不伪造授权弹窗 |
| 额度展示与动画 | 原详情 adaptive 网格、自绘 Capsule 细条及 easeInOut | 移除额度条及其动画；实际单窗口整行、多窗口双列，大字体单列 |
| 通知授权 | UNUserNotificationCenter 系统 API | 仅首次尚未决定时原生请求；不加中间许可 UI，不强制重弹 |

## 定义 → 复现 → 隔离 → 假设 → 验证

1. **授权体验／错误归类。** 原重置入口先 reload 且仅 notDetermined 请求；低额入口依赖发布缓存、未授权仍能保存规则；设置页已允许时仍可点击请求，却无可见变化。假设 A：没有原生 API——源码否定，原来就使用 requestAuthorization；假设 B：TrollStore 注册／签名导致首次不弹——未复现，不能确诊；假设 C：已授权后的按钮无反应属于正常系统行为——Apple 官方文档及最新现场支持。
   - 新证据：用户反馈系统设置已看到 QuotaWatch，手动允许通知且测试成功；主助手抽帧确认设置显示“已允许”，7.9 秒录屏约第 4 秒出现真实 QuotaWatch 测试横幅。本轮执行者未直接操作用户手机。
   - 结论：当前安装可用本地通知；不能宣称注册损坏或必须私有 entitlement。之前首次未见授权框的原因仍未知，未宣称已修好该系统层根因。
2. **单窗口留白与进度条。** 假设：adaptive 网格按可用宽度产生多个列槽，而不是按实际窗口数选择。DetailMetricsCard 源码证实；旧实现确有自绘条。改成实际非 Credits 指标数量决定 1／2 列，保留额外指标、unknown、unlimited、低额、过期、错误和 Credits 独立明细。
3. **重置语义。** 源码确认已明确 resetAt 仍标“预计”。页面统一 24 小时准确日期时间；已到点显示“重置时间已到，等待刷新”。通知示例标题“5小时额度重置时间已到”，正文“别名：点击查看恢复后的最新额度”。不回填 100%，不猜周期，继续账户／窗口独立一次性排程。
4. **通知路由／到点刷新。** 源码确认代理原先仅 willPresent、没有 didReceive 路由；普通刷新只有 lastAttempt 5／10 分钟门槛，可能挡住刚到点查询。增加冷启动待处理点击、根导航任务、实际 UUID 存在校验、失效回首页及自动查询；重复 delivery 去重，投递后已成功查询则不重复联网，槽位满则等待。路由任务挂根 NavigationStack，不随首页推入详情而取消。
   - 到点资格限定 `snapshot.capturedAt < resetAt <= now`，仅无前次错误时越过普通间隔。成功查询即使还带旧 resetAt，后续回到普通间隔；不会被同一旧时间驱动每 30／60 秒重查。失败保留服务端 Retry-After 和正常自动退避；手动／点击操作继续 30 秒防抖。401／403、只读保护、revision 和单账户 single-flight 均保留。

## 最小修复与安全约束

- NotificationService 共用一个授权 Task；每次使用本次真实系统状态，generation 防旧状态覆盖。已允许直接返回；仅 notDetermined 调原生 requestAuthorization；denied 真实引导设置；系统请求错误与拒绝分开，诊断仅保留状态、布尔值、受控错误域／代码，不包含原始异常描述、账号或凭据。
- 设置页已允许显示“通知已允许”并禁用请求按钮。低额开关先授权再置开；保存与重置开启前仍验证权限；异步完成后检查账户 revision 和当前指标资格，已删除或变更不能回写。关闭提醒不请求权限。
- 通知本身不执行网络、不保证后台刷新；用户点击后自动查询，失败保留原快照、错误和手动入口。应用普通回前台也检查未观察到的到点窗口；前台等待可缩短到最近真实未来重置时刻。

## 权限依据

- Apple 官方：[请求通知权限](https://developer.apple.com/documentation/usernotifications/asking-permission-to-use-notifications)。本轮读取其官方文档 JSON，明确写明第一次请求系统提示并记录响应，后续请求不再提示；所以不能承诺在 authorized／denied 下强制重弹。
- TrollStore 官方固定源码 `88424f683b2a08f34a3f88985f790f97d84ce1df`：[RootHelper/main.m#L810-L818](https://github.com/opa334/TrollStore/blob/88424f683b2a08f34a3f88985f790f97d84ce1df/RootHelper/main.m#L810-L818) 的安装补丁明确设置 `SBAppUsesLocalNotifications = 1`；[uicache.m#L112-L125](https://github.com/opa334/TrollStore/blob/88424f683b2a08f34a3f88985f790f97d84ce1df/RootHelper/uicache.m#L112-L125) 按注册条件区分 User／System 并传递现有 entitlements。
- 以上只说明上游实现，不证明用户安装版本或实际设备注册值；未发现足以要求本 App 新增 usernotifications 私有 entitlement 的证据。本轮不增加私有权限，不写 SBAppUsesLocalNotifications，不改安装注册或 Bundle ID；最新已成功通知证据也不支持盲目改签名。

## 实际验证结果与宿主限制

- 修复前先新增 `Tests/notification_repair_checks.py`：5 个源码回归守卫全部失败，记录在外置 `before-regression.log`。这是源码级复现，不是设备授权／布局复现。
- 最终 `bash scripts/test.sh --source-only` 通过：工程身份／最小权限与无正式扩展检查、AppIcon／平台图标检查、工程格式补丁自测、独立 Probe 工程及 IPA 路径／边界自测均通过；Python 30 项通过（构建与签名拒绝逻辑 4、登录生命周期 3、新通知回归 5、OAuth 安全 12、UI／通知集成 6）。签名用合成 bundle 和 mocked Apple tools，不是实际 codesign 或 IPA 验证。
- 外置挂载的 Python TemporaryDirectory 首次清理因 lstat／fstat 身份不一致报 `Cannot call rmtree on a symbolic link`。只在外置测试宿主 sitecustomize 中选用 Python 标准路径式 rmtree 回退后重跑；未修改生产脚本、测试断言、签名白名单或 Probe 代码。所有合成目录、缓存仍留在指定外置位置。
- tree-sitter 0.24.4，Swift grammar 固定标签 `0.7.1-with-generated-files`（`277b583bbb024f20ba88b95c48bf5a6a0b4f2287`）：每个文件独立进程、按 Swift 扩展名解析，23 个 Swift 文件全部通过，退出 0。批量／强制 scope 模式曾在含既有语法的文件报错，未据此修改 Probe 或既有夹具；最终独立解析日志逐个记录。仅语法检查，不是 Swift 类型／actor／SDK 检查。
- `bash -n scripts/test.sh scripts/package.sh scripts/build_widget_probe.sh`、`git diff --check` 通过。
- `Tests/reset_main.swift` 新增／更新已接入默认强制 Swift 夹具：实际 0／1／2／多窗口与大字体选择、精确通知文案、账户 UUID 解析／无效／已删目标、投递去重键、授权后 revision 变更／删除保护、到点越过普通间隔、不越过 Retry-After／认证保护、失败退避、成功仍返旧 resetAt 不形成 30／60 秒循环、不制造 100%、准确日期时间；原旧 JSON 缺字段／null／坏字段拒绝及独立排程用例保留。
- 宿主无 swift／swiftc／xcrun／Xcode；**Swift 夹具未执行，iOS 未编译，真实签名未执行，新布局／系统授权初次弹框／重置排程及点击自动刷新未在真机验收**。已确认的旧安装测试横幅只证明当时本地通知可用，不能代替这些新路径验收。

## 待真机验收

1. 新装且状态确为 notDetermined 时，从低额开关和重置入口直接出现 iOS 系统框；允许后可开、拒绝或真实请求错误不保存开启。已允许按钮禁用，denied 不强行重弹。快速点击、切账户、删账户时不串号／不回写旧设置。
2. 单窗口整行、双窗口双列，长名称／unknown／unlimited／额外窗口／最大动态字体／横屏／深浅色；全详情无额度进度条，下一行准确重置时间。
3. 多账户不同窗口一次性通知实际投递，标题与正文正确；到点不虚构恢复百分比，未获得后台联网机会不承诺已查。
4. 前台、后台唤回及冷启动点击通知正确定位并自动查询；重复点击、无效／已删目标、设置／Credits／低额／编辑 sheet 打开时无重复呈现；登录及后续验证保存进行中先安全完成或由用户取消，随后再路由。
5. 前台和普通打开时到点即尝试查询；429 Retry-After、403、离线失败、成功却仍返回旧 resetAt 均不形成 30／60 秒自动请求循环，错误与手动刷新保留。

## 本轮工作树结论

相关 9 个正式 Swift 文件、3 个测试文件、5 个说明文档有本地修改／新增；无提交、无推送。main、版本／构建号、签名允许列表、Info.plist、OAuth 源码和独立 Probe 全部保持基线。新路径尚需获授权后的 Xcode 编译和上述设备验收；不能将静态通过报告为真机修复已验证。
