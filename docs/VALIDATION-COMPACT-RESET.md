# 紧凑界面与重置提醒验证记录

## 2026-11-11 纯 UI 精简（本地验证记录）

- 基于 `test/compact-ui-reset-alerts@2841cf789fbce30358f718a6fb7fad6fc17cd089`，只读核对远端一致，开始时工作区干净；本节记录提交前的本地检查，提交后的编译与打包以本 SHA 的自动 push CI 为准。
- 顶部同卡片仅展示真实窗口名及紧凑数值，宽度不足／辅助大字体堆叠，单窗口左右对齐；未知、无限及币种保留。无进度条或重置时间。
- 额度详情、Credits、账户信息复用三个独立且默认收起的原生 DisclosureGroup，只有一个外层背景和圆角，以系统 Divider 分隔。展开内移除旧嵌套大卡和重复标题。
- 额度详情保留准确时间与真实提醒开关，阈值使用本地化单位；大块低额按钮移除，右上 UIKit UIMenu 的每窗口、Credits 及旧规则入口保留。全局权限／排程异常仍展示在折叠区外，开启不代表已授权或已排程。
- Credits 紧凑状态仍区分未知、无可用、零与无限；余额及规则管理入口保留，完整解释移到原生说明 sheet。账户别名编辑、保存条件与错误处理、长身份换行保留。
- source-only 检查通过：工程／图标／Probe 自检，Python **31 项**；使用既有外置 python-host 兼容层处理 iOS 挂载目录的 lstat/fstat 差异，不修改测试断言。Swift tree-sitter 23 个文件语法解析通过；bash -n 与 git diff --check 通过。临时工具与日志全部位于源码树外 repair-20261111。
- 未改计算、通知调度／权限路径、OAuth、原生菜单动画、低额表单、删除确认、权限、版本及工作流。无 Xcode／xcrun／swiftc，Swift 夹具未编译执行，也未完成 iOS 编译或真机验收；需重点核对大字体、长窗口名／邮箱、多币种以及菜单到 sheet 的系统呈现。


> 历史记录：对应 40d2ccbb 及之前的实现。2026-11-11 本轮布局、授权和通知路由修订与最新真机证据见 [本轮调试追踪](DEBUG-NOTIFICATION-REFRESH.md)；本文件的细条及预计文案描述不代表修订后的实现。

## 范围与实现依据

基线：`main@18febec9607e6945d9a83a0bf44d0f7538451425`，版本仍为 **0.2.2 (8)**。继续原已落盘修改，不回退；正式 Widget 移除，独立 WidgetProbe 及其脚本／工作流未改。此记录覆盖本地检查；对应提交的完整编译和签名构建结果以测试分支的 GitHub Actions 为准，不把本地语法检查当作编译。

| 项目 | 源码依据与工作方式 | 本次处理 |
| --- | --- | --- |
| 首页 | SwiftUI List / NavigationLink / refreshable / swipeActions | 保留系统列表、导航和下拉刷新；摘要紧凑、宽度不足堆叠，删除仍二次确认 |
| 详情 | SwiftUI ScrollView / DisclosureGroup | 核心数值和 4pt 细条；三个分组独立默认收起，重要错误在外 |
| 更多菜单与动画 | NativeMenuButton → UIButton.menu / UIMenu / UIAction | 最小 UIKit 桥接，主操作点击展开；嵌套按功能与指标分组，勾选来自持久化状态；不自绘菜单和动画 |
| 表单／弹窗 | 既有 RuleEditor / AccountEditor、原生 alert / confirmationDialog / sheet | 低额表单与登录流程保留，别名原生输入、危险删除确认；新增 Credits 原生说明页 |
| 登录呈现／取消动画 | CodexOAuth / AccountEditor | 本轮未改；原取消、清理、超时安全源码检查继续执行 |
| 额度进度动画 | 既有 SwiftUI easeInOut | 保留详情进度动画，只减细；首页不增加进度条 |

以上为源码查证，不是动画时序、布局或真机运行验收。

## 构建环境诊断

首次测试提交 `406b7b7940981659cb4309a2119338fedfc1a9c2` 的自动 push 构建 `42950909459` 在进入任何步骤前被平台取消，annotation 为 `The configuration 'macos-14-arm64-us-default' is not supported`，不是代码或夹具失败。核对 actions/runner-images 官方清单后，正式构建改为受支持的 `macos-15` / 明确预装的 Xcode 16.4，并保留精确工具链版本检查；最低 iOS、Swift 5 语言模式、工程 objectVersion 56 和产品版本不变。独立 Probe 工作流按范围保持原样，此次没有触发或验证它的实际云构建环境。

## 已执行的本地检查

环境无 `swiftc` / `xcrun`。临时语法工具、日志和生成文件放源码树外的验证缓存，Python 关闭 bytecode 写入。

- `bash scripts/test.sh --source-only`：通过。
  - 工程身份、版本、单一正式 App target 和最小权限允许列表：通过。
  - AppIcon：18 个槽位／13 个不透明 PNG（20–1024px）：通过。
  - project.pbxproj 格式补丁自检：通过。
  - 独立 Probe 源码／权限守卫和 IPA 路径、边界自检：通过。
  - Python 回归共 **25 项**：构建与签名拒绝逻辑 4、登录生命周期 3、OAuth 安全 12、UI／通知源码集成 6，全部通过。
- `tree-sitter 0.24.4` + Swift grammar `0.7.1`：正式 App、Tests、WidgetProbe 共 **23 个 Swift 文件**解析通过，退出 0。此项只验证语法树，不检查 Swift 类型、actor 隔离、SDK 可用性或实际链接。
- `bash -n scripts/test.sh scripts/package.sh scripts/build_widget_probe.sh`：通过。
- `git diff --check`：通过。
- 独立 Probe 全目录、其工作流和三个相关构建／验证脚本无改动；正式 OAuth 与 AccountEditor 无改动。

构建／签名 Python 测试使用合成 bundle 和 mocked Apple 工具，验证错误版本、模拟器平台、多架构、超范围权限、资源封装入口与残留扩展的拒绝逻辑，**不是实际 codesign 或 IPA 验证**。正式打包仍执行真实严格校验，并在 IPA 解包后再次校验。

## 新增 Foundation Swift 夹具

`Tests/reset_main.swift` 已接入默认 `scripts/test.sh`，与原核心夹具分别强制编译运行。覆盖旧 JSON 缺字段／null 默认关闭、新数据往返、坏字段拒绝、独立账户和窗口、重复指标去重、更新替换、取消与删除、改名文案、换身份状态、认证失败清理、短暂网络失败保留、可靠未来时间判断、不猜周期、不重复到期、容量与稳定优先级、低额规则／latch 独立。身份清空与异步 generation worker 的实际接入另有源码守卫；纯逻辑夹具不是 UNUserNotificationCenter 运行测试。

## 仍须设备验收

- iOS 16.3+ iPhone / iPad 深浅色、最大动态字体、长别名和邮箱、多币种与额外窗口。
- UIKit 菜单展开／返回／关闭、实时勾选、权限弹窗、低额表单、Credits sheet 及删除确认无呈现冲突。
- 真实账户 OAuth / Key 查询、通知实际显示、专注模式／锁屏、改名／删账户／换身份及快速切换时的系统调度。
- 系统待发请求容量、异步 add 失败、系统权限撤回、冷启动对账及 TrollStore 升级安装。

系统移除／添加通知不是原子事务，编辑瞬间已经开始投递的通知不能保证撤回。超出容量的窗口需下次对账，不承诺 App 被杀后的自动补位；通知只提示“预计重置时间已到”，不确认额度已恢复。
