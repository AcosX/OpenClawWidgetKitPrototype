import Foundation
import Darwin
import CryptoKit

private let defaultWidgetURL = "http://127.0.0.1"

private typealias AccountConfig = OpenClawWidgetAccount
private typealias ClickUpConfig = OpenClawWidgetClickUp
private typealias WorkerConfig = OpenClawWidgetConfiguration

private struct OfficialResetPayload: Decodable, Sendable {
    let status: String?
    let updatedAt: Date?
    let accounts: [OfficialResetAccount]

    enum CodingKeys: String, CodingKey {
        case status
        case updatedAt = "updated_at"
        case accounts
    }
}

private struct OfficialResetAccount: Decodable, Sendable {
    let name: String
    let accountID: Int?
    let status: String?
    let message: String?
    let availableCount: Int?
    let totalEarnedCount: Int?
    let credits: [ResetCredit]?

    enum CodingKeys: String, CodingKey {
        case name
        case accountIDCamel = "accountID"
        case accountIDSnake = "account_id"
        case status
        case message
        case availableCount = "available_count"
        case totalEarnedCount = "total_earned_count"
        case credits
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        accountID = try container.decodeIfPresent(Int.self, forKey: .accountIDCamel)
            ?? container.decodeIfPresent(Int.self, forKey: .accountIDSnake)
        status = try container.decodeIfPresent(String.self, forKey: .status)
        message = try container.decodeIfPresent(String.self, forKey: .message)
        availableCount = try container.decodeIfPresent(Int.self, forKey: .availableCount)
        totalEarnedCount = try container.decodeIfPresent(Int.self, forKey: .totalEarnedCount)
        credits = try container.decodeIfPresent([ResetCredit].self, forKey: .credits)
    }
}

private struct ResetCredit: Codable, Sendable {
    let status: String?
    let resetType: String?
    let grantedAt: String?
    let expiresAt: String?
    let redeemStartedAt: String?
    let redeemedAt: String?
    let title: String?
    let description: String?

    enum CodingKeys: String, CodingKey {
        case status
        case resetType = "reset_type"
        case grantedAt = "granted_at"
        case expiresAt = "expires_at"
        case redeemStartedAt
        case redeemedAt
        case title
        case description
    }
}

private struct RateLimitWindow: Codable, Sendable {
    let usedPercent: Double?
    let remainingPercent: Double?
    let windowSeconds: Double?
    let resetAt: String?
    let resetAfterSeconds: Double?
}

private struct AccountResult: Codable, Sendable {
    let name: String
    let displayName: String?
    let abbreviation: String?
    let remaining: Double?
    let limit: Double?
    let used: Double?
    let unit: String?
    let window: String?
    let status: String
    let message: String?
    let resetAvailableCount: Int?
    let resetCreditExpirations: [String]?
    let resetMessage: String?
    let resetCredits: [ResetCredit]?
    let resetCreditsUpdatedAt: Date?
    var primaryWindow: RateLimitWindow? = nil
    var secondaryWindow: RateLimitWindow? = nil

    // Sub2API 调度状态（仅用于展示与自动恢复判断；旧缓存缺少这些字段时保持 nil）。
    var sub2apiStatus: String?
    var sub2apiIsRateLimited: Bool?
    var sub2apiIsOverloaded: Bool?
    var sub2apiHasError: Bool?
    var sub2apiIsAvailable: Bool?
    var sub2apiIsSchedulable: Bool?
    var sub2apiRateLimitResetAt: String?
    var sub2apiTempUnschedulableUntil: String?
    var sub2apiErrorMessage: String?
    var sub2apiStateUnknown: Bool?

    // Resolved admin account ID for configs matched by name/searchName through
    // the admin account list.
    var resolvedAccountID: Int?

    // Stable identity for the current quota baseline period. It is assigned when
    // quota decreases (or when an older cache without the field is first seen)
    // and is reused until the next decrease. Quota-increase event IDs include it
    // so retries deduplicate without suppressing a later identical reset.
    var quotaResetOccurrence: String?
}

private struct PendingRateLimitRestoration: Codable, Sendable {
    let accountName: String
    let detectedAt: Date
    let oldRemaining: Double?
    let newRemaining: Double?
    let quotaOccurrence: String?
    let resolvedAccountID: Int?
    var attempts: Int
    var lastAttemptAt: Date?
    var lastError: String?
}

private struct WidgetData: Codable, Sendable {
    let updatedAt: Date
    let source: String
    let widgetURL: String
    let accounts: [AccountResult]
    let pendingRateLimitRestorations: [PendingRateLimitRestoration]?
}

private struct Outbox: Codable, Sendable {
    var version = 1
    var items: [OutboxItem] = []
}

private struct OutboxItem: Codable, Identifiable, Sendable {
    let id: UUID
    let kind: String
    let content: String
    let createdAt: Date
    var attempts: Int
    var nextAttemptAt: Date
    var lastError: String?
    // A send is recorded before the HTTP request. If the process dies after the
    // request reaches ClickUp, the next run must not blindly create a duplicate.
    var deliveryState: String?
    var attemptStartedAt: Date?
    var acceptedMessageID: String?
    var acceptedChannelID: String?
}

private struct ReceiptStore: Codable, Sendable {
    var version = 1
    var receipts: [DeliveryReceipt] = []
}

private struct DeliveryReceipt: Codable, Sendable {
    let eventID: UUID
    let kind: String
    let messageID: String
    let deliveredAt: Date
    let channelID: String
}

private struct WorkerStatus: Codable, Sendable {
    let state: String
    let detail: String
    let mode: String
    let runStartedAt: Date
    let runFinishedAt: Date
    let updatedAt: Date
    let outboxPending: Int?
    let refreshedAccounts: Int
    let failedAccounts: Int
    let queuedMessages: Int
    let lastClickUpMessageID: String?
    let autoRestoredAccounts: Int
    let autoRestoreFailedAccounts: Int
    let pendingAutoRestores: Int?
}

private struct ClickUpTestResult: Codable, Sendable {
    let version: Int
    let eventID: UUID
    let state: String
    let detail: String
    let completedAt: Date
    let messageID: String?
    let channelID: String?
}

private struct RefreshSummary: Sendable {
    let refreshed: Int
    let failed: Int
    let queued: Int
    let autoRestored: Int
    let autoRestoreFailed: Int
    let pendingAutoRestores: Int
}

private struct RestoreReport: Sendable {
    let attempted: Int
    let restored: Int
    let failed: Int
    let details: [String]
}

private struct Sub2APIAccountState: Sendable {
    let status: String?
    let isRateLimited: Bool?
    let isOverloaded: Bool?
    let hasError: Bool?
    let isAvailable: Bool?
    let isSchedulable: Bool?
    let rateLimitResetAt: String?
    let tempUnschedulableUntil: String?
    let errorMessage: String?
}

private struct DeliveryReport: Sendable {
    var delivered: [UUID: String] = [:]
    var deliveredChannels: [UUID: String] = [:]
    var deferred = 0
    var uncertain = 0
    var storageWarnings = 0
    var issue: String?

    var hasIssue: Bool {
        deferred > 0 || uncertain > 0 || storageWarnings > 0 || issue != nil
    }

    mutating func noteIssue(_ value: String) {
        if issue == nil { issue = value }
    }
}

private enum WorkerError: LocalizedError {
    case missingAdminToken
    case missingAdminBaseURL
    case invalidAdminBaseURL
    case missingAccountID
    case emptyAccounts
    case missingClickUpConfiguration
    case invalidURL
    case http(Int)
    case invalidResponse(String)
    case allRoutesFailed([String])
    case lockBusy
    case lockUnavailable
    case unreadableOutbox
    case unreadableReceipts
    case invalidTestEventID
    case testMessageNotDelivered
    case acceptanceRecordNotPersisted

    var errorDescription: String? {
        switch self {
        case .missingAdminToken:
            return "admin token is missing"
        case .missingAdminBaseURL:
            return "admin base URL is missing; configure backend.adminBaseURL"
        case .invalidAdminBaseURL:
            return "admin base URL is invalid; expected an http(s) URL with a host"
        case .missingAccountID:
            return "account ID is missing"
        case .emptyAccounts:
            return "no accounts are configured"
        case .missingClickUpConfiguration:
            return "ClickUp workspace/channel configuration is incomplete"
        case .invalidURL:
            return "request URL is invalid"
        case .http(let code):
            return "HTTP \(code)"
        case .invalidResponse(let name):
            return "invalid response: \(name)"
        case .allRoutesFailed(let failures):
            return "all routes failed: \(failures.joined(separator: "; "))"
        case .lockBusy:
            return "another worker run owns the refresh lock"
        case .lockUnavailable:
            return "the refresh lock file is unavailable"
        case .unreadableOutbox:
            return "ClickUp outbox is unreadable or invalid"
        case .unreadableReceipts:
            return "ClickUp receipt store is unreadable or invalid"
        case .invalidTestEventID:
            return "test event ID is invalid"
        case .testMessageNotDelivered:
            return "test message was not durably delivered"
        case .acceptanceRecordNotPersisted:
            return "ClickUp accepted a message but its delivery record could not be persisted"
        }
    }
}

@main
private enum RefreshWorkerMain {
    private static let requestTimeout: TimeInterval = 15
    // Resolve paths from the selected config file so the worker is portable.
    // OpenClawWidgetPaths retains the old absolute location only as an explicit
    // compatibility fallback for existing installations.
    private static let explicitConfigURL: URL? = {
        let arguments = Array(CommandLine.arguments.dropFirst())
        guard let index = arguments.firstIndex(of: "--config"), arguments.indices.contains(arguments.index(after: index)) else { return nil }
        return URL(fileURLWithPath: arguments[arguments.index(after: index)]).standardizedFileURL
    }()
    private static var paths: OpenClawWidgetPaths {
        let config = OpenClawWidgetPaths.resolveConfigURL(explicit: explicitConfigURL)
        // --config selects credentials/configuration only. Runtime data stays
        // in the shared container so App and Widget always see the same cache.
        let defaultDirectory = OpenClawWidgetPaths.defaultDirectory()
        return OpenClawWidgetPaths(configURL: config, dataDirectory: defaultDirectory)
    }
    private static var configDirectory: URL { paths.directory }
    private static var configURL: URL { paths.configURL }
    private static var cacheURL: URL { paths.cacheURL }
    private static var statusURL: URL { paths.statusURL }
    private static var outboxURL: URL { paths.outboxURL }
    private static var receiptsURL: URL { paths.receiptsURL }
    private static var testResultURL: URL { paths.testResultURL }
    private static var logURL: URL { paths.logURL }
    private static var lockURL: URL { paths.lockURL }

    static func main() async {
        let code = await run()
        Darwin.exit(code)
    }

    private static func run() async -> Int32 {
        let arguments = Array(CommandLine.arguments.dropFirst())
        if arguments.contains("--print-config-path") {
            print(OpenClawWidgetPaths.resolveConfigURL(explicit: explicitConfigURL).path)
            return 0
        }
        if arguments.contains("--print-data-directory") {
            print(OpenClawWidgetPaths.defaultDirectory().path)
            return 0
        }
        let mode: String
        if arguments.contains("--restore-status") {
            mode = "restore-status"
        } else if arguments.contains("--test-clickup") {
            mode = "test-clickup"
        } else {
            mode = "run-once"
        }
        let requestedTestEventID: UUID?
        do {
            requestedTestEventID = try testEventID(arguments: arguments, mode: mode)
        } catch {
            return 64
        }
        let startedAt = Date()
        var testResultAlreadyRecorded = false

        do {
            try prepareConfigurationDirectory()
        } catch {
            if let eventID = requestedTestEventID {
                // The configuration directory itself is unavailable, so no durable
                // test result can be written. The non-zero process result is the only
                // remaining signal in this exceptional case.
                _ = eventID
            }
            return 70
        }

        let lock: LockAcquireResult
        do {
            lock = try acquireLock()
        } catch {
            appendLog(level: "error", event: "lock_unavailable", fields: ["mode": mode])
            if let eventID = requestedTestEventID {
                try? writeTestResult(
                    eventID: eventID,
                    state: "failed",
                    detail: safeDescription(WorkerError.lockUnavailable),
                    messageID: nil,
                    channelID: nil
                )
            }
            return 1
        }

        guard case .acquired(let lockFD) = lock else {
            appendLog(level: "info", event: "lock_busy", fields: ["mode": mode])
            // Exit 75 is retried by the caller. Do not write the shared test
            // result here: another concurrent test may already have recorded a
            // delivered receipt for its own event ID.
            return 75
        }
        defer {
            flock(lockFD, LOCK_UN)
            close(lockFD)
        }

        rotateLogIfNeeded()
        appendLog(level: "info", event: "run_started", fields: ["mode": mode])

        do {
            let configData = try Data(contentsOf: configURL)
            // The legacy path is a read-only migration source for the old
            // installed app. Do not even change its mode while probing it.
            if !isLegacyCompatibilityConfigURL {
                restrictPermissions(of: configURL, to: 0o600)
            }
            let config = try decode(WorkerConfig.self, from: configData)
            var outbox = try loadOutbox()
            var lastMessageID: String?
            var summary = RefreshSummary(refreshed: 0, failed: 0, queued: 0, autoRestored: 0, autoRestoreFailed: 0, pendingAutoRestores: 0)
            var refreshFailure: Error?
            var restoreReport: RestoreReport?
            var delivery = DeliveryReport()

            if mode == "test-clickup" {
                guard let testEventID = requestedTestEventID else { throw WorkerError.invalidTestEventID }
                let testItem = OutboxItem(
                    id: testEventID,
                    kind: "test",
                    content: "OpenClaw Widget ClickUp delivery test. Time: \(iso8601String(Date()))",
                    createdAt: Date(),
                    attempts: 0,
                    nextAttemptAt: Date(),
                    lastError: nil,
                    deliveryState: nil,
                    attemptStartedAt: nil,
                    acceptedMessageID: nil,
                    acceptedChannelID: nil
                )
                if !outbox.items.contains(where: { $0.id == testEventID }) {
                    outbox.items.append(testItem)
                }
                try saveOutbox(outbox)
                delivery = await deliverDueMessages(outbox: &outbox, config: config, forcedEventID: testItem.id, processOnlyForcedEvent: true)
                lastMessageID = delivery.delivered[testItem.id]
                guard lastMessageID != nil else {
                    // A failed or deferred test must not leak into ordinary
                    // --run-once outbox processing and be sent later by surprise.
                    outbox.items.removeAll { $0.id == testItem.id }
                    do {
                        try saveOutbox(outbox)
                    } catch {
                        appendLog(level: "error", event: "clickup_test_cleanup_failed", fields: [
                            "event_id": testItem.id.uuidString,
                            "reason": safeDescription(error)
                        ])
                    }
                    throw WorkerError.testMessageNotDelivered
                }
            } else {
                if mode == "restore-status" {
                    let routes = try adminRoutes(config.adminBaseURL)
                    restoreReport = try await restoreAccountStates(config: config, routes: routes, token: config.adminToken ?? "")
                }
                do {
                    summary = try await refreshCache(config: config, outbox: &outbox)
                } catch {
                    refreshFailure = error
                    // refreshCache durably writes newly queued events before it
                    // advances the cache baseline. Reload so delivery always sees
                    // the durable source of truth, even if its later cache write
                    // failed.
                    outbox = try loadOutbox()
                }
                delivery = await deliverDueMessages(outbox: &outbox, config: config, forcedEventID: nil)
                lastMessageID = delivery.delivered.values.first
            }

            let state: String
            let detail: String
            let exitCode: Int32
            if mode == "test-clickup" {
                state = "success"
                detail = "ClickUp test delivered with a message receipt"
                exitCode = 0
            } else if let refreshFailure {
                state = "error"
                let prefix = mode == "restore-status" ? "account restore finished; " : ""
                detail = "\(prefix)quota refresh failed; ClickUp outbox processed: \(safeDescription(refreshFailure))"
                exitCode = 1
            } else if let restoreReport, restoreReport.failed > 0 {
                state = "partial"
                let failureDetails = restoreReport.details.joined(separator: "; ")
                var parts = [
                    "account restore failed for \(restoreReport.failed)/\(restoreReport.attempted) accounts (\(failureDetails))"
                ]
                if summary.failed > 0 {
                    parts.append("\(summary.failed) account quota refresh(es) retained stale cache")
                }
                detail = parts.joined(separator: "; ")
                exitCode = 1
            } else if summary.failed > 0 {
                state = "partial"
                detail = "some accounts were refreshed; stale cache was retained for failures"
                exitCode = 1
            } else if summary.autoRestoreFailed > 0 {
                state = "partial"
                detail = "quota cache refreshed; auto account restore failed for \(summary.autoRestoreFailed) recovered account(s)"
                exitCode = 1
            } else if summary.pendingAutoRestores > 0 {
                state = "partial"
                detail = "quota cache refreshed; automatic account restore is still pending for \(summary.pendingAutoRestores) recovered account(s)"
                exitCode = 1
            } else if !outbox.items.isEmpty || delivery.hasIssue {
                state = "partial"
                detail = deliveryDetail(outbox: outbox, report: delivery)
                exitCode = 1
            } else if mode == "restore-status" {
                state = "success"
                detail = "account status restored and quota cache refreshed"
                exitCode = 0
            } else if summary.autoRestored > 0 {
                state = "success"
                detail = "quota cache refreshed; auto-restored \(summary.autoRestored) rate-limited account(s)"
                exitCode = 0
            } else {
                state = "success"
                detail = "quota cache refreshed"
                exitCode = 0
            }

            if let eventID = requestedTestEventID {
                try writeTestResult(
                    eventID: eventID,
                    state: "delivered",
                    detail: "ClickUp test delivered with a message receipt",
                    messageID: lastMessageID,
                    channelID: delivery.deliveredChannels[eventID]
                )
                testResultAlreadyRecorded = true
            }
            try writeStatus(
                state: state,
                detail: detail,
                mode: mode,
                startedAt: startedAt,
                outbox: outbox,
                summary: summary,
                lastMessageID: lastMessageID
            )
            appendLog(level: state == "success" ? "info" : "error", event: "run_finished", fields: [
                "mode": mode,
                "state": state,
                "refreshed": "\(summary.refreshed)",
                "failed": "\(summary.failed)",
                "queued": "\(summary.queued)",
                "auto_restored": "\(summary.autoRestored)",
                "auto_restore_failed": "\(summary.autoRestoreFailed)",
                "outbox_pending": String(outbox.items.count),
                "has_receipt": lastMessageID == nil ? "false" : "true"
            ])
            return exitCode
        } catch {
            let detail = safeDescription(error)
            try? writeStatus(
                state: "error",
                detail: detail,
                mode: mode,
                startedAt: startedAt,
                outbox: nil,
                summary: RefreshSummary(refreshed: 0, failed: 0, queued: 0, autoRestored: 0, autoRestoreFailed: 0, pendingAutoRestores: 0),
                lastMessageID: nil
            )
            if let eventID = requestedTestEventID, !testResultAlreadyRecorded {
                try? writeTestResult(
                    eventID: eventID,
                    state: "failed",
                    detail: detail,
                    messageID: nil,
                    channelID: nil
                )
            }
            appendLog(level: "error", event: "run_failed", fields: ["mode": mode, "reason": detail])
            return 1
        }
    }

    private enum LockAcquireResult {
        case acquired(Int32)
        case busy
    }

    private static func acquireLock() throws -> LockAcquireResult {
        let fd = open(lockURL.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw WorkerError.lockUnavailable }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            close(fd)
            return .busy
        }
        return .acquired(fd)
    }

    private static func selectedAccounts(from config: WorkerConfig) -> [AccountConfig] {
        var seenNames = Set<String>()
        let maxAccounts = max(1, min(config.behavior?.maxAccounts ?? 2, 8))
        return config.accounts.reduce(into: [AccountConfig]()) { selected, account in
            guard selected.count < maxAccounts, !account.name.isEmpty, seenNames.insert(account.name).inserted else { return }
            selected.append(account)
        }
    }

    private static func usesLegacyUsage(_ account: AccountConfig) -> Bool {
        account.accountID == nil
            && trimmed(account.baseURL) != nil
            && trimmed(account.apiKey) != nil
    }

    private static func refreshCache(config: WorkerConfig, outbox: inout Outbox) async throws -> RefreshSummary {
        let selectedAccounts = selectedAccounts(from: config)
        guard !selectedAccounts.isEmpty else { throw WorkerError.emptyAccounts }
        let adminBackedAccounts = selectedAccounts.filter { !usesLegacyUsage($0) }
        let routes = adminBackedAccounts.isEmpty ? [] : try adminRoutes(config.adminBaseURL)
        let token: String
        if !adminBackedAccounts.isEmpty {
            guard let adminToken = config.adminToken, !adminToken.isEmpty else { throw WorkerError.missingAdminToken }
            token = adminToken
        } else {
            token = ""
        }
        let previous: WidgetData?
        let previousCacheURL = OpenClawWidgetPaths.resolveCacheURL()
        if FileManager.default.fileExists(atPath: previousCacheURL.path) {
            // A cache that exists but cannot be read/decoded still contains the
            // recovery baseline and any pending restorations. Do not treat it as
            // a first run and overwrite it; fail this refresh and preserve it.
            let previousData = try Data(contentsOf: previousCacheURL)
            previous = try decode(WidgetData.self, from: previousData)
        } else {
            previous = nil
        }
        let previousByName = Dictionary((previous?.accounts ?? []).map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })

        var refreshedResults = await withTaskGroup(of: (Int, AccountResult).self, returning: [AccountResult].self) { group in
            for (index, account) in selectedAccounts.enumerated() {
                let old = previousByName[account.name]
                group.addTask {
                    let result = await fetchAccount(account, old: old, routes: routes, token: token)
                    return (index, result)
                }
            }
            var ordered = Array<AccountResult?>(repeating: nil, count: selectedAccounts.count)
            for await (index, result) in group {
                ordered[index] = result
            }
            return ordered.compactMap { $0 }
        }

        refreshedResults = await mergeOfficialResetCreditsIfAvailable(into: refreshedResults, config: config)
        if !adminBackedAccounts.isEmpty {
            refreshedResults = await mergeSub2APIStates(into: refreshedResults, previousByName: previousByName, accounts: selectedAccounts, routes: routes, token: token)
        }
        refreshedResults = applyQuotaBaselineOccurrences(to: refreshedResults, previous: previous, previousByName: previousByName)

        var queued = 0
        var autoRestored = 0
        var autoRestoreFailed = 0
        var pendingRestorations = previous?.pendingRateLimitRestorations ?? []
        var attemptedClearAccounts = Set<String>()

        // Retry restorations that were durably recorded by an earlier run. The
        // previous cache baseline has already advanced for these accounts, so the
        // new-increase scan below cannot see them again.
        var retainedPendingRestorations: [PendingRateLimitRestoration] = []
        for var pending in pendingRestorations {
            guard let currentIndex = refreshedResults.firstIndex(where: { $0.name == pending.accountName }) else {
                if selectedAccounts.contains(where: { $0.name == pending.accountName }) {
                    retainedPendingRestorations.append(pending)
                    appendLog(level: "info", event: "sub2api_rate_limit_restore_pending_retained", fields: [
                        "account": pending.accountName,
                        "reason": "account_not_in_refresh_result"
                    ])
                } else {
                    appendLog(level: "info", event: "sub2api_rate_limit_restore_pending_expired", fields: [
                        "account": pending.accountName,
                        "reason": "account_not_in_selected_refresh_set"
                    ])
                }
                continue
            }

            // A pending clear belongs to the recovered quota period. It remains
            // valid while the account identity is unchanged and either the
            // occurrence is unchanged or the balance is still above the
            // pre-recovery value (ordinary consumption after recovery).
            let currentAccount = refreshedResults[currentIndex]
            if pending.resolvedAccountID != nil || currentAccount.resolvedAccountID != nil {
                guard pending.resolvedAccountID == currentAccount.resolvedAccountID else {
                    appendLog(level: "info", event: "sub2api_rate_limit_restore_pending_expired", fields: [
                        "account": pending.accountName,
                        "reason": "resolved_account_changed"
                    ])
                    continue
                }
            }
            let sameOccurrence = pending.quotaOccurrence != nil
                && currentAccount.quotaResetOccurrence == pending.quotaOccurrence
            let stillAbovePreRecovery = pending.oldRemaining.flatMap { oldRemaining in
                currentAccount.remaining.map { $0 > oldRemaining }
            } ?? false
            if pending.resolvedAccountID == nil {
                guard sameOccurrence else {
                    appendLog(level: "info", event: "sub2api_rate_limit_restore_pending_expired", fields: [
                        "account": pending.accountName,
                        "reason": "quota_baseline_changed"
                    ])
                    continue
                }
            } else {
                guard sameOccurrence || stillAbovePreRecovery else {
                    appendLog(level: "info", event: "sub2api_rate_limit_restore_pending_expired", fields: [
                        "account": pending.accountName,
                        "reason": "quota_baseline_changed"
                    ])
                    continue
                }
            }

            // Do not issue the clear from a stale quota result; wait until a live
            // refresh confirms that the pending baseline is still the current one.
            guard refreshedResults[currentIndex].status == "ok" else {
                retainedPendingRestorations.append(pending)
                appendLog(level: "info", event: "sub2api_rate_limit_restore_pending_retained", fields: [
                    "account": pending.accountName,
                    "reason": "quota_result_stale"
                ])
                continue
            }

            // Preserved scheduling fields are for recovery discovery only. Never
            // issue a clear based on stale/unknown state.
            guard refreshedResults[currentIndex].sub2apiStateUnknown != true else {
                retainedPendingRestorations.append(pending)
                appendLog(level: "info", event: "sub2api_rate_limit_restore_pending_retained", fields: [
                    "account": pending.accountName,
                    "reason": "scheduling_state_unknown"
                ])
                continue
            }

            // If a later run observed that the account is definitively no longer
            // rate-limited, the pending clear has already been resolved elsewhere.
            if refreshedResults[currentIndex].sub2apiIsRateLimited == false {
                appendLog(level: "info", event: "sub2api_rate_limit_restore_pending_resolved", fields: [
                    "account": pending.accountName,
                    "reason": "account_no_longer_rate_limited"
                ])
                continue
            }

            // A live lookup that omits/nullifies is_rate_limited is not evidence
            // that the limiter is still active. Keep the item until it returns an
            // explicit true or false.
            guard refreshedResults[currentIndex].sub2apiIsRateLimited == true else {
                retainedPendingRestorations.append(pending)
                appendLog(level: "info", event: "sub2api_rate_limit_restore_pending_retained", fields: [
                    "account": pending.accountName,
                    "reason": "rate_limit_flag_not_confirmed"
                ])
                continue
            }

            let configuredPendingAccountID = selectedAccounts.first(where: { $0.name == pending.accountName })?.accountID
            guard let accountID = refreshedResults[currentIndex].resolvedAccountID ?? configuredPendingAccountID else {
                retainedPendingRestorations.append(pending)
                appendLog(level: "error", event: "sub2api_rate_limit_restore_pending_retained", fields: [
                    "account": pending.accountName,
                    "reason": "accountID_missing"
                ])
                continue
            }

            do {
                try await clearRateLimit(accountID: accountID, routes: routes, token: token)
                autoRestored += 1
                attemptedClearAccounts.insert(pending.accountName)
                refreshedResults[currentIndex].sub2apiIsRateLimited = false
                refreshedResults[currentIndex].sub2apiRateLimitResetAt = nil
                let recomputedAvailability = recomputeSub2APIAvailability(for: refreshedResults[currentIndex])
                refreshedResults[currentIndex].sub2apiIsAvailable = recomputedAvailability
                if recomputedAvailability == nil {
                    refreshedResults[currentIndex].sub2apiStateUnknown = true
                }
                appendLog(level: "info", event: "sub2api_rate_limit_auto_restored", fields: [
                    "account": pending.accountName,
                    "account_id": "\(accountID)",
                    "old_remaining": pending.oldRemaining.map { "\($0)" } ?? "",
                    "new_remaining": pending.newRemaining.map { "\($0)" } ?? "",
                    "pending_attempts": "\(pending.attempts)"
                ])
            } catch {
                autoRestoreFailed += 1
                attemptedClearAccounts.insert(pending.accountName)
                pending.attempts += 1
                pending.lastAttemptAt = Date()
                pending.lastError = safeDescription(error)
                retainedPendingRestorations.append(pending)
                appendLog(level: "error", event: "sub2api_rate_limit_auto_restore_failed", fields: [
                    "account": pending.accountName,
                    "account_id": "\(accountID)",
                    "reason": safeDescription(error),
                    "pending_attempts": "\(pending.attempts)"
                ])
            }
        }
        pendingRestorations = retainedPendingRestorations

        for index in refreshedResults.indices {
            let current = refreshedResults[index]
            guard current.status == "ok",
                  let old = previousByName[current.name],
                  isCompatibleQuotaBaseline(old, current),
                  let oldRemaining = old.remaining,
                  let newRemaining = current.remaining,
                  newRemaining > oldRemaining else { continue }
            let eventID = quotaIncreaseEventID(
                accountName: current.name,
                oldRemaining: oldRemaining,
                newRemaining: newRemaining,
                occurrence: current.quotaResetOccurrence ?? "initial"
            )

            if !outbox.items.contains(where: { $0.id == eventID }) {
                let displayName = current.displayName ?? current.name
                let content = [
                    "Codex quota recovered",
                    "\(displayName): \(formatQuota(oldRemaining, unit: current.unit)) -> \(formatQuota(newRemaining, unit: current.unit))",
                    "Detected: \(iso8601String(Date()))"
                ].joined(separator: "\n")
                outbox.items.append(OutboxItem(
                    id: eventID,
                    kind: "quota-increase",
                    content: content,
                    createdAt: Date(),
                    attempts: 0,
                    nextAttemptAt: Date(),
                    lastError: nil,
                    deliveryState: nil,
                    attemptStartedAt: nil,
                    acceptedMessageID: nil,
                    acceptedChannelID: nil
                ))
                queued += 1
            }

            // 额度已经恢复但 Sub2API 仍把账号标记为限流时，自动清一次限流状态。
            // Unknown scheduling state, or a live lookup that omitted the flag,
            // must be queued before the baseline advances even when the cached
            // flag is false: the cached value is stale evidence. A later
            // known-good run will either clear or resolve the pending item.
            if current.sub2apiStateUnknown == true || current.sub2apiIsRateLimited == nil {
                if !pendingRestorations.contains(where: { $0.accountName == current.name }) {
                    pendingRestorations.append(PendingRateLimitRestoration(
                        accountName: current.name,
                        detectedAt: Date(),
                        oldRemaining: oldRemaining,
                        newRemaining: newRemaining,
                        quotaOccurrence: current.quotaResetOccurrence,
                        resolvedAccountID: current.resolvedAccountID,
                        attempts: 0,
                        lastAttemptAt: nil,
                        lastError: nil
                    ))
                    appendLog(level: "info", event: "sub2api_rate_limit_restore_pending_created", fields: [
                        "account": current.name,
                        "reason": current.sub2apiStateUnknown == true ? "scheduling_state_unknown" : "rate_limit_flag_missing"
                    ])
                }
                continue
            }

            guard current.sub2apiIsRateLimited != false else { continue }

            guard !attemptedClearAccounts.contains(current.name) else { continue }
            let configuredAccountID = selectedAccounts.first(where: { $0.name == current.name })?.accountID
            guard let accountID = current.resolvedAccountID ?? configuredAccountID else { continue }
            do {
                try await clearRateLimit(accountID: accountID, routes: routes, token: token)
                autoRestored += 1
                attemptedClearAccounts.insert(current.name)
                refreshedResults[index].sub2apiIsRateLimited = false
                refreshedResults[index].sub2apiRateLimitResetAt = nil
                let recomputedAvailability = recomputeSub2APIAvailability(for: refreshedResults[index])
                refreshedResults[index].sub2apiIsAvailable = recomputedAvailability
                if recomputedAvailability == nil {
                    refreshedResults[index].sub2apiStateUnknown = true
                }
                appendLog(level: "info", event: "sub2api_rate_limit_auto_restored", fields: [
                    "account": current.name,
                    "account_id": "\(accountID)",
                    "old_remaining": String(oldRemaining),
                    "new_remaining": String(newRemaining)
                ])
            } catch {
                autoRestoreFailed += 1
                attemptedClearAccounts.insert(current.name)
                if !pendingRestorations.contains(where: { $0.accountName == current.name }) {
                    pendingRestorations.append(PendingRateLimitRestoration(
                        accountName: current.name,
                        detectedAt: Date(),
                        oldRemaining: oldRemaining,
                        newRemaining: newRemaining,
                        quotaOccurrence: current.quotaResetOccurrence,
                        resolvedAccountID: current.resolvedAccountID ?? configuredAccountID,
                        attempts: 1,
                        lastAttemptAt: Date(),
                        lastError: safeDescription(error)
                    ))
                }
                appendLog(level: "error", event: "sub2api_rate_limit_auto_restore_failed", fields: [
                    "account": current.name,
                    "account_id": "\(accountID)",
                    "reason": safeDescription(error)
                ])
            }
        }

        // Durably queue notifications and persist the pending restoration list
        // before advancing the comparison baseline.
        try saveOutbox(outbox)
        let payload = WidgetData(
            updatedAt: Date(),
            source: "sub2api background worker",
            widgetURL: config.widgetURL ?? previous?.widgetURL ?? defaultWidgetURL,
            accounts: refreshedResults,
            pendingRateLimitRestorations: pendingRestorations.isEmpty ? nil : pendingRestorations
        )
        try atomicWrite(encode(payload), to: cacheURL, permissions: 0o600)

        let ok = refreshedResults.filter { $0.status == "ok" }.count
        return RefreshSummary(
            refreshed: ok,
            failed: refreshedResults.count - ok,
            queued: queued,
            autoRestored: autoRestored,
            autoRestoreFailed: autoRestoreFailed,
            pendingAutoRestores: pendingRestorations.count
        )
    }

    private static func applyQuotaBaselineOccurrences(
        to accounts: [AccountResult],
        previous: WidgetData?,
        previousByName: [String: AccountResult]
    ) -> [AccountResult] {
        let legacyBaselineOccurrence = previous.map {
            "baseline-\(String(format: "%.6f", $0.updatedAt.timeIntervalSince1970))"
        } ?? "initial"
        return accounts.map { account in
            var updated = account
            guard let old = previousByName[account.name] else {
                updated.quotaResetOccurrence = UUID().uuidString
                return updated
            }
            guard isCompatibleQuotaBaseline(old, updated) else {
                // The configured name now points at a different account/unit.
                updated.quotaResetOccurrence = UUID().uuidString
                return updated
            }
            let oldOccurrence = old.quotaResetOccurrence
            if old.remaining == updated.remaining {
                // Same baseline: keep its identity across ordinary refreshes.
                updated.quotaResetOccurrence = oldOccurrence ?? legacyBaselineOccurrence
            } else if let oldRemaining = old.remaining,
                      let newRemaining = updated.remaining,
                      newRemaining > oldRemaining {
                // A recovery keeps the occurrence of the depleted baseline so the
                // event ID stays stable while the outbox retries delivery.
                updated.quotaResetOccurrence = oldOccurrence ?? legacyBaselineOccurrence
            } else {
                // Quota moved downward, so this is a new baseline (for example a
                // weekly reset that starts the next 0 -> 100 recovery).
                updated.quotaResetOccurrence = UUID().uuidString
            }
            return updated
        }
    }

    private static func isCompatibleQuotaBaseline(_ old: AccountResult, _ current: AccountResult) -> Bool {
        // A pre-ID cache entry (old nil) must remain compatible on its first
        // refresh so a recovery that happened before deployment is not missed.
        // Once the old side has an ID, the current side must carry the same one.
        if let oldID = old.resolvedAccountID {
            guard oldID == current.resolvedAccountID else { return false }
        }
        guard old.unit == current.unit else { return false }
        if let oldWindow = old.window, let currentWindow = current.window {
            guard oldWindow == currentWindow else { return false }
        }
        return true
    }

    // MARK: - Sub2API 账号状态

    private static func mergeSub2APIStates(
        into accounts: [AccountResult],
        previousByName: [String: AccountResult],
        accounts config: [AccountConfig],
        routes: [String],
        token: String
    ) async -> [AccountResult] {
        let states = await fetchSub2APIStates(routes: routes, token: token)
        guard !states.isEmpty else {
            // Both scheduling-state lookups failed. Keep the last known state
            // instead of persisting fresh nil fields, which would make a pending
            // auto-restore undiscoverable and make the UI treat unknown as normal.
            appendLog(level: "info", event: "sub2api_states_unavailable_preserving_cache", fields: [:])
            return accounts.map { account in
                guard let old = previousByName[account.name] else {
                    var updated = account
                    updated.sub2apiStateUnknown = true
                    return updated
                }
                var updated = account
                updated.sub2apiStatus = old.sub2apiStatus
                updated.sub2apiIsRateLimited = old.sub2apiIsRateLimited
                updated.sub2apiIsOverloaded = old.sub2apiIsOverloaded
                updated.sub2apiHasError = old.sub2apiHasError
                updated.sub2apiIsAvailable = old.sub2apiIsAvailable
                updated.sub2apiIsSchedulable = old.sub2apiIsSchedulable
                updated.sub2apiRateLimitResetAt = old.sub2apiRateLimitResetAt
                updated.sub2apiTempUnschedulableUntil = old.sub2apiTempUnschedulableUntil
                updated.sub2apiErrorMessage = old.sub2apiErrorMessage
                updated.sub2apiStateUnknown = true
                return updated
            }
        }
        return accounts.map { account in
            let configuredAccountID = config.first(where: { $0.name == account.name })?.accountID
            guard let accountID = account.resolvedAccountID ?? configuredAccountID,
                  let state = states[accountID] else {
                guard let old = previousByName[account.name] else {
                    var updated = account
                    updated.sub2apiStateUnknown = true
                    return updated
                }
                var updated = account
                updated.sub2apiStatus = old.sub2apiStatus
                updated.sub2apiIsRateLimited = old.sub2apiIsRateLimited
                updated.sub2apiIsOverloaded = old.sub2apiIsOverloaded
                updated.sub2apiHasError = old.sub2apiHasError
                updated.sub2apiIsAvailable = old.sub2apiIsAvailable
                updated.sub2apiIsSchedulable = old.sub2apiIsSchedulable
                updated.sub2apiRateLimitResetAt = old.sub2apiRateLimitResetAt
                updated.sub2apiTempUnschedulableUntil = old.sub2apiTempUnschedulableUntil
                updated.sub2apiErrorMessage = old.sub2apiErrorMessage
                updated.sub2apiStateUnknown = true
                return updated
            }
            var updated = account
            updated.sub2apiStatus = state.status
            updated.sub2apiIsRateLimited = state.isRateLimited
            updated.sub2apiIsOverloaded = state.isOverloaded
            updated.sub2apiHasError = state.hasError
            updated.sub2apiIsAvailable = state.isAvailable
            updated.sub2apiIsSchedulable = state.isSchedulable
            updated.sub2apiRateLimitResetAt = state.rateLimitResetAt
            updated.sub2apiTempUnschedulableUntil = state.tempUnschedulableUntil
            updated.sub2apiErrorMessage = state.errorMessage
            updated.sub2apiStateUnknown = false
            return updated
        }
    }

    private static func fetchSub2APIStates(routes: [String], token: String) async -> [Int: Sub2APIAccountState] {
        if let states = await fetchSub2APIStatesFromAvailability(routes: routes, token: token), !states.isEmpty {
            return states
        }
        appendLog(level: "info", event: "sub2api_availability_unavailable", fields: ["fallback": "admin-account-list"])
        if let states = await fetchSub2APIStatesFromAdminList(routes: routes, token: token), !states.isEmpty {
            return states
        }
        return [:]
    }

    private static func fetchSub2APIStatesFromAvailability(routes: [String], token: String) async -> [Int: Sub2APIAccountState]? {
        var failures: [String] = []
        for route in routes {
            let routeLabel = URL(string: route)?.host ?? "admin-route"
            guard let url = URL(string: "\(route)/api/v1/admin/ops/account-availability") else { return nil }
            do {
                let data = try await requestData(url: url, headers: ["X-API-Key": token], expectedStatus: 200..<300)
                let raw = try JSONSerialization.jsonObject(with: data)
                guard let root = unwrapDictionary(raw) else { throw WorkerError.invalidResponse("account availability") }
                if let enabled = root["enabled"] as? Bool, !enabled { return nil }
                guard let accountMap = root["account"] as? [String: Any] else {
                    throw WorkerError.invalidResponse("account availability map")
                }
                var states: [Int: Sub2APIAccountState] = [:]
                for (key, value) in accountMap {
                    guard let accountID = Int(key), let object = value as? [String: Any] else { continue }
                    states[accountID] = sub2APIState(
                        status: object["status"] as? String,
                        isRateLimited: object["is_rate_limited"] as? Bool,
                        isOverloaded: object["is_overloaded"] as? Bool,
                        hasError: object["has_error"] as? Bool,
                        isAvailable: object["is_available"] as? Bool,
                        isSchedulable: nil,
                        rateLimitResetAt: object["rate_limit_reset_at"] as? String,
                        tempUnschedulableUntil: object["temp_unschedulable_until"] as? String,
                        errorMessage: object["error_message"] as? String
                    )
                }
                return states
            } catch {
                failures.append("\(routeLabel): \(safeDescription(error))")
                if !shouldTryAlternateRoute(after: error) { return nil }
            }
        }
        if !failures.isEmpty {
            appendLog(level: "info", event: "sub2api_availability_request_failed", fields: ["failures": failures.joined(separator: "; ")])
        }
        return nil
    }

    private static func fetchSub2APIStatesFromAdminList(routes: [String], token: String) async -> [Int: Sub2APIAccountState]? {
        do {
            let items = try await fetchAdminAccountsData(routes: routes, token: token)
            var states: [Int: Sub2APIAccountState] = [:]
            let now = Date()
            for item in items {
                guard let accountID = integer(item["id"]) else { continue }
                let status = item["status"] as? String
                let isSchedulable = item["schedulable"] as? Bool
                let rateLimitResetAt = item["rate_limit_reset_at"] as? String
                let overloadUntil = item["overload_until"] as? String
                let tempUnschedulableUntil = item["temp_unschedulable_until"] as? String
                let isRateLimited = rateLimitResetAt.flatMap(parseISO8601).map { $0 > now } ?? false
                let isOverloaded = overloadUntil.flatMap(parseISO8601).map { $0 > now } ?? false
                let isTempUnschedulable = tempUnschedulableUntil.flatMap(parseISO8601).map { $0 > now } ?? false
                let hasError = status == "error"
                let isAvailable = status == "active"
                    && isSchedulable != false
                    && !isRateLimited
                    && !isOverloaded
                    && !isTempUnschedulable
                states[accountID] = sub2APIState(
                    status: status,
                    isRateLimited: isRateLimited,
                    isOverloaded: isOverloaded,
                    hasError: hasError,
                    isAvailable: isAvailable,
                    isSchedulable: isSchedulable,
                    rateLimitResetAt: rateLimitResetAt,
                    tempUnschedulableUntil: tempUnschedulableUntil,
                    errorMessage: item["error_message"] as? String
                )
            }
            return states
        } catch {
            appendLog(level: "info", event: "sub2api_admin_list_status_unavailable", fields: ["reason": safeDescription(error)])
            return nil
        }
    }

    private static func sub2APIState(
        status: String?,
        isRateLimited: Bool?,
        isOverloaded: Bool?,
        hasError: Bool?,
        isAvailable: Bool?,
        isSchedulable: Bool?,
        rateLimitResetAt: String?,
        tempUnschedulableUntil: String?,
        errorMessage: String?
    ) -> Sub2APIAccountState {
        let normalizedHasError = hasError ?? (status == "error" ? true : nil)
        let normalizedRateLimited = normalizedHasError == true ? false : isRateLimited
        let normalizedOverloaded = normalizedHasError == true ? false : isOverloaded
        return Sub2APIAccountState(
            status: status,
            isRateLimited: normalizedRateLimited,
            isOverloaded: normalizedOverloaded,
            hasError: normalizedHasError,
            isAvailable: isAvailable,
            isSchedulable: isSchedulable,
            rateLimitResetAt: rateLimitResetAt,
            tempUnschedulableUntil: tempUnschedulableUntil,
            errorMessage: errorMessage
        )
    }

    private static func recomputeSub2APIAvailability(for account: AccountResult) -> Bool? {
        guard account.sub2apiStatus == "active" else { return false }
        // The clear removed the limiter, but a prior live lookup said the account
        // was unavailable for some other reason we cannot recompute here. Keep
        // that as unknown instead of manufacturing a healthy state.
        if account.sub2apiIsAvailable == false { return nil }
        if account.sub2apiHasError == true { return false }
        if account.sub2apiIsRateLimited == true { return false }
        if account.sub2apiIsOverloaded == true { return false }
        if account.sub2apiIsSchedulable == false { return false }
        if let until = account.sub2apiTempUnschedulableUntil,
           !until.isEmpty,
           let deadline = parseISO8601(until),
           deadline > Date() {
            return false
        }
        return true
    }


    private static func restoreAccountStates(config: WorkerConfig, routes: [String], token: String) async throws -> RestoreReport {
        let accounts = selectedAccounts(from: config)
        guard !accounts.isEmpty else { throw WorkerError.emptyAccounts }
        guard !token.isEmpty else { throw WorkerError.missingAdminToken }

        // Configs that omit accountID are still supported through name/searchName
        // matching against the admin account list. Resolve those IDs once so both
        // this manual restore and later state merges can target the account.
        var resolvedIDs: [String: Int] = [:]
        let accountsNeedingIDResolution = accounts.filter { $0.accountID == nil }
        if !accountsNeedingIDResolution.isEmpty {
            do {
                let adminAccounts = try await fetchAdminAccountsData(routes: routes, token: token)
                for account in accountsNeedingIDResolution {
                    guard let match = findAccount(config: account, in: adminAccounts),
                          let matchedID = integer(match["id"]) else { continue }
                    resolvedIDs[account.name] = matchedID
                }
            } catch {
                appendLog(level: "error", event: "sub2api_restore_id_resolution_failed", fields: [
                    "reason": safeDescription(error)
                ])
            }
        }

        var attempted = 0
        var restored = 0
        var failed = 0
        var details: [String] = []
        for account in accounts {
            attempted += 1
            guard let accountID = account.accountID ?? resolvedIDs[account.name] else {
                failed += 1
                let detail = "\(account.name): accountID missing"
                details.append(detail)
                appendLog(level: "error", event: "sub2api_restore_missing_account_id", fields: ["account": account.name])
                continue
            }
            do {
                try await clearRateLimit(accountID: accountID, routes: routes, token: token)
                restored += 1
                appendLog(level: "info", event: "sub2api_restore_succeeded", fields: ["account": account.name, "account_id": "\(accountID)"])
            } catch {
                failed += 1
                let detail = "\(account.name): \(safeDescription(error))"
                details.append(detail)
                appendLog(level: "error", event: "sub2api_restore_failed", fields: [
                    "account": account.name,
                    "account_id": "\(accountID)",
                    "reason": safeDescription(error)
                ])
            }
        }
        return RestoreReport(attempted: attempted, restored: restored, failed: failed, details: details)
    }

    private static func clearRateLimit(accountID: Int, routes: [String], token: String) async throws {
        var failures: [String] = []
        for route in routes {
            let routeLabel = URL(string: route)?.host ?? "admin-route"
            guard let url = URL(string: "\(route)/api/v1/admin/accounts/\(accountID)/clear-rate-limit") else {
                throw WorkerError.invalidURL
            }
            do {
                _ = try await requestData(url: url, headers: ["X-API-Key": token], expectedStatus: 200..<300, method: "POST")
                return
            } catch {
                failures.append("\(routeLabel): \(safeDescription(error))")
                if !shouldTryAlternateRoute(after: error) { throw error }
            }
        }
        throw WorkerError.allRoutesFailed(failures)
    }


    private static func quotaIncreaseEventID(accountName: String, oldRemaining: Double, newRemaining: Double, occurrence: String) -> UUID {
        let input = "quota-increase:\(accountName):\(oldRemaining):\(newRemaining):\(occurrence)"
        let digest = SHA256.hash(data: Data(input.utf8))
        let bytes = Array(digest.prefix(16))
        let hex = bytes.map { String(format: "%02x", $0) }.joined()
        let uuidString = "\(hex.prefix(8))-\(hex.dropFirst(8).prefix(4))-\(hex.dropFirst(12).prefix(4))-\(hex.dropFirst(16).prefix(4))-\(hex.dropFirst(20))"
        return UUID(uuidString: uuidString) ?? UUID()
    }

    private static func mergeOfficialResetCreditsIfAvailable(into accounts: [AccountResult], config: WorkerConfig) async -> [AccountResult] {
        guard let bridgeBaseURL = trimmed(config.bridgeBaseURL) else { return accounts }
        let normalized = normalizeBaseURL(bridgeBaseURL)
        guard let url = URL(string: "\(normalized)/codex-reset-credits") else { return accounts }
        do {
            let data = try await requestData(
                url: url,
                headers: ["X-Bridge-Token": config.bridgeToken ?? ""],
                expectedStatus: 200..<300
            )
            let official = try decode(OfficialResetPayload.self, from: data)
            return applyOfficialResetCredits(official, to: accounts, config: config)
        } catch {
            appendLog(level: "error", event: "official_reset_credits_unavailable", fields: ["reason": safeDescription(error)])
            return accounts
        }
    }

    private static func applyOfficialResetCredits(_ official: OfficialResetPayload, to accounts: [AccountResult], config: WorkerConfig) -> [AccountResult] {
        accounts.map { account in
            let configured = config.accounts.first(where: { $0.name == account.name })
            let match: OfficialResetAccount?
            let wantedIdentity = (configured?.searchName ?? configured?.name ?? account.name)
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            let nameMatch: OfficialResetAccount?
            if !wantedIdentity.isEmpty {
                let exact = official.accounts.filter { $0.name.lowercased() == wantedIdentity }
                if exact.count == 1 {
                    nameMatch = exact[0]
                } else if exact.isEmpty {
                    let partial = official.accounts.filter { $0.name.lowercased().contains(wantedIdentity) }
                    nameMatch = partial.count == 1 ? partial[0] : nil
                } else {
                    nameMatch = nil
                }
            } else {
                nameMatch = nil
            }
            if let configuredAccountID = configured?.accountID {
                match = official.accounts.first(where: { $0.accountID == configuredAccountID }) ?? nameMatch
            } else {
                match = nameMatch
            }
            guard let match else { return account }
            let isBridgeAccountError = match.status == "error"
            let credits = isBridgeAccountError ? (account.resetCredits ?? []) : (match.credits ?? [])
            let availableCredits = credits.filter { $0.status == nil || $0.status == "available" }
            let sourceCredits = availableCredits.isEmpty ? credits : availableCredits
            let expirations = isBridgeAccountError
                ? (account.resetCreditExpirations ?? [])
                : sourceCredits.compactMap(\.expiresAt).sorted()
            let message: String? = {
                if isBridgeAccountError { return match.message ?? "官方 reset credits 查询失败" }
                if let count = match.availableCount, count > 0, expirations.isEmpty { return "官方接口返回可用次数，但未返回 expires_at 明细" }
                return account.resetMessage
            }()
            return AccountResult(
                name: account.name,
                displayName: account.displayName,
                abbreviation: account.abbreviation,
                remaining: account.remaining,
                limit: account.limit,
                used: account.used,
                unit: account.unit,
                window: account.window,
                status: account.status,
                message: account.message,
                resetAvailableCount: isBridgeAccountError
                    ? account.resetAvailableCount
                    : (match.availableCount ?? account.resetAvailableCount),
                resetCreditExpirations: expirations,
                resetMessage: message,
                resetCredits: credits,
                resetCreditsUpdatedAt: isBridgeAccountError ? account.resetCreditsUpdatedAt : official.updatedAt,
                primaryWindow: account.primaryWindow,
                secondaryWindow: account.secondaryWindow,
                resolvedAccountID: account.resolvedAccountID
            )
        }
    }

    private static func fetchAccount(
        _ account: AccountConfig,
        old: AccountResult?,
        routes: [String],
        token: String
    ) async -> AccountResult {
        if let accountID = account.accountID {
            do {
                var result = try await fetchQuotaAccount(accountID: accountID, account: account, old: old, routes: routes, token: token)
                result.resolvedAccountID = accountID
                return result
            } catch {
                return staleResult(account: account, old: old, message: safeDescription(error))
            }
        }

        if let baseURL = trimmed(account.baseURL), let apiKey = trimmed(account.apiKey) {
            return await fetchLegacyUsage(account: account, old: old, baseURL: baseURL, apiKey: apiKey)
        }

        do {
            let accountsData = try await fetchAdminAccountsData(routes: routes, token: token)
            guard let match = findAccount(config: account, in: accountsData) else {
                return withDisplayFields(
                    from: account,
                    AccountResult(
                        name: account.name,
                        displayName: account.displayName,
                        abbreviation: account.abbreviation,
                        remaining: nil,
                        limit: nil,
                        used: nil,
                        unit: nil,
                        window: "30d",
                        status: "missing",
                        message: "未找到账号",
                        resetAvailableCount: old?.resetAvailableCount,
                        resetCreditExpirations: old?.resetCreditExpirations,
                        resetMessage: old?.resetMessage,
                        resetCredits: old?.resetCredits,
                        resetCreditsUpdatedAt: old?.resetCreditsUpdatedAt,
                        primaryWindow: old?.primaryWindow,
                        secondaryWindow: old?.secondaryWindow
                    )
                )
            }

            let matchedID = integer(match["id"])
            var result = withDisplayFields(from: account, accountResultFromAdminList(match, account: account, old: old))
            result.resolvedAccountID = matchedID
            if let matchedID {
                do {
                    var live = try await fetchQuotaAccount(accountID: matchedID, account: account, old: old, routes: routes, token: token)
                    live.resolvedAccountID = matchedID
                    if live.remaining != nil || live.resetAvailableCount != nil {
                        result = live
                    }
                } catch {
                    result = AccountResult(
                        name: result.name,
                        displayName: result.displayName,
                        abbreviation: result.abbreviation,
                        remaining: result.remaining ?? old?.remaining,
                        limit: result.limit ?? old?.limit,
                        used: result.used ?? old?.used,
                        unit: result.unit ?? old?.unit,
                        window: result.window ?? old?.window ?? "30d",
                        status: "stale",
                        message: "额度接口刷新失败，保留账号列表数据：\(safeDescription(error))",
                        resetAvailableCount: result.resetAvailableCount ?? old?.resetAvailableCount,
                        resetCreditExpirations: result.resetCreditExpirations ?? old?.resetCreditExpirations,
                        resetMessage: result.resetMessage ?? old?.resetMessage,
                        resetCredits: result.resetCredits ?? old?.resetCredits,
                        resetCreditsUpdatedAt: result.resetCreditsUpdatedAt ?? old?.resetCreditsUpdatedAt,
                        primaryWindow: result.primaryWindow ?? old?.primaryWindow,
                        secondaryWindow: result.secondaryWindow ?? old?.secondaryWindow,
                        resolvedAccountID: matchedID
                    )
                }
            }
            return result
        } catch {
            return staleResult(account: account, old: old, message: safeDescription(error))
        }
    }

    private static func fetchQuotaAccount(
        accountID: Int,
        account: AccountConfig,
        old: AccountResult?,
        routes: [String],
        token: String
    ) async throws -> AccountResult {
        var failures: [String] = []
        for route in routes {
            let routeLabel = URL(string: route)?.host ?? "admin-route"
            guard let url = URL(string: "\(route)/api/v1/admin/openai/accounts/\(accountID)/quota") else {
                throw WorkerError.invalidURL
            }
            do {
                let data = try await requestData(url: url, headers: ["X-API-Key": token], expectedStatus: 200..<300)
                let raw = try JSONSerialization.jsonObject(with: data)
                guard let object = unwrapDictionary(raw) else { throw WorkerError.invalidResponse("quota object") }
                guard let parsed = parseQuota(object, account: account, old: old) else {
                    throw WorkerError.invalidResponse("quota fields")
                }
                return parsed
            } catch {
                failures.append("\(routeLabel): \(safeDescription(error))")
                if !shouldTryAlternateRoute(after: error) { throw error }
            }
        }
        throw WorkerError.allRoutesFailed(failures)
    }

    private static func fetchAdminAccountsData(routes: [String], token: String) async throws -> [[String: Any]] {
        var failures: [String] = []
        for route in routes {
            let routeLabel = URL(string: route)?.host ?? "admin-route"
            do {
                let firstRaw = try await fetchAdminAccountsPage(route: route, page: 1, token: token)
                guard var items = adminAccountItems(from: firstRaw) else {
                    throw WorkerError.invalidResponse("admin accounts list")
                }
                let pageSize = paginationInteger(in: firstRaw, key: "page_size") ?? 100
                let total = paginationInteger(in: firstRaw, key: "total") ?? paginationInteger(in: firstRaw, key: "count")
                let declaredPages = paginationInteger(in: firstRaw, key: "pages")
                let inferredPages = total.map { max(1, ($0 + max(1, pageSize) - 1) / max(1, pageSize)) } ?? 1
                let pages = min(1_000, max(1, declaredPages ?? inferredPages))
                if pages > 1 {
                    for page in 2...pages {
                        let pageRaw = try await fetchAdminAccountsPage(route: route, page: page, token: token)
                        guard let pageItems = adminAccountItems(from: pageRaw), !pageItems.isEmpty else { continue }
                        items.append(contentsOf: pageItems)
                    }
                }
                return items
            } catch {
                failures.append("\(routeLabel): \(safeDescription(error))")
                if !shouldTryAlternateRoute(after: error) { throw error }
            }
        }
        throw WorkerError.allRoutesFailed(failures)
    }

    private static func fetchAdminAccountsPage(route: String, page: Int, token: String) async throws -> Any {
        guard let url = URL(string: "\(route)/api/v1/admin/accounts?page=\(page)&page_size=100") else {
            throw WorkerError.invalidURL
        }
        let data = try await requestData(url: url, headers: ["X-API-Key": token], expectedStatus: 200..<300)
        return try JSONSerialization.jsonObject(with: data)
    }

    private static func adminAccountItems(from raw: Any) -> [[String: Any]]? {
        if let array = raw as? [[String: Any]] { return array }
        guard let dict = raw as? [String: Any] else { return nil }
        if let code = integer(dict["code"]), code == 0, let data = dict["data"] {
            if let array = data as? [[String: Any]] { return array }
            if let nested = data as? [String: Any] {
                if let items = nested["items"] as? [[String: Any]] { return items }
                for key in ["accounts", "rows"] {
                    if let items = nested[key] as? [[String: Any]] { return items }
                }
            }
        }
        for key in ["accounts", "items", "rows"] {
            if let items = dict[key] as? [[String: Any]] { return items }
        }
        if let nested = dict["data"] as? [String: Any] {
            for key in ["accounts", "items", "rows"] {
                if let items = nested[key] as? [[String: Any]] { return items }
            }
        }
        return nil
    }

    private static func paginationInteger(in raw: Any, key: String) -> Int? {
        guard let dict = raw as? [String: Any] else { return nil }
        if let value = integer(dict[key]) { return value }
        if let data = dict["data"] as? [String: Any], let value = integer(data[key]) { return value }
        return nil
    }

    private static func findAccount(config: AccountConfig, in accounts: [[String: Any]]) -> [String: Any]? {
        if let wantedID = config.accountID, let hit = accounts.first(where: { integer($0["id"]) == wantedID }) { return hit }
        let wanted = (config.searchName ?? config.name).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !wanted.isEmpty else { return nil }
        let matches = accounts.map { account -> (account: [String: Any], fields: [String]) in
            let fields = [account["name"], account["display_name"], account["label"], account["email"]]
                .compactMap { $0 as? String }
                .map { $0.lowercased() }
            return (account, fields)
        }
        let exact = matches.filter { $0.fields.contains(wanted) }
        if exact.count == 1 { return exact[0].account }
        if exact.count > 1 { return nil }
        let partial = matches.filter { $0.fields.contains { $0.contains(wanted) } }
        return partial.count == 1 ? partial[0].account : nil
    }

    private static func accountResultFromAdminList(_ object: [String: Any], account: AccountConfig, old: AccountResult?) -> AccountResult {
        if let parsed = parseQuota(object, account: account, old: old) { return parsed }
        return withDisplayFields(
            from: account,
            AccountResult(
                name: account.name,
                displayName: account.displayName,
                abbreviation: account.abbreviation,
                remaining: nil,
                limit: nil,
                used: nil,
                unit: nil,
                window: "30d",
                status: "error",
                message: "账号列表缺少可用额度字段",
                resetAvailableCount: old?.resetAvailableCount,
                resetCreditExpirations: old?.resetCreditExpirations,
                resetMessage: old?.resetMessage,
                resetCredits: old?.resetCredits,
                resetCreditsUpdatedAt: old?.resetCreditsUpdatedAt,
                primaryWindow: old?.primaryWindow,
                secondaryWindow: old?.secondaryWindow
            )
        )
    }

    private static func fetchLegacyUsage(
        account: AccountConfig,
        old: AccountResult?,
        baseURL: String,
        apiKey: String
    ) async -> AccountResult {
        guard let url = URL(string: baseURL) else {
            return staleResult(account: account, old: old, message: safeDescription(WorkerError.invalidURL))
        }
        var request = URLRequest(url: url, timeoutInterval: requestTimeout)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let http = response as? HTTPURLResponse
            guard (200..<300).contains(http?.statusCode ?? -1) else {
                throw WorkerError.http(http?.statusCode ?? -1)
            }
            let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            let value = number(object?["remaining"]) ?? number(object?["balance"])
            guard let value else {
                return withDisplayFields(
                    from: account,
                    AccountResult(
                        name: account.name,
                        displayName: account.displayName,
                        abbreviation: account.abbreviation,
                        remaining: nil,
                        limit: nil,
                        used: nil,
                        unit: nil,
                        window: "legacy",
                        status: "error",
                        message: "需要 admin quota API",
                        resetAvailableCount: old?.resetAvailableCount,
                        resetCreditExpirations: old?.resetCreditExpirations,
                        resetMessage: old?.resetMessage,
                        resetCredits: old?.resetCredits,
                        resetCreditsUpdatedAt: old?.resetCreditsUpdatedAt,
                        primaryWindow: old?.primaryWindow,
                        secondaryWindow: old?.secondaryWindow
                    )
                )
            }
            return withDisplayFields(
                from: account,
                AccountResult(
                    name: account.name,
                    displayName: account.displayName,
                    abbreviation: account.abbreviation,
                    remaining: value,
                    limit: nil,
                    used: nil,
                    unit: object?["unit"] as? String ?? "USD",
                    window: "legacy",
                    status: "legacy",
                    message: "不是 Codex 30 天额度",
                    resetAvailableCount: old?.resetAvailableCount,
                    resetCreditExpirations: old?.resetCreditExpirations,
                    resetMessage: old?.resetMessage,
                    resetCredits: old?.resetCredits,
                    resetCreditsUpdatedAt: old?.resetCreditsUpdatedAt,
                    primaryWindow: old?.primaryWindow,
                    secondaryWindow: old?.secondaryWindow
                )
            )
        } catch {
            return staleResult(account: account, old: old, message: safeDescription(error))
        }
    }

    private static func withDisplayFields(from config: AccountConfig, _ result: AccountResult) -> AccountResult {
        let visible = config.displayName ?? config.name
        let short = config.abbreviation ?? visible
        return AccountResult(
            name: result.name,
            displayName: visible,
            abbreviation: short,
            remaining: result.remaining,
            limit: result.limit,
            used: result.used,
            unit: result.unit,
            window: result.window,
            status: result.status,
            message: result.message,
            resetAvailableCount: result.resetAvailableCount,
            resetCreditExpirations: result.resetCreditExpirations,
            resetMessage: result.resetMessage,
            resetCredits: result.resetCredits,
            resetCreditsUpdatedAt: result.resetCreditsUpdatedAt,
            primaryWindow: result.primaryWindow,
            secondaryWindow: result.secondaryWindow
        )
    }

    private static func requestData(
        url: URL,
        headers: [String: String],
        expectedStatus: Range<Int>,
        method: String = "GET"
    ) async throws -> Data {
        var lastError: Error?
        for attempt in 0...1 {
            do {
                var request = URLRequest(url: url, timeoutInterval: requestTimeout)
                request.httpMethod = method
                request.setValue("application/json", forHTTPHeaderField: "Accept")
                for (name, value) in headers where !value.isEmpty {
                    request.setValue(value, forHTTPHeaderField: name)
                }
                let (data, response) = try await URLSession.shared.data(for: request)
                let status = (response as? HTTPURLResponse)?.statusCode ?? -1
                guard expectedStatus.contains(status) else { throw WorkerError.http(status) }
                return data
            } catch {
                lastError = error
                if attempt == 1 || !isRetryable(error) { throw error }
                try? await Task.sleep(for: .milliseconds(300))
            }
        }
        throw lastError ?? WorkerError.invalidResponse("network")
    }

    private static func parseQuota(_ object: [String: Any], account: AccountConfig, old: AccountResult?) -> AccountResult? {
        let rateLimit = object["rate_limit"] as? [String: Any]
        let primaryWindow = parseRateLimitWindow(rateLimit?["primary_window"])
        let secondaryWindow = parseRateLimitWindow(rateLimit?["secondary_window"])
        let explicitLimit = number(object["quota_30d_limit"])
            ?? number(object["quota_monthly_limit"])
            ?? number(object["monthly_quota_limit"])
            ?? number(object["quota_limit"])
            ?? number(object["quota"])
        let explicitUsed = number(object["quota_30d_used"])
            ?? number(object["quota_monthly_used"])
            ?? number(object["monthly_quota_used"])
            ?? number(object["quota_used"])
        var remaining = number(object["quota_30d_remaining"])
            ?? number(object["remaining_30d"])
            ?? number(object["monthly_quota_remaining"])
            ?? number(object["quota_remaining"])
        var limit = explicitLimit
        var used = explicitUsed
        var unit = object["quota_unit"] as? String ?? "quota"
        var window = "30d"

        if remaining == nil, let limit, let used {
            remaining = max(0, limit - used)
        }
        if let primaryWindow,
           let primaryRemaining = primaryWindow.remainingPercent
                ?? primaryWindow.usedPercent.map({ max(0, 100 - $0) }) {
            limit = 100
            remaining = primaryRemaining
            used = primaryWindow.usedPercent ?? max(0, 100 - primaryRemaining)
            unit = "%"
            window = windowFromSeconds(primaryWindow.windowSeconds)
        }
        if remaining == nil,
           let extra = object["extra"] as? [String: Any],
           let usedPercent = number(extra["codex_primary_used_percent"]) ?? number(extra["codex_7d_used_percent"]) {
            limit = 100
            used = usedPercent
            remaining = max(0, 100 - usedPercent)
            unit = "%"
            window = windowFromMinutes(number(extra["codex_primary_window_minutes"]) ?? number(extra["codex_7d_window_minutes"]))
        }
        guard let remaining else { return nil }

        let resetInfo = parseResetInfo(object)
        // The quota payload may contain only a count (no expires_at details) for
        // rate_limit_reset_credits. Official detail objects come from the bridge
        // merge later in the run. Retain cached bridge objects only while the live
        // payload has no fresher detail and its count is still compatible with the
        // cached objects. If the live payload already includes expirations, prefer
        // those over old credit objects if the bridge merge later fails.
        let hasLiveCreditDetails = resetInfo.expirations?.isEmpty == false
        let countStillCompatible = resetInfo.count == nil || old?.resetAvailableCount == resetInfo.count
        let retainCachedOfficialCredits = countStillCompatible && !hasLiveCreditDetails
        return AccountResult(
            name: account.name,
            displayName: account.displayName ?? account.name,
            abbreviation: account.abbreviation ?? account.displayName ?? account.name,
            remaining: remaining,
            limit: limit,
            used: used,
            unit: unit,
            window: window,
            status: "ok",
            message: nil,
            resetAvailableCount: resetInfo.count ?? old?.resetAvailableCount,
            resetCreditExpirations: retainCachedOfficialCredits
                ? (resetInfo.expirations ?? old?.resetCreditExpirations)
                : resetInfo.expirations,
            resetMessage: retainCachedOfficialCredits
                ? (resetInfo.message ?? old?.resetMessage)
                : resetInfo.message,
            resetCredits: retainCachedOfficialCredits ? old?.resetCredits : nil,
            resetCreditsUpdatedAt: retainCachedOfficialCredits ? old?.resetCreditsUpdatedAt : nil,
            primaryWindow: primaryWindow ?? old?.primaryWindow,
            secondaryWindow: secondaryWindow ?? old?.secondaryWindow
        )
    }

    private static func parseRateLimitWindow(_ value: Any?) -> RateLimitWindow? {
        guard let object = value as? [String: Any] else { return nil }
        let usedPercent = number(object["used_percent"]) ?? number(object["usedPercent"])
        let remainingPercent = number(object["remaining_percent"])
            ?? number(object["remainingPercent"])
            ?? usedPercent.map { max(0, 100 - $0) }
        let windowSeconds = number(object["limit_window_seconds"])
            ?? number(object["window_seconds"])
            ?? number(object["windowSeconds"])
        let resetAt = parseRateLimitResetAt(object["reset_at"])
            ?? parseRateLimitResetAt(object["resetAt"])
        let resetAfterSeconds = number(object["reset_after_seconds"])
            ?? number(object["resetAfterSeconds"])
        guard usedPercent != nil
            || remainingPercent != nil
            || windowSeconds != nil
            || resetAt != nil
            || resetAfterSeconds != nil else { return nil }
        return RateLimitWindow(
            usedPercent: usedPercent,
            remainingPercent: remainingPercent,
            windowSeconds: windowSeconds,
            resetAt: resetAt,
            resetAfterSeconds: resetAfterSeconds
        )
    }

    private static func parseRateLimitResetAt(_ value: Any?) -> String? {
        if let string = value as? String {
            return string
        }
        guard let seconds = number(value), seconds.isFinite else { return nil }
        return iso8601String(Date(timeIntervalSince1970: seconds))
    }

    private static func staleResult(account: AccountConfig, old: AccountResult?, message: String) -> AccountResult {
        AccountResult(
            name: account.name,
            displayName: account.displayName ?? old?.displayName ?? account.name,
            abbreviation: account.abbreviation ?? old?.abbreviation ?? account.name,
            remaining: old?.remaining,
            limit: old?.limit,
            used: old?.used,
            unit: old?.unit,
            window: old?.window ?? "30d",
            status: old == nil ? "error" : "stale",
            message: "Background refresh failed; cached values retained: \(message)",
            resetAvailableCount: old?.resetAvailableCount,
            resetCreditExpirations: old?.resetCreditExpirations,
            resetMessage: old?.resetMessage,
            resetCredits: old?.resetCredits,
            resetCreditsUpdatedAt: old?.resetCreditsUpdatedAt,
            primaryWindow: old?.primaryWindow,
            secondaryWindow: old?.secondaryWindow,
            resolvedAccountID: old?.resolvedAccountID ?? account.accountID
        )
    }

    private static func parseResetInfo(_ object: [String: Any]) -> (count: Int?, expirations: [String]?, message: String?) {
        guard let raw = object["rate_limit_reset_credits"] as? [String: Any] else { return (nil, nil, nil) }
        let count = integer(raw["available_count"])
        let credits = raw["credits"] as? [[String: Any]] ?? []
        let expirations = credits.compactMap { credit -> String? in
            guard (credit["status"] as? String) == nil || (credit["status"] as? String) == "available" else { return nil }
            return credit["expires_at"] as? String
        }.sorted()
        if !expirations.isEmpty { return (count ?? expirations.count, expirations, nil) }
        if let count, count > 0 { return (count, nil, "reset credits have no expiration details") }
        return (count, count == nil ? nil : [], nil)
    }

    private static func deliverDueMessages(
        outbox: inout Outbox,
        config: WorkerConfig,
        forcedEventID: UUID?,
        processOnlyForcedEvent: Bool = false
    ) async -> DeliveryReport {
        var report = DeliveryReport()
        var receipts: ReceiptStore
        do {
            receipts = try loadReceipts()
        } catch {
            report.storageWarnings += 1
            report.noteIssue("receipt_store_unreadable")
            appendLog(level: "error", event: "clickup_delivery_blocked", fields: ["reason": safeDescription(error)])
            return report
        }

        var alreadyDelivered: [UUID: String] = [:]
        for receipt in receipts.receipts {
            guard alreadyDelivered[receipt.eventID] == nil else {
                report.storageWarnings += 1
                report.noteIssue("receipt_store_invalid")
                appendLog(level: "error", event: "clickup_delivery_blocked", fields: ["reason": "receipt_store_invalid"])
                return report
            }
            alreadyDelivered[receipt.eventID] = receipt.messageID
        }

        // Test messages are transient and must never be sent by ordinary runs,
        // nor by a later test that has already failed or been abandoned.
        let abandonedTestIDs = outbox.items.filter { item in
            item.kind == "test" && (!processOnlyForcedEvent || item.id != forcedEventID)
        }.map(\.id)
        if !abandonedTestIDs.isEmpty {
            outbox.items.removeAll { abandonedTestIDs.contains($0.id) }
            do {
                try saveOutbox(outbox)
            } catch {
                report.storageWarnings += 1
                report.noteIssue("test_outbox_cleanup_not_persisted")
                appendLog(level: "error", event: "clickup_delivery_blocked", fields: ["reason": safeDescription(error)])
                return report
            }
        }

        let deliveryCandidates = processOnlyForcedEvent
            ? outbox.items.filter { $0.id == forcedEventID }
            : outbox.items.filter { $0.kind != "test" }

        let completedEventIDs = Set(deliveryCandidates.compactMap { item -> UUID? in
            guard let messageID = alreadyDelivered[item.id] else { return nil }
            report.delivered[item.id] = messageID
            if let channelID = receipts.receipts.first(where: { $0.eventID == item.id })?.channelID {
                report.deliveredChannels[item.id] = channelID
            }
            return item.id
        })
        if !completedEventIDs.isEmpty {
            outbox.items.removeAll { completedEventIDs.contains($0.id) }
            do {
                try saveOutbox(outbox)
            } catch {
                report.storageWarnings += 1
                report.noteIssue("outbox_cleanup_not_persisted")
                appendLog(level: "error", event: "clickup_delivery_blocked", fields: ["reason": safeDescription(error)])
                return report
            }
        }

        let snapshot = deliveryCandidates
        for snapshotItem in snapshot {
            guard snapshotItem.nextAttemptAt <= Date() || snapshotItem.id == forcedEventID else { continue }
            guard let index = outbox.items.firstIndex(where: { $0.id == snapshotItem.id }) else { continue }

            if outbox.items[index].deliveryState == "accepted",
               let messageID = outbox.items[index].acceptedMessageID,
               let channelID = outbox.items[index].acceptedChannelID {
                if settleAcceptedItem(
                    eventID: snapshotItem.id,
                    messageID: messageID,
                    channelID: channelID,
                    outbox: &outbox,
                    receipts: &receipts,
                    report: &report
                ) {
                    report.delivered[snapshotItem.id] = messageID
                    report.deliveredChannels[snapshotItem.id] = channelID
                }
                continue
            }

            // An earlier process persisted intent to POST but stopped before it
            // could record whether ClickUp accepted it. Retrying would risk a
            // duplicate user-visible message, so leave it for investigation.
            if outbox.items[index].deliveryState == "inflight" {
                report.uncertain += 1
                report.noteIssue("delivery_outcome_uncertain")
                appendLog(level: "error", event: "clickup_delivery_uncertain", fields: [
                    "kind": outbox.items[index].kind,
                    "event_id": outbox.items[index].id.uuidString
                ])
                continue
            }

            do {
                try validateClickUpDestination(config)
            } catch {
                deferUnsentItem(
                    at: index,
                    because: error,
                    outbox: &outbox,
                    report: &report
                )
                continue
            }

            let previousDeliveryState = outbox.items[index].deliveryState
            let previousAttemptStartedAt = outbox.items[index].attemptStartedAt
            let previousAcceptedMessageID = outbox.items[index].acceptedMessageID
            let previousAcceptedChannelID = outbox.items[index].acceptedChannelID
            outbox.items[index].deliveryState = "inflight"
            outbox.items[index].attemptStartedAt = Date()
            outbox.items[index].acceptedMessageID = nil
            outbox.items[index].acceptedChannelID = nil
            do {
                try saveOutbox(outbox)
            } catch {
                // Restore the in-memory item before processing anything else;
                // otherwise a later successful save for another item would
                // persist an inflight marker for a POST that was never attempted.
                outbox.items[index].deliveryState = previousDeliveryState
                outbox.items[index].attemptStartedAt = previousAttemptStartedAt
                outbox.items[index].acceptedMessageID = previousAcceptedMessageID
                outbox.items[index].acceptedChannelID = previousAcceptedChannelID
                report.storageWarnings += 1
                report.noteIssue("outbox_send_intent_not_persisted")
                appendLog(level: "error", event: "clickup_delivery_blocked", fields: ["reason": safeDescription(error)])
                continue
            }

            do {
                let messageID = try await sendClickUp(outbox.items[index].content, config: config)
                let channelID = trimmed(config.clickup?.channelId) ?? "unknown"
                outbox.items[index].deliveryState = "accepted"
                outbox.items[index].acceptedMessageID = messageID
                outbox.items[index].acceptedChannelID = channelID

                do {
                    try saveOutbox(outbox)
                } catch {
                    // The accepted state could not be persisted, but ClickUp has
                    // already returned a receipt. Persist that receipt through the
                    // normal settle path so a later run can reconcile and clean up
                    // the old inflight on-disk item instead of freezing forever.
                    if settleAcceptedItem(
                        eventID: snapshotItem.id,
                        messageID: messageID,
                        channelID: channelID,
                        outbox: &outbox,
                        receipts: &receipts,
                        report: &report
                    ) {
                        report.delivered[snapshotItem.id] = messageID
                        report.deliveredChannels[snapshotItem.id] = channelID
                    }
                    report.storageWarnings += 1
                    report.noteIssue("accepted_delivery_not_persisted")
                    appendLog(level: "error", event: "clickup_delivery_uncertain", fields: [
                        "kind": snapshotItem.kind,
                        "event_id": snapshotItem.id.uuidString,
                        "reason": safeDescription(WorkerError.acceptanceRecordNotPersisted)
                    ])
                    continue
                }

                if settleAcceptedItem(
                    eventID: snapshotItem.id,
                    messageID: messageID,
                    channelID: channelID,
                    outbox: &outbox,
                    receipts: &receipts,
                    report: &report
                ) {
                    report.delivered[snapshotItem.id] = messageID
                    report.deliveredChannels[snapshotItem.id] = channelID
                }
            } catch {
                guard let retryIndex = outbox.items.firstIndex(where: { $0.id == snapshotItem.id }) else { continue }
                if isDefinitivePreSendError(error) {
                    // The request never left this process (offline, DNS/TCP/TLS
                    // failure), so it is safe to clear inflight and retry later.
                    deferUnsentItem(
                        at: retryIndex,
                        because: error,
                        outbox: &outbox,
                        report: &report
                    )
                    continue
                }
                guard isDefinitivelyRejectedByClickUp(error) else {
                    // A timeout, connection reset, or malformed success response
                    // leaves the server-side outcome unknown. The persisted
                    // inflight marker deliberately blocks an automatic replay.
                    report.uncertain += 1
                    report.noteIssue("delivery_outcome_uncertain")
                    appendLog(level: "error", event: "clickup_delivery_uncertain", fields: [
                        "kind": outbox.items[retryIndex].kind,
                        "event_id": outbox.items[retryIndex].id.uuidString,
                        "reason": safeDescription(error)
                    ])
                    continue
                }
                deferUnsentItem(
                    at: retryIndex,
                    because: error,
                    outbox: &outbox,
                    report: &report
                )
            }
        }
        return report
    }

    private static func deferUnsentItem(
        at index: Int,
        because error: Error,
        outbox: inout Outbox,
        report: inout DeliveryReport
    ) {
        outbox.items[index].attempts += 1
        let delay = min(3_600.0, 60.0 * pow(2.0, Double(min(outbox.items[index].attempts - 1, 6))))
        outbox.items[index].nextAttemptAt = Date().addingTimeInterval(delay)
        outbox.items[index].lastError = safeDescription(error)
        outbox.items[index].deliveryState = nil
        outbox.items[index].attemptStartedAt = nil
        outbox.items[index].acceptedMessageID = nil
        outbox.items[index].acceptedChannelID = nil
        do {
            try saveOutbox(outbox)
            report.deferred += 1
            report.noteIssue("clickup_delivery_deferred")
            appendLog(level: "error", event: "clickup_deferred", fields: [
                "kind": outbox.items[index].kind,
                "event_id": outbox.items[index].id.uuidString,
                "attempt": String(outbox.items[index].attempts),
                "reason": safeDescription(error)
            ])
        } catch {
            // The persisted state remains inflight, which intentionally blocks
            // automatic duplicate delivery on the next run.
            report.uncertain += 1
            report.storageWarnings += 1
            report.noteIssue("retry_state_not_persisted")
            appendLog(level: "error", event: "clickup_delivery_uncertain", fields: ["reason": safeDescription(error)])
        }
    }

    private static func settleAcceptedItem(
        eventID: UUID,
        messageID: String,
        channelID: String,
        outbox: inout Outbox,
        receipts: inout ReceiptStore,
        report: inout DeliveryReport
    ) -> Bool {
        guard let index = outbox.items.firstIndex(where: { $0.id == eventID }) else { return false }
        let item = outbox.items[index]
        if !receipts.receipts.contains(where: { $0.eventID == eventID }) {
            receipts.receipts.append(DeliveryReceipt(
                eventID: eventID,
                kind: item.kind,
                messageID: messageID,
                deliveredAt: Date(),
                channelID: channelID
            ))
            if receipts.receipts.count > 100 {
                receipts.receipts.removeFirst(receipts.receipts.count - 100)
            }
            do {
                try saveReceipts(receipts)
            } catch {
                report.uncertain += 1
                report.storageWarnings += 1
                report.noteIssue("accepted_receipt_not_persisted")
                appendLog(level: "error", event: "clickup_delivery_uncertain", fields: [
                    "kind": item.kind,
                    "event_id": item.id.uuidString,
                    "reason": safeDescription(WorkerError.acceptanceRecordNotPersisted)
                ])
                return false
            }
        }

        outbox.items.removeAll { $0.id == eventID }
        do {
            try saveOutbox(outbox)
        } catch {
            // The durable receipt prevents a duplicate POST; the next worker
            // run will only remove this already-delivered outbox entry.
            report.storageWarnings += 1
            report.noteIssue("outbox_cleanup_not_persisted")
            appendLog(level: "error", event: "clickup_delivery_cleanup_deferred", fields: [
                "kind": item.kind,
                "event_id": item.id.uuidString,
                "reason": safeDescription(error)
            ])
            return true
        }
        appendLog(level: "info", event: "clickup_delivered", fields: [
            "kind": item.kind,
            "event_id": item.id.uuidString,
            "has_receipt": "true"
        ])
        return true
    }

    private static func sendClickUp(_ content: String, config: WorkerConfig) async throws -> String {
        let destination = try clickUpDestination(config)
        let apiKey = destination.apiKey
        let url = destination.url

        let body: [String: String] = [
            "type": "message",
            "content": content,
            "content_format": "text/plain"
        ]
        var request = URLRequest(url: url, timeoutInterval: requestTimeout)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard status == 201 else { throw WorkerError.http(status) }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let messageID = stringIdentifier(object["id"]) else {
            throw WorkerError.invalidResponse("ClickUp message receipt")
        }
        return messageID
    }

    private static func validateClickUpDestination(_ config: WorkerConfig) throws {
        _ = try clickUpDestination(config)
    }

    private static func clickUpDestination(_ config: WorkerConfig) throws -> (apiKey: String, channelID: String, url: URL) {
        guard let clickup = config.clickup,
              let apiKey = trimmed(clickup.apiKey),
              let workspaceID = trimmed(clickup.workspaceId),
              let channelID = trimmed(clickup.channelId) else {
            throw WorkerError.missingClickUpConfiguration
        }
        guard let url = URL(string: "https://api.clickup.com/api/v3/workspaces/\(workspaceID)/chat/channels/\(channelID)/messages") else {
            throw WorkerError.invalidURL
        }
        return (apiKey, channelID, url)
    }

    private static func loadOutbox() throws -> Outbox {
        guard FileManager.default.fileExists(atPath: outboxURL.path) else { return Outbox() }
        do {
            let data = try Data(contentsOf: outboxURL)
            let value = try decode(Outbox.self, from: data)
            guard value.version == 1 else { throw WorkerError.unreadableOutbox }
            var eventIDs = Set<UUID>()
            for item in value.items {
                guard eventIDs.insert(item.id).inserted else { throw WorkerError.unreadableOutbox }
                guard !item.kind.isEmpty, !item.content.isEmpty else { throw WorkerError.unreadableOutbox }
            }
            return value
        } catch {
            throw WorkerError.unreadableOutbox
        }
    }

    private static func saveOutbox(_ outbox: Outbox) throws {
        try atomicWrite(encode(outbox), to: outboxURL, permissions: 0o600)
    }

    private static func loadReceipts() throws -> ReceiptStore {
        guard FileManager.default.fileExists(atPath: receiptsURL.path) else { return ReceiptStore() }
        do {
            let data = try Data(contentsOf: receiptsURL)
            let value = try decode(ReceiptStore.self, from: data)
            guard value.version == 1 else { throw WorkerError.unreadableReceipts }
            var eventIDs = Set<UUID>()
            for receipt in value.receipts {
                guard eventIDs.insert(receipt.eventID).inserted,
                      !receipt.messageID.isEmpty,
                      !receipt.channelID.isEmpty else {
                    throw WorkerError.unreadableReceipts
                }
            }
            return value
        } catch {
            throw WorkerError.unreadableReceipts
        }
    }

    private static func saveReceipts(_ receipts: ReceiptStore) throws {
        try atomicWrite(encode(receipts), to: receiptsURL, permissions: 0o600)
    }

    private static func writeStatus(
        state: String,
        detail: String,
        mode: String,
        startedAt: Date,
        outbox: Outbox?,
        summary: RefreshSummary,
        lastMessageID: String?
    ) throws {
        let now = Date()
        let status = WorkerStatus(
            state: state,
            detail: detail,
            mode: mode,
            runStartedAt: startedAt,
            runFinishedAt: now,
            updatedAt: now,
            outboxPending: outbox?.items.count,
            refreshedAccounts: summary.refreshed,
            failedAccounts: summary.failed,
            queuedMessages: summary.queued,
            lastClickUpMessageID: lastMessageID,
            autoRestoredAccounts: summary.autoRestored,
            autoRestoreFailedAccounts: summary.autoRestoreFailed,
            pendingAutoRestores: summary.pendingAutoRestores
        )
        try atomicWrite(encode(status), to: statusURL, permissions: 0o600)
    }

    private static func writeTestResult(
        eventID: UUID,
        state: String,
        detail: String,
        messageID: String?,
        channelID: String?
    ) throws {
        let result = ClickUpTestResult(
            version: 1,
            eventID: eventID,
            state: state,
            detail: detail,
            completedAt: Date(),
            messageID: messageID,
            channelID: channelID
        )
        try atomicWrite(encode(result), to: testResultURL, permissions: 0o600)
    }

    private static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(value)
    }

    private static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let value = try container.decode(String.self)
            if let date = parseISO8601(value) {
                return date
            }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "invalid ISO8601 date")
        }
        return try decoder.decode(type, from: data)
    }

    private static func atomicWrite(_ data: Data, to url: URL, permissions: Int) throws {
        try prepareConfigurationDirectory()
        try data.write(to: url, options: .atomic)
        restrictPermissions(of: url, to: permissions)
    }

    private static func prepareConfigurationDirectory() throws {
        try FileManager.default.createDirectory(at: configDirectory, withIntermediateDirectories: true)
        restrictPermissions(of: configDirectory, to: 0o700)
    }

    private static var isLegacyCompatibilityConfigURL: Bool {
        let candidate = configURL.standardizedFileURL
        let legacyDirectory = OpenClawWidgetPaths.legacyDirectory.standardizedFileURL
        guard candidate.deletingLastPathComponent() == legacyDirectory else { return false }
        return candidate.lastPathComponent == OpenClawWidgetPaths.configFileName
            || candidate.lastPathComponent == OpenClawWidgetPaths.legacyConfigFileName
    }

    private static func restrictPermissions(of url: URL, to permissions: Int) {
        try? FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: url.path)
    }

    private static func testEventID(arguments: [String], mode: String) throws -> UUID? {
        guard mode == "test-clickup" else { return nil }
        guard let position = arguments.firstIndex(of: "--event-id"),
              arguments.indices.contains(arguments.index(after: position)),
              let eventID = UUID(uuidString: arguments[arguments.index(after: position)]) else {
            throw WorkerError.invalidTestEventID
        }
        return eventID
    }

    private static func deliveryDetail(outbox: Outbox, report: DeliveryReport) -> String {
        var parts = ["ClickUp delivery deferred", "pending=\(outbox.items.count)"]
        if report.deferred > 0 { parts.append("deferred=\(report.deferred)") }
        if report.uncertain > 0 { parts.append("uncertain=\(report.uncertain)") }
        if report.storageWarnings > 0 { parts.append("storage=\(report.storageWarnings)") }
        if let issue = report.issue { parts.append("issue=\(issue)") }
        return parts.joined(separator: "; ")
    }

    private static func adminRoutes(_ configured: String?) throws -> [String] {
        guard let configured = trimmed(configured) else { throw WorkerError.missingAdminBaseURL }
        let selected = normalizeBaseURL(configured)
        guard let url = URL(string: selected),
              let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = url.host, !host.isEmpty else {
            throw WorkerError.invalidAdminBaseURL
        }
        return [selected]
    }

    private static func normalizeBaseURL(_ value: String) -> String {
        value.replacingOccurrences(of: "/v1/usage", with: "")
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "/")))
    }

    private static func unwrapDictionary(_ raw: Any) -> [String: Any]? {
        guard let object = raw as? [String: Any] else { return nil }
        if let code = integer(object["code"]), code == 0, let data = object["data"] as? [String: Any] {
            return data
        }
        return object
    }

    private static func number(_ value: Any?) -> Double? {
        if let number = value as? NSNumber { return number.doubleValue }
        if let string = value as? String { return Double(string) }
        return nil
    }

    private static func integer(_ value: Any?) -> Int? {
        if let number = value as? NSNumber { return number.intValue }
        if let string = value as? String { return Int(string) }
        return nil
    }

    private static func trimmed(_ value: String?) -> String? {
        guard let value else { return nil }
        let result = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return result.isEmpty ? nil : result
    }

    private static func stringIdentifier(_ value: Any?) -> String? {
        if let value = value as? String, !value.isEmpty { return value }
        if let value = value as? NSNumber { return value.stringValue }
        return nil
    }

    private static func isRetryable(_ error: Error) -> Bool {
        if error is URLError { return true }
        if case WorkerError.http(let code) = error { return code == 408 || code == 429 || code >= 500 }
        return false
    }

    private static func shouldTryAlternateRoute(after error: Error) -> Bool {
        if case WorkerError.invalidResponse = error { return true }
        return isRetryable(error)
    }

    private static func isDefinitivePreSendError(_ error: Error) -> Bool {
        if let urlError = error as? URLError {
            switch urlError.code {
            case .unsupportedURL,
                 .badURL,
                 .notConnectedToInternet,
                 .cannotFindHost,
                 .cannotConnectToHost,
                 .dnsLookupFailed,
                 .dataNotAllowed,
                 .internationalRoamingOff,
                 .callIsActive,
                 .cannotLoadFromNetwork,
                 .appTransportSecurityRequiresSecureConnection,
                 .secureConnectionFailed,
                 .serverCertificateHasBadDate,
                 .serverCertificateUntrusted,
                 .serverCertificateHasUnknownRoot,
                 .serverCertificateNotYetValid,
                 .clientCertificateRejected,
                 .clientCertificateRequired:
                return true
            default:
                return false
            }
        }
        if case WorkerError.missingClickUpConfiguration = error { return true }
        if case WorkerError.invalidURL = error { return true }
        return false
    }

    private static func isDefinitivelyRejectedByClickUp(_ error: Error) -> Bool {
        guard case WorkerError.http(let code) = error else { return false }
        // Only ordinary 4xx responses are definitive pre-processing rejections.
        // A 408 or any 5xx can be returned after ClickUp (or an upstream gateway)
        // has already created the message, so those outcomes must stay inflight.
        return (400...499).contains(code) && code != 408
    }

    private static func windowFromSeconds(_ value: Double?) -> String {
        guard let value else { return "30d" }
        if value >= 2_500_000 { return "30d" }
        if value >= 500_000 { return "7d" }
        if value >= 18_000 { return "5h" }
        return "\(Int(value))s"
    }

    private static func windowFromMinutes(_ value: Double?) -> String {
        guard let value else { return "30d" }
        if value >= 43_000 { return "30d" }
        if value >= 10_000 { return "7d" }
        if value >= 300 { return "5h" }
        return "\(Int(value))m"
    }

    private static func formatQuota(_ value: Double, unit: String?) -> String {
        let number = value.formatted(.number.precision(.fractionLength(0...2)))
        guard let unit, !unit.isEmpty, unit != "quota" else { return number }
        return "\(number) \(unit)"
    }

    private static func safeDescription(_ error: Error) -> String {
        if let workerError = error as? WorkerError {
            switch workerError {
            case .http(let code): return "http_\(code)"
            case .allRoutesFailed: return "all_routes_failed"
            case .invalidResponse: return "invalid_response"
            case .missingAdminToken: return "missing_admin_token"
            case .missingAdminBaseURL: return "missing_admin_base_url"
            case .invalidAdminBaseURL: return "invalid_admin_base_url"
            case .missingAccountID: return "missing_account_id"
            case .emptyAccounts: return "empty_accounts"
            case .missingClickUpConfiguration: return "missing_clickup_configuration"
            case .invalidURL: return "invalid_url"
            case .lockBusy: return "lock_busy"
            case .lockUnavailable: return "lock_unavailable"
            case .unreadableOutbox: return "unreadable_outbox"
            case .unreadableReceipts: return "unreadable_receipts"
            case .invalidTestEventID: return "invalid_test_event_id"
            case .testMessageNotDelivered: return "test_message_not_delivered"
            case .acceptanceRecordNotPersisted: return "acceptance_record_not_persisted"
            }
        }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .timedOut: return "network_timeout"
            case .notConnectedToInternet: return "network_offline"
            case .cannotConnectToHost: return "network_connect_failed"
            case .cannotFindHost: return "network_host_unavailable"
            case .networkConnectionLost: return "network_connection_lost"
            case .cancelled: return "network_cancelled"
            default: return "network_error"
            }
        }
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain { return "file_io_error" }
        return "operation_failed"
    }

    private static func rotateLogIfNeeded() {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: logURL.path),
              let size = attributes[.size] as? NSNumber, size.intValue >= 512 * 1024 else { return }
        let backupURL = logURL.appendingPathExtension("1")
        try? FileManager.default.removeItem(at: backupURL)
        try? FileManager.default.moveItem(at: logURL, to: backupURL)
    }

    private static func appendLog(level: String, event: String, fields: [String: String]) {
        var record = fields
        record["timestamp"] = iso8601String(Date())
        record["level"] = level
        record["event"] = event
        guard let data = try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]),
              var line = String(data: data, encoding: .utf8) else { return }
        line.append("\n")
        let bytes = Data(line.utf8)
        if !FileManager.default.fileExists(atPath: logURL.path) {
            try? bytes.write(to: logURL, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: logURL.path)
            return
        }
        guard let handle = try? FileHandle(forWritingTo: logURL) else { return }
        defer { try? handle.close() }
        do {
            try handle.seekToEnd()
            try handle.write(contentsOf: bytes)
        } catch {
            return
        }
    }

    private static func iso8601String(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    private static func parseISO8601(_ value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: value) { return date }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }
}
