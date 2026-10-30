import Foundation
import Security

// Credentials never enter the account archive, logs or notifications.
enum KeychainVault {
    private static let service = "com.wm0104.quotawatch"
    private static let accessGroup = "com.wm0104.quotawatch"
    private static func query(_ id: UUID) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: id.uuidString,
         kSecAttrAccessGroup as String: accessGroup]
    }
    static func load(_ id: UUID) throws -> Credential {
        var q = query(id)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else {
            throw QuotaError.message(status == errSecInteractionNotAllowed
                ? "钥匙串暂不可用，请先解锁设备。" : "未找到该账户的凭据，请重新登录或更换密钥。")
        }
        return try JSONDecoder().decode(Credential.self, from: data)
    }
    static func save(_ value: Credential, id: UUID) throws {
        let data = try JSONEncoder().encode(value)
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        let status = SecItemUpdate(query(id) as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var item = query(id)
            attributes.forEach { item[$0.key] = $0.value }
            guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else {
                throw QuotaError.message("无法安全保存凭据；账户未添加。")
            }
        } else if status != errSecSuccess {
            throw QuotaError.message("钥匙串写入失败，请解锁设备后重试。")
        }
    }
    static func delete(_ id: UUID) throws {
        let status = SecItemDelete(query(id) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw QuotaError.message("凭据删除失败，请解锁设备后重试。")
        }
    }
}

enum LocalArchive {
    struct Envelope: Codable {
        var schemaVersion = 1
        var accounts: [Account]
    }
    private static func directory() throws -> URL {
        let fm = FileManager.default
        var url = try fm.url(for: .applicationSupportDirectory, in: .userDomainMask,
                             appropriateFor: nil, create: true).appendingPathComponent("QuotaWatch", isDirectory: true)
        try fm.createDirectory(at: url, withIntermediateDirectories: true,
                               attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try url.setResourceValues(values)
        return url
    }
    static func load() throws -> [Account] {
        let url = try directory().appendingPathComponent("accounts.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let archive = try JSONDecoder().decode(Envelope.self, from: Data(contentsOf: url))
        guard archive.schemaVersion == 1 else {
            throw QuotaError.message("数据版本不兼容，请勿覆盖原文件。")
        }
        guard Set(archive.accounts.map(\.id)).count == archive.accounts.count else {
            throw QuotaError.message("账户数据损坏，原文件已保留。")
        }
        return archive.accounts
    }
    static func save(_ accounts: [Account]) throws {
        let url = try directory().appendingPathComponent("accounts.json")
        let data = try JSONEncoder().encode(Envelope(accounts: accounts))
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}
