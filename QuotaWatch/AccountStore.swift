import Foundation
import Combine

@MainActor
final class AccountStore: ObservableObject {
    @Published private(set) var accounts: [Account] = []
    @Published private(set) var busy: Set<UUID> = []
    @Published private(set) var loadError: String?
    @Published var message: String?
    let oauth = CodexOAuth()
    let notifications = NotificationService()
    private var jobs: [UUID: (marker: UUID, task: Task<Void, Never>)] = [:]
    private var refreshAllRunning = false

    init() { reloadArchive() }

    func reloadArchive() {
        guard jobs.isEmpty else { return }
        do { accounts = try LocalArchive.load(); loadError = nil }
        catch { loadError = "本地数据读取失败，原文件已保留。请解锁后重试；在恢复前禁止写入。" }
    }
    func account(_ id: UUID) -> Account? { accounts.first { $0.id == id } }
    private func commit(_ list: [Account]) throws {
        guard loadError == nil else { throw QuotaError.message("数据处于只读保护状态，请先重试读取。") }
        do { try LocalArchive.save(list); accounts = list }
        catch { throw QuotaError.message("本地保存失败，未覆盖当前账户状态，请检查设备空间或解锁后重试。") }
    }
    private func isCurrent(_ id: UUID, revision: UUID) -> Bool {
        account(id)?.revision == revision && !Task.isCancelled
    }
    private func update(_ value: Account) throws {
        var list = accounts
        guard let index = list.firstIndex(where: { $0.id == value.id }) else { return }
        list[index] = value
        try commit(list)
    }
    private func cancel(_ id: UUID) {
        jobs.removeValue(forKey: id)?.task.cancel()
        busy.remove(id)
    }
    func cancelRefreshes() { for id in Array(jobs.keys) { cancel(id) } }

    func add(kind: ProviderKind, alias: String, key: String = "", replacing id: UUID? = nil) async throws {
        guard loadError == nil else { throw QuotaError.message("请先恢复本地数据读取。") }
        let name = alias.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 64 else { throw QuotaError.message("请输入 1–64 字的账户别名。") }
        let previous = id.flatMap { account($0) }
        let expectedRevision = previous?.revision
        var credential: Credential
        if kind == .codex {
            credential = try await oauth.login()
        } else {
            let cleaned = key.trimmingCharacters(in: .whitespacesAndNewlines)
            guard cleaned.count >= 8, cleaned.count <= 8192,
                  cleaned.rangeOfCharacter(from: .whitespacesAndNewlines) == nil else {
                throw QuotaError.message("请输入有效的 DeepSeek API Key，不能包含空白字符。")
            }
            credential = Credential(apiKey: cleaned)
        }
        try Task.checkCancellation()
        let snapshot = try await QuotaClient.fetch(kind: kind, credential: credential)
        try Task.checkCancellation()
        if let id, account(id)?.revision != expectedRevision {
            throw QuotaError.message("账户已发生变化，本次登录结果未保存。")
        }
        if kind == .codex {
            guard let remote = credential.accountID, !remote.isEmpty else {
                throw QuotaError.message("登录成功，但无法识别 Codex 计费账户；为避免串号，未保存。")
            }
            if accounts.contains(where: { $0.id != id && $0.kind == kind && $0.remoteID == remote }) {
                throw QuotaError.message("该 Codex 账户已存在，请在原账户中选择重新登录。")
            }
        } else if accounts.contains(where: {
            $0.id != id && $0.kind == kind && (try? KeychainVault.load($0.id).apiKey) == credential.apiKey
        }) {
            throw QuotaError.message("这把 API Key 已存在；不同 Key 仍可能共用同一余额池。")
        }
        var value = previous ?? Account(kind: kind, alias: name)
        value.alias = name
        value.remoteID = credential.accountID
        value.identity = credential.identity
        value.snapshot = snapshot
        value.error = nil
        value.requiresAuth = false
        value.nextAllowedAt = nil
        value.lastAttempt = Date()
        value.revision = UUID()
        value.latched = []
        let oldCredential = try? KeychainVault.load(value.id)
        try KeychainVault.save(credential, id: value.id)
        do {
            if previous != nil {
                cancel(value.id)
                try update(value)
            } else { try commit(accounts + [value]) }
        } catch {
            if let oldCredential { try? KeychainVault.save(oldCredential, id: value.id) }
            else { try? KeychainVault.delete(value.id) }
            throw error
        }
        await evaluateAlerts(id: value.id, revision: value.revision)
    }

    func rename(_ id: UUID, alias: String) throws {
        let name = alias.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 64, var value = account(id) else {
            throw QuotaError.message("别名需为 1–64 字。")
        }
        cancel(id)
        value.alias = name
        value.revision = UUID()
        try update(value)
    }
    func delete(_ id: UUID) throws {
        guard loadError == nil else { throw QuotaError.message("只读保护期间不能删除账户。") }
        let credential = try? KeychainVault.load(id)
        try KeychainVault.delete(id)
        do { try commit(accounts.filter { $0.id != id }) }
        catch {
            if let credential { try? KeychainVault.save(credential, id: id) }
            throw error
        }
        cancel(id)
        notifications.remove(accountID: id)
    }
    func setRule(_ id: UUID, metricID: String, enabled: Bool, threshold: Decimal) async throws {
        guard var value = account(id), let metric = value.snapshot?.metrics.first(where: { $0.id == metricID }),
              threshold >= 0, !threshold.isNaN,
              metric.unit != .percent || threshold <= 100 else { throw QuotaError.message("阈值无效。") }
        cancel(id)
        value.rules.removeAll { $0.metricID == metricID }
        if enabled { value.rules.append(AlertRule(metricID: metricID, threshold: threshold)) }
        value.latched.remove(metricID)
        value.revision = UUID()
        try update(value)
        if value.error == nil { await evaluateAlerts(id: id, revision: value.revision) }
    }

    func refresh(_ id: UUID, forced: Bool = false) async {
        guard loadError == nil, let value = account(id), jobs[id] == nil, busy.count < 2 else { return }
        let now = Date()
        guard value.nextAllowedAt.map({ $0 <= now }) ?? true else { return }
        guard !value.requiresAuth else { return }
        let interval = forced ? 30.0 : value.kind.interval
        guard value.lastAttempt.map({ now.timeIntervalSince($0) >= interval }) ?? true else { return }
        let marker = UUID()
        let task = Task { await self.performRefresh(id, revision: value.revision) }
        jobs[id] = (marker, task)
        busy.insert(id)
        await task.value
        if jobs[id]?.marker == marker { jobs[id] = nil; busy.remove(id) }
    }
    func refreshAll(forced: Bool = false) async {
        guard !refreshAllRunning else { return }
        refreshAllRunning = true
        defer { refreshAllRunning = false }
        let ids = accounts.map(\.id)
        for start in stride(from: 0, to: ids.count, by: 2) {
            if Task.isCancelled { return }
            if start + 1 < ids.count {
                async let first: Void = refresh(ids[start], forced: forced)
                async let second: Void = refresh(ids[start + 1], forced: forced)
                _ = await (first, second)
            } else { await refresh(ids[start], forced: forced) }
        }
    }
    private func performRefresh(_ id: UUID, revision: UUID) async {
        guard var value = account(id), isCurrent(id, revision: revision) else { return }
        value.lastAttempt = Date()
        do {
            try update(value)
            var credential = try KeychainVault.load(id)
            var didRefreshToken = false
            if value.kind == .codex,
               credential.expiresAt.map({ $0.timeIntervalSinceNow < 300 }) ?? false {
                let previous = credential
                credential = try await CodexOAuth.refresh(previous)
                try commitRotation(credential, previous: previous, id: id)
                guard isCurrent(id, revision: revision) else { return }
                didRefreshToken = true
            }
            let snapshot: QuotaSnapshot
            do { snapshot = try await QuotaClient.fetch(kind: value.kind, credential: credential) }
            catch let error as HTTPFailure where error.status == 401 && value.kind == .codex && !didRefreshToken {
                let previous = credential
                credential = try await CodexOAuth.refresh(previous)
                try commitRotation(credential, previous: previous, id: id)
                guard isCurrent(id, revision: revision) else { return }
                snapshot = try await QuotaClient.fetch(kind: value.kind, credential: credential)
            }
            guard isCurrent(id, revision: revision), var current = account(id) else { return }
            current.snapshot = snapshot
            current.error = nil
            current.requiresAuth = false
            current.nextAllowedAt = nil
            try update(current)
            await evaluateAlerts(id: id, revision: revision)
        } catch is CancellationError { return }
        catch let error as URLError where error.code == .cancelled { return }
        catch {
            guard isCurrent(id, revision: revision), var current = account(id) else { return }
            current.error = safeMessage(error)
            if let http = error as? HTTPFailure {
                current.requiresAuth = http.status == 401 || http.status == 403
                current.nextAllowedAt = http.retryAt ?? Date().addingTimeInterval(http.status == 404 ? 86400 : 300)
            } else {
                let authWords = current.error ?? ""
                current.requiresAuth = authWords.contains("重新登录") || authWords.contains("重新授权")
                current.nextAllowedAt = Date().addingTimeInterval(300)
            }
            do { try update(current) } catch { message = safeMessage(error) }
        }
    }
    private func commitRotation(_ refreshed: Credential, previous: Credential, id: UUID) throws {
        let current = try? KeychainVault.load(id)
        guard CredentialRotation.canCommit(refreshed, previous: previous, current: current,
                                           accountExists: account(id)?.kind == .codex) else { return }
        try KeychainVault.save(refreshed, id: id)
    }

    private func evaluateAlerts(id: UUID, revision: UUID) async {
        guard let value = account(id), isCurrent(id, revision: revision), value.error == nil,
              let snapshot = value.snapshot else { return }
        let result = AlertEvaluator.evaluate(snapshot: snapshot, rules: value.rules,
                                             latched: value.latched, interval: value.kind.interval)
        // Healthy samples may re-arm; low samples latch only after a notification was scheduled.
        var next = value
        next.latched = result.latched.subtracting(result.notify)
        do {
            try update(next)
            guard !result.notify.isEmpty, isCurrent(id, revision: revision) else { return }
            let scheduled = try await notifications.send(account: next) { self.isCurrent(id, revision: revision) }
            guard isCurrent(id, revision: revision), var current = account(id) else {
                if scheduled { notifications.remove(accountID: id) }
                return
            }
            if scheduled {
                current.latched.formUnion(result.notify)
                try update(current)
            }
        } catch { message = "额度已更新，但提醒或其去重状态未保存，请检查通知权限和存储空间。" }
    }

    func safeMessage(_ error: Error) -> String {
        if let error = error as? QuotaError { return error.localizedDescription }
        if let error = error as? HTTPFailure { return error.localizedDescription }
        if error is URLError { return "网络连接失败，请检查网络权限或代理后重试。" }
        return "操作失败，请解锁设备并稍后重试。"
    }
}
