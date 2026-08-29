import SwiftUI
import WidgetKit
import AppKit

struct ResetCredit: Codable, Identifiable, Sendable {
    var id: String { "\(status ?? "unknown")-\(expiresAt ?? grantedAt ?? "")" }
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

struct RateLimitWindow: Codable, Sendable {
    let usedPercent: Double?
    let remainingPercent: Double?
    let windowSeconds: Double?
    let resetAt: String?
    let resetAfterSeconds: Double?
}

struct BalanceAccountResult: Codable, Identifiable, Sendable {
    var id: String { name }
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
    let primaryWindow: RateLimitWindow?
    let secondaryWindow: RateLimitWindow?
    let resetAvailableCount: Int?
    let resetCreditExpirations: [String]?
    let resetMessage: String?
    let resetCredits: [ResetCredit]?
    let resetCreditsUpdatedAt: Date?

    // Sub2API 调度状态（worker 刷新时写入；旧缓存缺失时保持 nil）。
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

    init(name: String, remaining: Double?, limit: Double?, used: Double?, unit: String?, window: String?, status: String, message: String?, resetAvailableCount: Int? = nil, resetCreditExpirations: [String]? = nil, resetMessage: String? = nil, resetCredits: [ResetCredit]? = nil, resetCreditsUpdatedAt: Date? = nil, displayName: String? = nil, abbreviation: String? = nil, primaryWindow: RateLimitWindow? = nil, secondaryWindow: RateLimitWindow? = nil) {
        self.name = name
        self.displayName = displayName
        self.abbreviation = abbreviation
        self.remaining = remaining
        self.limit = limit
        self.used = used
        self.unit = unit
        self.window = window
        self.status = status
        self.message = message
        self.primaryWindow = primaryWindow
        self.secondaryWindow = secondaryWindow
        self.resetAvailableCount = resetAvailableCount
        self.resetCreditExpirations = resetCreditExpirations
        self.resetMessage = resetMessage
        self.resetCredits = resetCredits
        self.resetCreditsUpdatedAt = resetCreditsUpdatedAt
    }
}

private extension BalanceAccountResult {
    var displayPrimaryWindow: RateLimitWindow? {
        guard let primaryWindow else { return legacyPrimaryWindow }
        guard let legacy = legacyPrimaryWindow else { return primaryWindow }
        return RateLimitWindow(
            usedPercent: primaryWindow.usedPercent ?? legacy.usedPercent,
            remainingPercent: primaryWindow.remainingPercent ?? legacy.remainingPercent,
            windowSeconds: primaryWindow.windowSeconds ?? legacy.windowSeconds,
            resetAt: primaryWindow.resetAt ?? legacy.resetAt,
            resetAfterSeconds: primaryWindow.resetAfterSeconds ?? legacy.resetAfterSeconds
        )
    }

    var legacyPrimaryWindow: RateLimitWindow? {
        guard let remaining else { return nil }

        let remainingPercent: Double
        let usedPercent: Double?
        if unit == "%" {
            remainingPercent = remaining
            usedPercent = used.map { max(0, min(100, $0)) } ?? max(0, min(100, 100 - remaining))
        } else if let limit, limit > 0 {
            remainingPercent = remaining / limit * 100
            usedPercent = used.map { $0 / limit * 100 } ?? (100 - remainingPercent)
        } else {
            return nil
        }

        return RateLimitWindow(
            usedPercent: usedPercent.map { max(0, min(100, $0)) },
            remainingPercent: max(0, min(100, remainingPercent)),
            windowSeconds: legacyWindowSeconds,
            resetAt: nil,
            resetAfterSeconds: nil
        )
    }

    private var legacyWindowSeconds: Double? {
        guard let window = window?.lowercased() else { return nil }
        if window == "5h" { return 18_000 }
        if window == "7d" { return 604_800 }
        if window == "30d" { return 2_592_000 }
        if window.hasSuffix("h"), let hours = Double(window.dropLast()) { return hours * 3_600 }
        if window.hasSuffix("d"), let days = Double(window.dropLast()) { return days * 86_400 }
        if window.hasSuffix("m"), let minutes = Double(window.dropLast()) { return minutes * 60 }
        if window.hasSuffix("s"), let seconds = Double(window.dropLast()) { return seconds }
        return nil
    }
}

private struct QuotaWindowRow: View {
    let title: String
    let window: RateLimitWindow?
    let fallbackTint: Color
    let cachedUpdatedAt: Date?

    private var remainingPercent: Double? {
        guard let window else { return nil }
        return window.remainingPercent ?? window.usedPercent.map { 100 - $0 }
    }

    private var progress: Double {
        guard let remainingPercent else { return 0 }
        return max(0, min(1, remainingPercent / 100))
    }

    private var tint: Color {
        guard let remainingPercent else { return fallbackTint }
        if remainingPercent >= 65 { return .green }
        if remainingPercent >= 28 { return .orange }
        return .red
    }

    private var percentText: String {
        guard let remainingPercent else { return "--" }
        return remainingPercent.formatted(.number.precision(.fractionLength(0...1))) + "%"
    }

    private var resetDate: Date? {
        guard let window else { return nil }
        if let resetAt = window.resetAt, let date = parseResetDate(resetAt) {
            return date
        }
        guard let resetAfterSeconds = window.resetAfterSeconds,
              let cachedUpdatedAt else { return nil }
        return cachedUpdatedAt.addingTimeInterval(resetAfterSeconds)
    }

    private var resetText: String {
        guard let resetDate else { return "--" }
        let dateStyle: Date.FormatStyle.DateStyle = isSevenDayWindow ? .abbreviated : .omitted
        return resetDate.formatted(date: dateStyle, time: .shortened)
    }

    private var isSevenDayWindow: Bool {
        (window?.windowSeconds ?? 0) >= 604_800
    }

    private func parseResetDate(_ value: String) -> Date? {
        if let date = ISO8601DateFormatter.openClaw.date(from: value)
            ?? ISO8601DateFormatter.openClawNoFraction.date(from: value) {
            return date
        }
        if let seconds = Double(value) {
            return Date(timeIntervalSince1970: seconds)
        }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                    .font(.callout.weight(.semibold))
                Spacer()
                Text("剩余 \(percentText)")
                    .font(.callout.weight(.bold))
                    .monospacedDigit()
                    .foregroundStyle(tint)
            }
            ProgressView(value: progress)
                .progressViewStyle(.linear)
                .tint(tint)
            Text("重置：\(resetText)")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }
}

struct BalanceWidgetData: Codable {
    let updatedAt: Date
    let source: String
    let widgetURL: String
    let accounts: [BalanceAccountResult]
}

@MainActor
final class BalanceViewModel: ObservableObject {
    @Published var isRefreshing = false
    @Published var status = "就绪"
    @Published var results: [BalanceAccountResult] = []
    @Published var updatedAt: Date?
    @Published var backgroundWorkerStatus = "正在读取后台刷新状态…"
    @Published var backgroundWorkerState = "unknown"
    @Published var isTestingClickUp = false
    @Published var isRestoringStatus = false
    @Published private(set) var configuration: OpenClawWidgetConfiguration?

    private static var paths: OpenClawWidgetPaths { OpenClawWidgetPaths(configURL: OpenClawWidgetPaths.resolveConfigURL()) }
    private static var workerStatusPath: URL { paths.statusURL }
    private static var clickUpTestResultPath: URL { paths.testResultURL }
    private static var workerExecutableURL: URL? {
        let bundled = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/Sub2APIRefreshWorker")
        return FileManager.default.isExecutableFile(atPath: bundled.path) ? bundled : nil
    }

    init() {
        configuration = OpenClawWidgetPaths.load()
        loadCachedData()
        loadBackgroundWorkerStatus()
    }

    func loadCachedData() {
        let url = Self.widgetDataURL()
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder.openClaw.decode(BalanceWidgetData.self, from: data) else { return }
        results = decoded.accounts
        updatedAt = decoded.updatedAt
        status = "已载入本地小组件数据"
    }

    func runBackgroundRefreshNow() async {
        guard !isRefreshing, !isTestingClickUp, !isRestoringStatus else { return }
        isRefreshing = true
        status = "正在请求后台 worker 刷新…"
        defer { isRefreshing = false }

        do {
            var terminationStatus: Int32 = 75
            for attempt in 0..<5 {
                terminationStatus = try await Self.runWorker(arguments: ["--run-once"])
                if terminationStatus != 75 { break }
                if attempt < 4 {
                    status = "后台已有刷新在进行，等待其完成…"
                    try? await Task.sleep(nanoseconds: 4_000_000_000)
                }
            }
            loadCachedData()
            loadBackgroundWorkerStatus()
            WidgetCenter.shared.reloadAllTimelines()
            switch terminationStatus {
            case 0:
                status = "后台 worker 已完成刷新"
            case 75:
                status = "后台刷新仍在进行，稍后会自动更新"
            default:
                let object = workerStatusObject()
                let state = object?["state"] as? String
                let detail = object?["detail"] as? String
                let failedAccounts = (object?["failedAccounts"] as? NSNumber)?.intValue ?? 0
                let autoRestoreFailed = (object?["autoRestoreFailedAccounts"] as? NSNumber)?.intValue ?? 0
                let pendingAutoRestores = (object?["pendingAutoRestores"] as? NSNumber)?.intValue ?? 0
                if state == "partial" {
                    if failedAccounts > 0 {
                        status = "部分账号刷新失败，已保留缓存数据"
                    } else if autoRestoreFailed > 0 {
                        status = "额度缓存已刷新，但自动恢复限流状态失败"
                    } else if pendingAutoRestores > 0 {
                        status = "额度缓存已刷新，但自动恢复限流状态仍在等待重试"
                    } else if let detail, detail.contains("ClickUp") {
                        status = "额度缓存已刷新，但 ClickUp 通知仍有待处理"
                    } else {
                        status = "额度缓存已刷新，但后台仍有待处理任务"
                    }
                } else if state == "error", let detail, !detail.isEmpty {
                    status = "后台刷新失败：\(detail)"
                } else {
                    status = "后台刷新失败：退出码 \(terminationStatus)"
                }
            }
        } catch {
            status = "后台刷新失败：\(friendly(error))"
            loadBackgroundWorkerStatus()
        }
    }

    func restoreAccountStatusNow() async {
        guard !isRefreshing, !isTestingClickUp, !isRestoringStatus else { return }
        isRestoringStatus = true
        status = "正在请求后台 worker 恢复已配置账号的 Sub2API 状态…"
        defer { isRestoringStatus = false }

        do {
            var terminationStatus: Int32 = 75
            for attempt in 0..<5 {
                terminationStatus = try await Self.runWorker(arguments: ["--restore-status"])
                if terminationStatus != 75 { break }
                if attempt < 4 {
                    status = "后台 worker 忙，等待其完成…"
                    try? await Task.sleep(nanoseconds: 4_000_000_000)
                }
            }
            loadCachedData()
            loadBackgroundWorkerStatus()
            WidgetCenter.shared.reloadAllTimelines()
            switch terminationStatus {
            case 0:
                status = "已请求 Sub2API 恢复配置账号状态，并刷新了额度缓存"
            case 75:
                status = "后台 worker 忙，未执行状态恢复，请稍后重试"
            default:
                let object = workerStatusObject()
                let state = object?["state"] as? String
                let detail = object?["detail"] as? String
                let failedAccounts = (object?["failedAccounts"] as? NSNumber)?.intValue ?? 0
                let autoRestoreFailed = (object?["autoRestoreFailedAccounts"] as? NSNumber)?.intValue ?? 0
                let pendingAutoRestores = (object?["pendingAutoRestores"] as? NSNumber)?.intValue ?? 0
                if state == "partial" {
                    if let detail, detail.contains("account restore failed") {
                        status = "账号状态恢复未完全成功：\(detail)"
                    } else if autoRestoreFailed > 0 {
                        status = "账号状态已恢复，但自动恢复限流状态失败"
                    } else if pendingAutoRestores > 0 {
                        status = "账号状态已恢复，但自动恢复限流状态仍在等待重试"
                    } else if failedAccounts > 0 {
                        status = "账号状态已恢复，但部分账号额度刷新失败，已保留缓存数据"
                    } else if let detail, detail.contains("ClickUp") {
                        status = "账号状态已恢复，但 ClickUp 通知仍有待处理"
                    } else {
                        status = "账号状态已恢复，但后台仍有待处理任务：\(detail ?? "未知")"
                    }
                } else if state == "error", let detail, !detail.isEmpty {
                    status = "恢复账号状态失败：\(detail)"
                } else {
                    status = "恢复账号状态失败：退出码 \(terminationStatus)"
                }
            }
        } catch {
            status = "恢复账号状态失败：\(friendly(error))"
            loadBackgroundWorkerStatus()
        }
    }

    func loadBackgroundWorkerStatus() {
        guard let object = workerStatusObject() else {
            backgroundWorkerStatus = "后台刷新尚未产生状态"
            backgroundWorkerState = "unknown"
            return
        }
        let state = object["state"] as? String ?? "unknown"
        backgroundWorkerState = state
        let detail = object["detail"] as? String
        let pending = (object["outboxPending"] as? NSNumber)?.intValue
        let timestamp = object["runFinishedAt"] as? String ?? object["updatedAt"] as? String
        let finishedAt = timestamp.flatMap { ISO8601DateFormatter.openClaw.date(from: $0) ?? ISO8601DateFormatter.openClawNoFraction.date(from: $0) }
        let time = finishedAt?.formatted(date: .omitted, time: .shortened) ?? "未知时间"
        let summary = detail.map { "\(state)：\($0)" } ?? state
        let pendingText = pending.map(String.init) ?? "未知"
        backgroundWorkerStatus = "后台 worker 最近记录 · \(time) \(summary) · 待投递 \(pendingText)"
    }

    private func workerStatusObject() -> [String: Any]? {
        guard let data = try? Data(contentsOf: Self.workerStatusPath) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private static func runWorker(arguments: [String]) async throws -> Int32 {
        guard let executableURL = Self.workerExecutableURL else { throw WorkerLaunchError.embeddedWorkerMissing }
        return try await Task.detached {
            let process = Process()
            process.executableURL = executableURL
            process.arguments = arguments
            do {
                try process.run()
                process.waitUntilExit()
                return process.terminationStatus
            } catch {
                throw error
            }
        }.value
    }

    func sendClickUpTestMessage() async {
        guard !isRefreshing, !isTestingClickUp, !isRestoringStatus else { return }
        isTestingClickUp = true
        status = "正在通过后台 worker 测试 ClickUp Chat…"
        defer { isTestingClickUp = false }

        do {
            let eventID = UUID().uuidString
            var terminationStatus: Int32 = 75
            for attempt in 0..<5 {
                terminationStatus = try await Self.runWorker(arguments: ["--test-clickup", "--event-id", eventID])
                if terminationStatus != 75 { break }
                if attempt < 4 {
                    status = "后台 worker 忙，等待其完成…"
                    try? await Task.sleep(nanoseconds: 4_000_000_000)
                }
            }
            guard let result = clickUpTestResultObject(),
                  result["eventID"] as? String == eventID else {
                throw ClickUpDeliveryError.missingReceipt
            }
            guard result["state"] as? String == "delivered" else {
                let detail = result["detail"] as? String
                throw ClickUpDeliveryError.workerReported(detail ?? "worker 未送达测试消息")
            }
            guard (result["channelID"] as? String)?.isEmpty == false,
                  let messageID = result["messageID"] as? String, !messageID.isEmpty else {
                throw ClickUpDeliveryError.missingReceipt
            }
            loadBackgroundWorkerStatus()
            if terminationStatus == 0 {
                status = "ClickUp Chat 测试已送达（回执 \(messageID)）"
            } else {
                status = "ClickUp Chat 测试已送达（回执 \(messageID)），但 worker 状态记录异常（退出码 \(terminationStatus)）"
            }
        } catch {
            loadBackgroundWorkerStatus()
            status = "ClickUp Chat 测试失败：\(friendly(error))"
        }
    }

    private func clickUpTestResultObject() -> [String: Any]? {
        guard let data = try? Data(contentsOf: Self.clickUpTestResultPath) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private func friendly(_ error: Error) -> String { (error as? LocalizedError)?.errorDescription ?? (error as NSError).localizedDescription }

    static func widgetDataURL() -> URL {
        OpenClawWidgetPaths.resolveCacheURL()
    }
}

private enum WorkerLaunchError: LocalizedError {
    case embeddedWorkerMissing
    var errorDescription: String? {
        "当前 App 构建未包含 Sub2APIRefreshWorker，请从包含 helper 的构建运行；不会使用已安装 App 的 worker。"
    }
}

private enum ClickUpDeliveryError: LocalizedError {
    case missingReceipt
    case workerReported(String)

    var errorDescription: String? {
        switch self {
        case .missingReceipt:
            return "测试结果缺少有效的消息回执"
        case .workerReported(let detail):
            return "后台 worker 未送达测试消息：\(detail)"
        }
    }
}

extension JSONDecoder {
    static var openClaw: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let string = try container.decode(String.self)
            if let date = ISO8601DateFormatter.openClaw.date(from: string) { return date }
            if let date = ISO8601DateFormatter.openClawNoFraction.date(from: string) { return date }
            if string.hasSuffix("Z") {
                let trimmed = String(string.dropLast())
                if let dot = trimmed.firstIndex(of: ".") {
                    let prefix = trimmed[..<dot]
                    let fraction = trimmed[trimmed.index(after: dot)...].prefix(3)
                    let normalized = "\(prefix).\(fraction)Z"
                    if let date = ISO8601DateFormatter.openClaw.date(from: normalized) { return date }
                }
            }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid ISO8601 date: \(string)")
        }
        return decoder
    }
}

extension ISO8601DateFormatter {
    static var openClaw: ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }

    static var openClawNoFraction: ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }
}

struct ContentView: View {
    @StateObject private var model = BalanceViewModel()

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(nsColor: .windowBackgroundColor), Color.accentColor.opacity(0.08)], startPoint: .topLeading, endPoint: .bottomTrailing)
                .ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    header
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)], spacing: 14) {
                        ForEach(displayRows) { account in accountCard(account) }
                    }
                    footer
                }
                .padding(28)
            }
        }
        .frame(minWidth: 720, minHeight: 520)
        .task {
            model.loadCachedData()
            model.loadBackgroundWorkerStatus()
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 16) {
            ZStack {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(.blue.gradient)
                    .frame(width: 54, height: 54)
                    .shadow(color: .blue.opacity(0.25), radius: 12, y: 6)
                Image(systemName: "gauge.with.dots.needle.67percent")
                    .font(.system(size: 25, weight: .semibold))
                    .foregroundStyle(.white)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("OpenClaw Codex 额度")
                    .font(.largeTitle.bold())
                Text("显示配置账号的 5 小时和 7 天剩余额度、已用比例和重置次数。配置含有访问凭据，请限制文件权限并优先使用钥匙串管理 secrets。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            statusPill
        }
    }

    private var statusPill: some View {
        HStack(spacing: 6) {
            Circle().fill(overallStatusColor).frame(width: 8, height: 8)
            Text(overallStatusText)
                .font(.caption.weight(.medium))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(.regularMaterial, in: Capsule())
    }

    private func accountCard(_ account: BalanceAccountResult) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(account.displayName ?? account.name)
                        .font(.title3.bold())
                    Text("窗口：5 小时 / 7 天")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Label(accountStatusText(account), systemImage: accountStatusIcon(account))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(accountStatusColor(account))
                    .labelStyle(.titleAndIcon)
            }

            if account.displayPrimaryWindow != nil || account.secondaryWindow != nil {
                VStack(alignment: .leading, spacing: 10) {
                    Text("额度窗口")
                        .font(.headline)
                    QuotaWindowRow(title: "5 小时", window: account.displayPrimaryWindow, fallbackTint: progressTint(account), cachedUpdatedAt: model.updatedAt)
                    QuotaWindowRow(title: "7 天", window: account.secondaryWindow, fallbackTint: .orange, cachedUpdatedAt: model.updatedAt)
                    if account.primaryWindow == nil, let remaining = account.remaining {
                        Text("旧缓存额度：\(formatQuota(remaining, unit: account.unit))\(account.used.map { "，已用 \(formatQuota($0, unit: account.unit))" } ?? "")")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
            } else if let remaining = account.remaining {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(formatQuota(remaining, unit: account.unit))
                            .font(.system(size: 38, weight: .bold, design: .rounded))
                            .monospacedDigit()
                        Text("剩余")
                            .font(.headline)
                            .foregroundStyle(.secondary)
                        Spacer()
                        if let used = account.used {
                            Text("已用 \(formatQuota(used, unit: account.unit))")
                                .font(.callout.weight(.medium))
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                    }
                    ProgressView(value: progressValue(account))
                        .progressViewStyle(.linear)
                        .tint(progressTint(account))
                    HStack {
                        Text("0%")
                        Spacer()
                        Text("100%")
                    }
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                }
            } else {
                Label(account.message ?? statusText(account.status), systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                infoRow("重置次数", resetSummary(account) ?? "暂无数据", systemImage: "arrow.counterclockwise.circle")
                if let credits = account.resetCredits, !credits.isEmpty {
                    ForEach(Array(credits.enumerated()), id: \.offset) { index, credit in
                        infoRow("到期明细", resetCreditDetail(credit, index: index), systemImage: "calendar.badge.clock")
                    }
                } else if let expirations = account.resetCreditExpirations, !expirations.isEmpty {
                    ForEach(Array(expirations.enumerated()), id: \.offset) { index, date in
                        infoRow("到期明细", "第 \(index + 1) 次：\(formatDateString(date))", systemImage: "calendar.badge.clock")
                    }
                } else if (account.resetAvailableCount ?? 0) > 0 {
                    infoRow("到期明细", "sub2api 当前未返回 expires_at，无法显示具体到期时间", systemImage: "calendar.badge.exclamationmark")
                }
                if account.status == "ok",
                   account.sub2apiHasError == true,
                   let message = account.sub2apiErrorMessage, !message.isEmpty {
                    infoRow("Sub2API", message, systemImage: "info.circle")
                }
                if let message = account.message, account.status != "ok" {
                    infoRow("说明", message, systemImage: "info.circle")
                }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, minHeight: 280, alignment: .topLeading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(.white.opacity(0.18)))
        .shadow(color: .black.opacity(0.08), radius: 18, y: 8)
    }

    private func infoRow(_ title: String, _ value: String, systemImage: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: systemImage)
                .foregroundStyle(.secondary)
                .frame(width: 16)
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 56, alignment: .leading)
            Text(value)
                .font(.caption)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Button {
                    Task { await model.runBackgroundRefreshNow() }
                } label: {
                    Label(model.isRefreshing ? "正在刷新…" : "刷新 Codex 额度", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.isRefreshing || model.isTestingClickUp || model.isRestoringStatus)

                Button {
                    Task { await model.restoreAccountStatusNow() }
                } label: {
                    Label(model.isRestoringStatus ? "正在恢复…" : "恢复账号状态", systemImage: "arrow.uturn.backward.circle")
                }
                .buttonStyle(.bordered)
                .disabled(model.isRefreshing || model.isTestingClickUp || model.isRestoringStatus)

                Button {
                    model.loadCachedData()
                    model.loadBackgroundWorkerStatus()
                    WidgetCenter.shared.reloadAllTimelines()
                } label: {
                    Label("刷新小组件", systemImage: "rectangle.3.group.bubble.left")
                }
                .buttonStyle(.bordered)

                Button {
                    Task { await model.sendClickUpTestMessage() }
                } label: {
                    Label(model.isTestingClickUp ? "正在测试…" : "测试 ClickUp Chat", systemImage: "paperplane")
                }
                .buttonStyle(.bordered)
                .disabled(model.isRefreshing || model.isTestingClickUp || model.isRestoringStatus)

                Spacer()

                if let updatedAt = model.updatedAt {
                    Label("更新时间：\(updatedAt.formatted(date: .abbreviated, time: .standard))", systemImage: "clock")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            VStack(alignment: .leading, spacing: 7) {
                Label(model.status, systemImage: statusSymbol)
                Label(model.backgroundWorkerStatus, systemImage: "gearshape.2")
                    .lineLimit(2)
                .font(.caption)
                .foregroundStyle(.secondary)

                Text(sourceSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var sourceSummary: String {
        let backend = model.configuration?.adminBaseURL ?? "未配置 backend"
        let bridge = model.configuration?.bridgeBaseURL.map { " + bridge \($0)" } ?? ""
        return "数据来源：sub2api admin quota (\(backend))\(bridge)；小组件读取共享缓存 JSON"
    }

    private func formatQuota(_ value: Double, unit: String?) -> String {
        let n = value.formatted(.number.precision(.fractionLength(0...2)))
        if let unit, !unit.isEmpty, unit != "quota" { return "\(n) \(unit)" }
        return n
    }

    private func progressValue(_ account: BalanceAccountResult) -> Double {
        if let remaining = account.remaining, account.unit == "%" { return max(0, min(1, remaining / 100.0)) }
        if let remaining = account.remaining, let limit = account.limit, limit > 0 { return max(0, min(1, remaining / limit)) }
        return 0
    }

    private func progressTint(_ account: BalanceAccountResult) -> Color {
        let value = progressValue(account)
        if value >= 0.7 { return .green }
        if value >= 0.3 { return .orange }
        return .red
    }

    private var hasCriticalAccountError: Bool {
        displayRows.contains { account in
            if account.status == "error" || account.status == "missing" || account.status == "config" {
                return true
            }
            guard account.status == "ok", account.sub2apiStateUnknown != true else { return false }
            return account.sub2apiHasError == true || accountStatusText(account) == "异常"
        }
    }

    private var overallStatusText: String {
        if model.isRefreshing { return "刷新中" }
        if model.isRestoringStatus { return "恢复状态中" }
        if displayRows.allSatisfy({ accountStatusText($0) == "正常" }) { return "正常" }
        if hasCriticalAccountError { return "有账号异常" }
        if displayRows.contains(where: { accountStatusText($0) == "限流中" }) { return "有限流账号" }
        if displayRows.contains(where: { $0.status == "stale" }) { return "缓存数据" }
        return "需检查"
    }

    private var overallStatusColor: Color {
        if model.isRefreshing || model.isRestoringStatus { return .blue }
        if displayRows.allSatisfy({ accountStatusText($0) == "正常" }) { return .green }
        if hasCriticalAccountError { return .red }
        if displayRows.contains(where: { accountStatusText($0) == "限流中" }) { return .orange }
        if displayRows.contains(where: { $0.status == "stale" }) { return .orange }
        return .red
    }

    private var statusSymbol: String {
        if model.isRefreshing || model.isTestingClickUp || model.isRestoringStatus { return "hourglass" }
        if model.backgroundWorkerState == "partial" || model.backgroundWorkerState == "error"
            || model.status.contains("失败") || model.status.contains("部分")
            || model.status.contains("需检查") || model.status.contains("异常") {
            return "exclamationmark.triangle.fill"
        }
        return "checkmark.circle"
    }

    private func statusText(_ status: String) -> String {
        switch status {
        case "ok": return "正常"
        case "stale": return "缓存"
        case "missing": return "未找到"
        case "config": return "需配置"
        case "legacy": return "旧接口"
        case "waiting": return "等待刷新"
        case "error": return "错误"
        default: return status
        }
    }

    private func statusIcon(_ status: String) -> String {
        switch status {
        case "ok": return "checkmark.circle.fill"
        case "stale": return "clock.badge.exclamationmark.fill"
        case "waiting": return "hourglass"
        default: return "exclamationmark.triangle.fill"
        }
    }

    private func statusColor(_ status: String) -> Color {
        switch status {
        case "ok": return .green
        case "stale", "waiting": return .orange
        default: return .red
        }
    }

    private func hasActiveTempUnschedulableUntil(_ account: BalanceAccountResult) -> Bool {
        guard let until = account.sub2apiTempUnschedulableUntil, !until.isEmpty else { return false }
        guard let deadline = ISO8601DateFormatter.openClaw.date(from: until)
            ?? ISO8601DateFormatter.openClawNoFraction.date(from: until) else {
            // An unparsable timestamp is treated as active rather than silently
            // clearing the unschedulable state.
            return true
        }
        return deadline > Date()
    }

    private func hasSub2APISchedulingEvidence(_ account: BalanceAccountResult) -> Bool {
        account.sub2apiStateUnknown != nil
            || account.sub2apiStatus != nil
            || account.sub2apiIsRateLimited != nil
            || account.sub2apiIsOverloaded != nil
            || account.sub2apiHasError != nil
            || account.sub2apiIsAvailable != nil
            || account.sub2apiIsSchedulable != nil
            || account.sub2apiRateLimitResetAt != nil
            || account.sub2apiTempUnschedulableUntil != nil
            || account.sub2apiErrorMessage != nil
    }

    private func accountStatusText(_ account: BalanceAccountResult) -> String {
        // 仅在本次额度刷新成功（非 stale/cache）时展示 Sub2API 调度状态。
        guard account.status == "ok" else { return statusText(account.status) }

        if account.sub2apiStateUnknown == true || !hasSub2APISchedulingEvidence(account) { return "状态未知" }
        if account.sub2apiHasError == true { return "异常" }
        if account.sub2apiIsRateLimited == true { return "限流中" }
        if account.sub2apiIsOverloaded == true { return "过载" }
        if hasActiveTempUnschedulableUntil(account) { return "暂不可调度" }

        switch account.sub2apiStatus {
        case "active":
            if account.sub2apiIsSchedulable == false { return "已停用" }
            if account.sub2apiIsAvailable == true { return "正常" }
            return "不可调度"
        case "inactive":
            return "已停用"
        case "error":
            return "异常"
        case .some(let raw):
            return raw
        case nil:
            if account.sub2apiIsAvailable == true { return "正常" }
            if account.sub2apiIsAvailable == false || account.sub2apiIsSchedulable == false { return "不可调度" }
            return "状态未知"
        }
    }

    private func accountStatusIcon(_ account: BalanceAccountResult) -> String {
        guard account.status == "ok" else { return statusIcon(account.status) }
        if account.sub2apiStateUnknown == true || !hasSub2APISchedulingEvidence(account) { return "questionmark.circle.fill" }
        if account.sub2apiHasError == true { return "exclamationmark.triangle.fill" }
        if account.sub2apiIsRateLimited == true { return "clock.badge.exclamationmark.fill" }
        if account.sub2apiIsOverloaded == true { return "bolt.horizontal.circle.fill" }
        if hasActiveTempUnschedulableUntil(account) { return "pause.circle.fill" }
        if account.sub2apiIsSchedulable == false { return "pause.circle.fill" }
        if account.sub2apiStatus == nil {
            if account.sub2apiIsAvailable == true { return "checkmark.circle.fill" }
            if account.sub2apiIsAvailable == false || account.sub2apiIsSchedulable == false { return "exclamationmark.triangle.fill" }
            return "questionmark.circle.fill"
        }
        if account.sub2apiIsAvailable == true { return "checkmark.circle.fill" }
        return "exclamationmark.triangle.fill"
    }

    private func accountStatusColor(_ account: BalanceAccountResult) -> Color {
        guard account.status == "ok" else { return statusColor(account.status) }
        if account.sub2apiStateUnknown == true || !hasSub2APISchedulingEvidence(account) { return .orange }
        if account.sub2apiHasError == true { return .red }
        if account.sub2apiIsRateLimited == true || account.sub2apiIsOverloaded == true { return .orange }
        if hasActiveTempUnschedulableUntil(account) { return .orange }
        if account.sub2apiIsSchedulable == false { return .secondary }
        if account.sub2apiStatus == nil {
            if account.sub2apiIsAvailable == true { return .green }
            return .orange
        }
        if account.sub2apiIsAvailable == true { return .green }
        return .orange
    }

    private func resetSummary(_ account: BalanceAccountResult) -> String? {
        guard let count = account.resetAvailableCount else { return account.resetMessage }
        if count == 0 { return "0 次可用" }
        if let credits = account.resetCredits, !credits.isEmpty { return "\(count) 次可用（含官方到期时间）" }
        if let expirations = account.resetCreditExpirations, !expirations.isEmpty { return "\(count) 次可用" }
        if account.resetMessage != nil { return "\(count) 次可用（暂无到期时间）" }
        return "\(count) 次可用"
    }

    private func resetCreditDetail(_ credit: ResetCredit, index: Int) -> String {
        let title = credit.title ?? "第 \(index + 1) 次"
        let status = credit.status ?? "unknown"
        let expires = credit.expiresAt.map(formatDateString) ?? "未知"
        let granted = credit.grantedAt.map(formatDateString)
        if let granted { return "\(title)：\(status)，到期 \(expires)，发放 \(granted)" }
        return "\(title)：\(status)，到期 \(expires)"
    }

    private func formatDateString(_ value: String) -> String {
        if let date = ISO8601DateFormatter.openClaw.date(from: normalizedDateString(value)) ?? ISO8601DateFormatter.openClawNoFraction.date(from: value) {
            return date.formatted(date: .abbreviated, time: .shortened)
        }
        return value
    }

    private func normalizedDateString(_ value: String) -> String {
        guard value.hasSuffix("Z"), let dot = value.firstIndex(of: ".") else { return value }
        let prefix = value[..<dot]
        let fractionStart = value.index(after: dot)
        let fraction = value[fractionStart...].dropLast().prefix(3)
        return "\(prefix).\(fraction)Z"
    }

    private var displayRows: [BalanceAccountResult] {
        if !model.results.isEmpty { return model.results }
        let configured = model.configuration?.accounts.prefix(2).map {
            BalanceAccountResult(name: $0.name, remaining: nil, limit: nil, used: nil, unit: nil, window: "30d", status: "waiting", message: "尚未刷新", displayName: $0.displayName, abbreviation: $0.abbreviation)
        }
        if let configured, !configured.isEmpty { return Array(configured) }
        return [
            BalanceAccountResult(name: "Account 1", remaining: nil, limit: nil, used: nil, unit: nil, window: "30d", status: "waiting", message: "尚未刷新"),
            BalanceAccountResult(name: "Account 2", remaining: nil, limit: nil, used: nil, unit: nil, window: "30d", status: "waiting", message: "尚未刷新")
        ]
    }
}
