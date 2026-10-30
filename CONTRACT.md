# QuotaWatch internal API contract (Swift 5 / iOS 16)

Independent original implementation. No source copied from OpenMinis. Files below must agree; UI/store owner handles persistence, Keychain, notifications and quota HTTP requests. No real credentials in tests or logs.

## Core files (Models.swift / QuotaParser.swift)

Foundation only, portable to macOS swiftc for tests.

- `enum ProviderKind: String, Codable, CaseIterable, Identifiable { case codex, deepseek }`, computed `id: String`, `name: String`, `interval: TimeInterval` (300/600).
- `enum QuotaUnit: String, Codable { case percent, cny, usd, credits }`
- `struct Credential: Codable, Equatable`: optional String `apiKey`, `accessToken`, `refreshToken`, `accountID`, `identity`; optional Date `expiresAt`. All properties default nil so `Credential(apiKey: ...)` works. This type is NEVER serialized into account cache.
- `struct QuotaMetric: Codable, Equatable, Identifiable`: `id: String`, `title: String`, `unit: QuotaUnit`, `remaining: Decimal?`, `resetAt: Date? = nil`, `granted: Decimal? = nil`, `toppedUp: Decimal? = nil`, `unlimited: Bool = false`.
- `struct QuotaSnapshot: Codable, Equatable`: `capturedAt: Date`, `metrics: [QuotaMetric]`, `plan: String? = nil`, `available: Bool? = nil`.
- `struct AlertRule: Codable, Equatable, Identifiable`: `metricID: String`, `threshold: Decimal`, `enabled: Bool = true`; computed `id: String { metricID }`.
- `struct Account: Codable, Identifiable, Equatable`: `id: UUID = UUID()`, `kind: ProviderKind`, `alias: String`, `remoteID: String? = nil`, `identity: String? = nil`, `snapshot: QuotaSnapshot? = nil`, `rules: [AlertRule] = []`, `latched: Set<String> = []`, `error: String? = nil`, `lastAttempt: Date? = nil`, `nextAllowedAt: Date? = nil`, `requiresAuth: Bool = false`, `revision: UUID = UUID()`, `createdAt: Date = Date()`. Use synthesized memberwise initializers, var fields.
- `enum QuotaError: LocalizedError { case message(String) }` with user-readable errorDescription. Never include response bodies or tokens in errors.
- `enum QuotaParser { static func parse(_ data: Data, kind: ProviderKind, now: Date = Date()) throws -> QuotaSnapshot }` Parse actual DeepSeek and Codex shapes, empty valid arrays are unknown not zero, no silently accepted unrecognized responses. Codex metric IDs `codex.primary.<seconds>` / `codex.secondary.<seconds>` (use primary/secondary if missing duration), extra limits use stable upstream name prefix; credits separate. Reject invalid values, don't sum windows/currencies; explicit allowed false without percent must not imply percentage zero. Use Decimal money and 100-used_percent (clamped 0...100 for valid nonnegative used %). Negative/malformed data rejected or absent, never manufactured values.
- `enum AlertEvaluator { static func evaluate(snapshot: QuotaSnapshot, rules: [AlertRule], latched: Set<String>, interval: TimeInterval, now: Date = Date()) -> (notify: [String], latched: Set<String>) }` threshold <=, fresh data only (<=2*interval), resetAt<=now unknown, missing/unknown windows keep old latch (not rearm); healthy above threshold clears latch; initially-low emits then latches; disabled rules no notify. It may produce prospective latch; store commits latch only after scheduling success.

## OAuth file

`@MainActor final class CodexOAuth: NSObject, ObservableObject`:
- `@Published private(set) var isLoggingIn = false`
- `func login() async throws -> Credential` self presents SFSafariViewController from current topmost controller, handles cancel, 180s timeout, state/PKCE and local loopback callback. Fail safely if port in use, never listen on LAN. Follow CLI authorize/token config from public source, not unapproved token extraction.
- `func cancel()`
- `static func refresh(_ existing: Credential) async throws -> Credential` preserves accountID/identity/refreshToken if refresh response omits; exposes no raw server errors. expired/revoked refresh throws QuotaError.message with re-login text.
- Scope openid profile email offline_access; CLI client ID public identifier; redirect http://localhost:1455/auth/callback; browser login force account choice if supported. JWT decode only for display metadata, not for cryptographic identity verification.

## Build

Bundle com.wm0104.quotawatch; version 0.1.1, build 2; arm64 iPhone/iPad; iOS 16.3. Keychain group com.wm0104.quotawatch and application-identifier same; get-task-allow false. Never enterprise/private platform/root entitlements.
