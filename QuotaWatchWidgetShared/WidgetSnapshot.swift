import Foundation

// Versioned, credential-free widget cache. This file is intentionally independent of
// Models.swift so the widget and the macOS tests can compile it on its own.
enum WidgetSnapshotLimits {
    static let schemaVersion = 1
    static let widgetKind = "QuotaWatchWidget"
    static let maximumAccounts = 5
    static let maximumMetricsPerAccount = 8
    static let maximumAliasLength = 64
    static let maximumTitleLength = 120
    static let maximumMetricIDLength = 200
    static let maximumErrorLength = 160
    static let maximumDurationSeconds = 31_536_000
    static let maximumFileBytes = 1_000_000
    static let earliestDate = Date(timeIntervalSince1970: 978_307_200)   // 2001-01-01
    static let latestDate = Date(timeIntervalSince1970: 4_102_444_800)   // 2100-01-01
    static let allowedProviders: Set<String> = ["codex", "deepseek"]
    static let allowedUnits: Set<String> = ["percent", "cny", "usd", "credits"]

    static func defaultAlias(for provider: String) -> String {
        switch provider {
        case "codex": return "Codex"
        case "deepseek": return "DeepSeek"
        default: return "账户"
        }
    }
}

enum WidgetSnapshotError: LocalizedError {
    case invalidSnapshot
    var errorDescription: String? { "小组件数据无效，未写入。" }
}

// One sanitized quota row. It deliberately has no granted/topped-up/plan/account ID.
struct WidgetMetricSnapshot: Codable, Equatable, Identifiable {
    var id: String
    var title: String
    var unit: String
    var remaining: Decimal?
    var resetAt: Date?
    var unlimited: Bool
    var durationSeconds: Int?

    init(id: String, title: String, unit: String, remaining: Decimal? = nil,
         resetAt: Date? = nil, unlimited: Bool = false, durationSeconds: Int? = nil) {
        self.id = id
        self.title = title
        self.unit = unit
        self.remaining = remaining
        self.resetAt = resetAt
        self.unlimited = unlimited
        self.durationSeconds = durationSeconds
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, unit, remaining, resetAt, unlimited, durationSeconds
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        unit = try container.decode(String.self, forKey: .unit)
        title = ((try? container.decodeIfPresent(String.self, forKey: .title)) ?? nil) ?? id
        remaining = (try? container.decodeIfPresent(Decimal.self, forKey: .remaining)) ?? nil
        resetAt = (try? container.decodeIfPresent(Date.self, forKey: .resetAt)) ?? nil
        unlimited = ((try? container.decodeIfPresent(Bool.self, forKey: .unlimited)) ?? nil) ?? false
        durationSeconds = (try? container.decodeIfPresent(Int.self, forKey: .durationSeconds)) ?? nil
    }

    func sanitized() -> WidgetMetricSnapshot? {
        guard let cleanID = WidgetSnapshotSanitizer.identifier(
                id, maxCharacters: WidgetSnapshotLimits.maximumMetricIDLength),
              WidgetSnapshotLimits.allowedUnits.contains(unit) else { return nil }
        guard !unlimited || unit == "credits" else { return nil }
        if let remaining, !Self.valid(remaining, unit: unit) { return nil }

        let cleanTitle = WidgetSnapshotSanitizer.text(
            title, maxCharacters: WidgetSnapshotLimits.maximumTitleLength) ?? cleanID
        let cleanReset = resetAt.flatMap {
            WidgetSnapshotSanitizer.valid($0) ? $0 : nil
        }
        let cleanDuration = durationSeconds.flatMap {
            (1...WidgetSnapshotLimits.maximumDurationSeconds).contains($0) ? $0 : nil
        }
        return WidgetMetricSnapshot(
            id: cleanID, title: cleanTitle, unit: unit, remaining: remaining,
            resetAt: cleanReset, unlimited: unlimited, durationSeconds: cleanDuration)
    }

    private static func valid(_ value: Decimal, unit: String) -> Bool {
        guard !value.isNaN, value >= 0 else { return false }
        switch unit {
        case "percent": return value <= 100
        case "cny", "usd": return value <= Decimal(1_000_000_000_000)
        case "credits": return value <= Decimal(1_000_000_000)
        default: return false
        }
    }
}

// Opaque local UUID only. No remote account ID, email, alias from the provider, or credential.
struct WidgetAccountSnapshot: Codable, Equatable, Identifiable {
    var id: UUID
    var provider: String
    var displayAlias: String
    var metrics: [WidgetMetricSnapshot]
    var creditsAvailable: Bool?
    var capturedAt: Date
    var lastError: String?

    init(id: UUID = UUID(), provider: String, displayAlias: String,
         metrics: [WidgetMetricSnapshot], creditsAvailable: Bool? = nil,
         capturedAt: Date, lastError: String? = nil) {
        self.id = id
        self.provider = provider
        self.displayAlias = displayAlias
        self.metrics = metrics
        self.creditsAvailable = creditsAvailable
        self.capturedAt = capturedAt
        self.lastError = lastError
    }

    private enum CodingKeys: String, CodingKey {
        case id, provider, displayAlias, metrics, creditsAvailable, capturedAt, lastError
    }
    private enum LegacyKeys: String, CodingKey { case capturesAt }

    // Canonical cache key follows QuotaSnapshot.capturedAt. `capturesAt` is a read-only spelling
    // compatibility alias; decode also accepts that key from an older writer.
    var capturesAt: Date { capturedAt }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        provider = try container.decode(String.self, forKey: .provider)
        displayAlias = ((try? container.decodeIfPresent(String.self, forKey: .displayAlias)) ?? nil) ?? ""
        creditsAvailable = (try? container.decodeIfPresent(Bool.self, forKey: .creditsAvailable)) ?? nil
        if let value = (try? container.decodeIfPresent(Date.self, forKey: .capturedAt)) ?? nil {
            capturedAt = value
        } else if let legacy = try? decoder.container(keyedBy: LegacyKeys.self),
                  let value = (try? legacy.decodeIfPresent(Date.self, forKey: .capturesAt)) ?? nil {
            capturedAt = value
        } else {
            throw WidgetSnapshotError.invalidSnapshot
        }
        lastError = (try? container.decodeIfPresent(String.self, forKey: .lastError)) ?? nil
        if let raw = try? container.decode([WidgetFailableDecodable<WidgetMetricSnapshot>].self,
                                          forKey: .metrics) {
            metrics = raw.compactMap(\.value)
        } else {
            metrics = []
        }
    }

    func sanitized(relativeTo generatedAt: Date) -> WidgetAccountSnapshot? {
        guard WidgetSnapshotLimits.allowedProviders.contains(provider),
              WidgetSnapshotSanitizer.valid(capturedAt),
              capturedAt <= generatedAt.addingTimeInterval(300) else { return nil }

        var seen: Set<String> = []
        let cleanMetrics = Array(metrics.compactMap { $0.sanitized() }
            .filter { seen.insert($0.id).inserted }
            .prefix(WidgetSnapshotLimits.maximumMetricsPerAccount))
        let alias = WidgetSnapshotSanitizer.text(
            displayAlias, maxCharacters: WidgetSnapshotLimits.maximumAliasLength)
            ?? WidgetSnapshotLimits.defaultAlias(for: provider)
        let error = lastError.flatMap { WidgetSnapshotSanitizer.errorText($0) }
        return WidgetAccountSnapshot(
            id: id, provider: provider, displayAlias: alias, metrics: cleanMetrics,
            creditsAvailable: creditsAvailable, capturedAt: capturedAt, lastError: error)
    }
}

struct WidgetSnapshot: Codable, Equatable {
    var schemaVersion: Int
    var generatedAt: Date
    var accounts: [WidgetAccountSnapshot]

    init(schemaVersion: Int = WidgetSnapshotLimits.schemaVersion,
         generatedAt: Date = Date(), accounts: [WidgetAccountSnapshot] = []) {
        self.schemaVersion = schemaVersion
        self.generatedAt = generatedAt
        self.accounts = accounts
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, generatedAt, accounts
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        generatedAt = try container.decode(Date.self, forKey: .generatedAt)
        let raw = try container.decode([WidgetFailableDecodable<WidgetAccountSnapshot>].self,
                                       forKey: .accounts)
        accounts = raw.compactMap(\.value)
        // An array that exists but contains no decodable account is corruption, not an empty state.
        if !raw.isEmpty && accounts.isEmpty { throw WidgetSnapshotError.invalidSnapshot }
    }

    func sanitized() -> WidgetSnapshot? {
        guard schemaVersion == WidgetSnapshotLimits.schemaVersion,
              WidgetSnapshotSanitizer.valid(generatedAt) else { return nil }
        var seen: Set<UUID> = []
        let cleanAccounts = Array(accounts
            .compactMap { $0.sanitized(relativeTo: generatedAt) }
            .filter { seen.insert($0.id).inserted }
            .prefix(WidgetSnapshotLimits.maximumAccounts))
        guard accounts.isEmpty || !cleanAccounts.isEmpty else { return nil }
        return WidgetSnapshot(schemaVersion: WidgetSnapshotLimits.schemaVersion,
                              generatedAt: generatedAt, accounts: cleanAccounts)
    }

    func jsonData() throws -> Data {
        guard let clean = sanitized() else { throw WidgetSnapshotError.invalidSnapshot }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(clean)
    }

    static func decode(_ data: Data) -> WidgetSnapshot? {
        guard !data.isEmpty, data.count <= WidgetSnapshotLimits.maximumFileBytes else { return nil }
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .millisecondsSince1970
            let raw = try decoder.decode(WidgetSnapshot.self, from: data)
            guard let clean = raw.sanitized() else { return nil }
            guard raw.accounts.isEmpty || !clean.accounts.isEmpty else { return nil }
            return clean
        } catch {
            return nil
        }
    }
}

struct WidgetFailableDecodable<Value: Decodable>: Decodable {
    let value: Value?
    init(from decoder: Decoder) throws { value = try? Value(from: decoder) }
}

// Single-line, bounded, email/token-redacted display strings. Raw response bodies are rejected
// from lastError so a caller cannot accidentally persist a body containing secrets.
enum WidgetSnapshotSanitizer {
    private static let email = try? NSRegularExpression(
        pattern: "[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\\.[A-Za-z]{2,}", options: [])
    private static let longSecret = try? NSRegularExpression(
        pattern: "[A-Za-z0-9_\\-]{32,}", options: [])

    static func identifier(_ value: String, maxCharacters: Int) -> String? {
        let allowed = CharacterSet(charactersIn:
            "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        guard !value.isEmpty, value.count <= maxCharacters,
              value.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return nil }
        return value
    }

    static func text(_ value: String, maxCharacters: Int) -> String? {
        guard let line = collapsed(value) else { return nil }
        return String(redacted(line).prefix(maxCharacters))
    }

    static func errorText(_ value: String) -> String? {
        guard let line = collapsed(value), !looksLikePayload(line) else { return nil }
        return String(redacted(line).prefix(WidgetSnapshotLimits.maximumErrorLength))
    }

    static func valid(_ date: Date) -> Bool {
        let value = date.timeIntervalSince1970
        return value.isFinite
            && value >= WidgetSnapshotLimits.earliestDate.timeIntervalSince1970
            && value <= WidgetSnapshotLimits.latestDate.timeIntervalSince1970
    }

    private static func collapsed(_ value: String) -> String? {
        let cleaned = value.unicodeScalars.map { scalar -> String in
            if CharacterSet.controlCharacters.contains(scalar) { return " " }
            return String(scalar)
        }.joined()
        let line = cleaned.split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        return line.isEmpty ? nil : line
    }

    private static func redacted(_ value: String) -> String {
        var text = value
        for regex in [email, longSecret].compactMap({ $0 }) {
            text = regex.stringByReplacingMatches(
                in: text, options: [], range: NSRange(text.startIndex..., in: text),
                withTemplate: "[已隐藏]")
        }
        return text
    }

    private static func looksLikePayload(_ value: String) -> Bool {
        let lower = value.lowercased()
        return ["{", "}", "bearer ", "access_token", "refresh_token", "api_key", "client_secret"]
            .contains { lower.contains($0) }
    }
}
