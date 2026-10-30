import SwiftUI
import WidgetKit

@main
struct QuotaProbeApp: App {
    var body: some Scene {
        WindowGroup { ProbeView() }
    }
}

private struct ProbeView: View {
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("probeLastVerifiedWriteRevision") private var lastWrittenRevision = 0
    @State private var snapshot: ProbeSnapshot?
    @State private var diagnostic: ProbeReadDiagnostic?
    @State private var groupStatus = "尚未检查"
    @State private var snapshotStatus = "尚未读取"
    @State private var diagnosticStatus = "尚未读取"
    @State private var operation = "尚未写入；不会自动生成共享快照。"

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("模拟 / TEST · FAKE DATA")
                        .font(.title2.bold()).foregroundColor(.orange)
                    Text("独立 QuotaProbe 0.1.0 (1)，可与 QuotaWatch 并排安装。所有账户与数字均为假数据；无网络、密钥、登录或真实余额。")
                    Text("本地读取 / 重绘 ≠ 网络更新。此测试包不验证任何真实服务。")
                        .font(.footnote)
                }
                Section("手动兼容测试") {
                    Text("1. 打开本 App，点击写入下一版假数据。\n2. 回主屏幕长按 → + → 找 QuotaProbe，添加中 / 大组件。\n3. 对比 App 的文件修订号与组件读取修订号。\n4. 再写下一版，返回主屏幕等待，再回 App 刷新诊断。")
                    Text("只请求 reloadTimelines，不保证立即重绘；系统可能延迟。2 / 4 分钟仅跨过预计重置时间，10 分钟标记过期，绝不自动恢复 100%。锁屏 / 重启后首次解锁、重新安装与持久性需真机验证。")
                        .font(.footnote)
                }
                Section("App Group · 无备用容器") {
                    Text(ProbeIdentity.group).font(.caption).textSelection(.enabled)
                    Text(groupStatus)
                    Text("文件读取：\(snapshotStatus)")
                    Text("本 App 上次写入并回读验证：r\(lastWrittenRevision)（0 = 无记录）")
                    if let snapshot = snapshot {
                        Text("共享文件当前版本：r\(snapshot.revision)").bold()
                        Text("写入：\(stamp(snapshot.writtenAt))")
                        Text("过期：\(stamp(snapshot.staleAt))")
                        ForEach(snapshot.accounts) { account in
                            VStack(alignment: .leading, spacing: 3) {
                                Text(account.id).font(.caption.bold())
                                if let percent = account.remainingPercent {
                                    Text("模拟剩余 \(percent, specifier: "%.0f")%（不会自动重置）")
                                }
                                if let usd = account.balanceUSD {
                                    Text("模拟余额 USD \(usd, specifier: "%.2f")")
                                }
                                if let reset = account.expectedResetAt {
                                    Text("预计重置：\(stamp(reset))；不是余额更新")
                                        .font(.caption)
                                }
                            }
                        }
                    }
                }
                Section("Widget 最近一次 provider 读取 · 不是绘制回执") {
                    Text(diagnosticStatus)
                    if let diagnostic = diagnostic {
                        Text("读取修订号：\(diagnostic.revision.map { "r\($0)" } ?? "无")")
                        Text("读取时间：\(stamp(diagnostic.readAt))")
                        Text("读取结果：\(diagnostic.result)")
                    }
                    Text("诊断是独立 JSON；保留旧诊断用于比对。读取成功不能证明系统已显示该版。容器不可用时 Widget 无法留下诊断。")
                        .font(.caption)
                }
                Section("仅操作测试文件") {
                    Button("写入下一版假数据 + 请求组件重载", action: writeNext)
                    Button("移除唯一测试快照 + 请求组件重载", role: .destructive, action: removeSnapshot)
                    Button("刷新 App 本地读取 / 诊断", action: refresh)
                    Text(operation).font(.footnote).textSelection(.enabled)
                    Text("删除不清除诊断或任何真实 App 数据；组件旧缓存可能继续显示，等待系统重载。")
                        .font(.caption)
                }
            }
            .navigationTitle("QuotaProbe · FAKE")
            .onAppear(perform: refresh)
            .onChange(of: scenePhase) { phase in if phase == .active { refresh() } }
            .onOpenURL { _ in refresh() }
        }
    }

    private func stamp(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .standard)
    }

    private func refresh() {
        snapshot = nil
        diagnostic = nil
        do {
            let store = try ProbeStore.appGroup()
            groupStatus = "已解析专用共享容器；具体访问结果如下。"
            do {
                snapshot = try store.readSnapshot()
                snapshotStatus = snapshot == nil ? "无测试快照" : "校验通过 / FAKE"
            } catch { snapshotStatus = "错误（损坏 / 锁定 / 不可读）：\(error.localizedDescription)" }
            do {
                diagnostic = try store.readDiagnostic()
                diagnosticStatus = diagnostic == nil ? "尚无 Widget 读取记录" : "诊断校验通过"
            } catch { diagnosticStatus = "诊断不可读：\(error.localizedDescription)" }
        } catch {
            groupStatus = error.localizedDescription
            snapshotStatus = "无法访问"
            diagnosticStatus = "无法访问"
        }
    }

    private func writeNext() {
        do {
            let store = try ProbeStore.appGroup()
            let previous = max(try store.readSnapshot()?.revision ?? 0, lastWrittenRevision)
            guard previous < ProbeIdentity.maximumRevision else { throw ProbeError.invalid("修订号已到上限") }
            let revision = previous + 1
            try store.writeSnapshot(.fake(revision: revision, now: Date()))
            guard try store.readSnapshot()?.revision == revision else { throw ProbeError.invalid("写后回读不一致") }
            lastWrittenRevision = revision
            operation = "已原子写入并回读 r\(revision)。已请求重载，等待系统；没有网络请求。"
            WidgetCenter.shared.reloadTimelines(ofKind: ProbeIdentity.kind)
        } catch { operation = "写入失败（未声称成功）：\(error.localizedDescription)" }
        refresh()
    }

    private func removeSnapshot() {
        do {
            try ProbeStore.appGroup().removeSnapshot()
            operation = "仅移除 \(ProbeIdentity.snapshotFile)；保留诊断。已请求重载，旧缓存可能暂留。"
            WidgetCenter.shared.reloadTimelines(ofKind: ProbeIdentity.kind)
        } catch { operation = "移除失败：\(error.localizedDescription)" }
        refresh()
    }
}
