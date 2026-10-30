import Foundation
#if os(iOS)
import Security
#endif

enum WidgetCredentialError: LocalizedError {
    case accountNotAllowed
    case notFound
    case invalid
    case unavailable
    case saveFailed
    case deleteFailed

    var errorDescription: String? {
        switch self {
        case .accountNotAllowed: return "该账户不在小组件允许列表内，未读写凭据。"
        case .notFound: return "未找到该小组件账户的凭据。"
        case .invalid: return "小组件凭据无效或与账户不匹配。"
        case .unavailable: return "钥匙串暂不可用，请先解锁设备。"
        case .saveFailed: return "小组件凭据保存失败，原凭据未覆盖。"
        case .deleteFailed: return "小组件凭据删除失败，请稍后重试。"
        }
    }
}

// Deliberately local and differently named from the app's Credential. It is only stored in the
// widget Keychain service; it is never encoded into WidgetSnapshot or any file.
struct WidgetCredentialRecord: Codable, Equatable {
    var provider: String
    var apiKey: String?
    var accessToken: String?
    var refreshToken: String?
    var accountID: String?
    var identity: String?
    var expiresAt: Date?

    init(provider: String, apiKey: String? = nil, accessToken: String? = nil,
         refreshToken: String? = nil, accountID: String? = nil,
         identity: String? = nil, expiresAt: Date? = nil) {
        self.provider = provider
        self.apiKey = apiKey
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.accountID = accountID
        self.identity = identity
        self.expiresAt = expiresAt
    }

    // Returns a minimized normalized copy, or nil when the credential for its provider is unusable.
    // Unrelated secret fields are removed instead of being copied into the widget service.
    func validated() -> WidgetCredentialRecord? {
        guard WidgetSnapshotLimits.allowedProviders.contains(provider) else { return nil }
        var result = self

        switch provider {
        case "codex":
            guard let access = Self.headerValue(accessToken, maximum: 32_768) else { return nil }
            let refresh: String?
            if let raw = refreshToken, !raw.isEmpty {
                guard let clean = Self.headerValue(raw, maximum: 32_768) else { return nil }
                refresh = clean
            } else {
                refresh = nil
            }
            result.apiKey = nil
            result.accessToken = access
            result.refreshToken = refresh
        case "deepseek":
            guard let key = Self.apiKey(apiKey) else { return nil }
            result.apiKey = key
            result.accessToken = nil
            result.refreshToken = nil
        default:
            return nil
        }

        if let raw = accountID, !raw.isEmpty {
            guard let clean = Self.headerValue(raw, maximum: 128) else { return nil }
            result.accountID = clean
        } else {
            result.accountID = nil
        }
        if let raw = identity, !raw.isEmpty {
            result.identity = WidgetSnapshotSanitizer.text(raw, maxCharacters: 256)
        } else {
            result.identity = nil
        }
        if let expiresAt {
            guard WidgetSnapshotSanitizer.valid(expiresAt) else { return nil }
            result.expiresAt = expiresAt
        } else {
            result.expiresAt = nil
        }
        return result
    }

    func encoded() throws -> Data {
        guard let clean = validated() else { throw WidgetCredentialError.invalid }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(clean)
    }

    static func decode(_ data: Data) -> WidgetCredentialRecord? {
        guard !data.isEmpty, data.count <= WidgetCredentialStore.maximumPayloadBytes else { return nil }
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .millisecondsSince1970
            return try decoder.decode(WidgetCredentialRecord.self, from: data).validated()
        } catch {
            return nil
        }
    }

    private static func headerValue(_ value: String?, maximum: Int) -> String? {
        guard let value, !value.isEmpty, value.utf8.count <= maximum else { return nil }
        guard value.unicodeScalars.allSatisfy({ (33...126).contains($0.value) }) else { return nil }
        return value
    }

    private static func apiKey(_ value: String?) -> String? {
        guard let value, (8...8_192).contains(value.utf8.count),
              value.unicodeScalars.allSatisfy({ (33...126).contains($0.value) }) else { return nil }
        return value
    }
}

// Separate service from the app's com.wm0104.quotawatch vault. No access group is requested here;
// the host target owns entitlement registration. Every read validates again and nothing is cached,
// so a record that becomes invalid is never reused from memory.
enum WidgetCredentialStore {
    static let service = "com.wm0104.quotawatch.widget-credentials"
    static let accessGroup = "com.wm0104.quotawatch.widget"
    static let maximumPayloadBytes = 65_536

    static func load(accountID: UUID, provider: String,
                     allowedAccountIDs: Set<UUID>? = nil) throws -> WidgetCredentialRecord {
        if let allowedAccountIDs, !allowedAccountIDs.contains(accountID) {
            throw WidgetCredentialError.accountNotAllowed
        }
        #if os(iOS)
        var query = baseQuery(accountID)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data,
              data.count <= maximumPayloadBytes else {
            throw status == errSecItemNotFound
                ? WidgetCredentialError.notFound : WidgetCredentialError.unavailable
        }
        guard let record = WidgetCredentialRecord.decode(data),
              record.provider == provider else { throw WidgetCredentialError.invalid }
        return record
        #else
        throw WidgetCredentialError.unavailable
        #endif
    }

    // Save is restricted to an explicit allowed account set so a widget cannot invent an account
    // or overwrite credentials for an account absent from its snapshot.
    static func save(_ record: WidgetCredentialRecord, accountID: UUID, provider: String,
                     allowedAccountIDs: Set<UUID>) throws {
        guard allowedAccountIDs.contains(accountID) else {
            throw WidgetCredentialError.accountNotAllowed
        }
        guard record.provider == provider, let clean = record.validated(),
              clean.provider == provider else { throw WidgetCredentialError.invalid }
        #if os(iOS)
        let data: Data
        do { data = try clean.encoded() }
        catch { throw WidgetCredentialError.invalid }
        guard data.count <= maximumPayloadBytes else { throw WidgetCredentialError.invalid }
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        let status = SecItemUpdate(baseQuery(accountID) as CFDictionary,
                                   attributes as CFDictionary)
        if status == errSecItemNotFound {
            var item = baseQuery(accountID)
            attributes.forEach { item[$0.key] = $0.value }
            guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else {
                throw WidgetCredentialError.saveFailed
            }
        } else if status != errSecSuccess {
            throw WidgetCredentialError.saveFailed
        }
        #else
        throw WidgetCredentialError.unavailable
        #endif
    }

    // Host-only cleanup: call this when an account is removed from the app. The widget must use
    // the allowed-account overload so it can never delete another account's credential.
    static func delete(accountID: UUID) throws {
        #if os(iOS)
        let status = SecItemDelete(baseQuery(accountID) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw WidgetCredentialError.deleteFailed
        }
        #else
        throw WidgetCredentialError.unavailable
        #endif
    }

    static func delete(accountID: UUID, allowedAccountIDs: Set<UUID>) throws {
        guard allowedAccountIDs.contains(accountID) else {
            throw WidgetCredentialError.accountNotAllowed
        }
        try delete(accountID: accountID)
    }

    #if os(iOS)
    private static func baseQuery(_ accountID: UUID) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: accountID.uuidString,
         kSecAttrAccessGroup as String: accessGroup]
    }
    #endif
}
